-- Create the web service
IF ( SELECT COUNT(*) FROM syswebservice WHERE service_name = 'getDelay' ) < 1 THEN
	CREATE SERVICE getDelay 
		TYPE 'JSON' 
		AUTHORIZATION OFF
		SECURE OFF
		USER DBA
		AS CALL get_delays( http_variable( 'param' ) );
END IF;

-- Install the extra SRSes, should be instant if already installed
CALL sa_install_feature( 'st_geometry_predefined_srs' );

-- Associate type ids with strings
DROP TABLE IF EXISTS traffic_jam_type
CREATE TABLE IF NOT EXISTS traffic_jam_type 
	(
		type_id INT NOT NULL,
		type_name VARCHAR( 20 ) NOT NULL,
		PRIMARY KEY ( type_id ASC )
	)

INSERT INTO traffic_jam_type VALUES( '1', 'Unknown' )
INSERT INTO traffic_jam_type VALUES( '3', 'Accident Cleared' )
INSERT INTO traffic_jam_type VALUES( '6', 'Traffic Jam' )
INSERT INTO traffic_jam_type VALUES( '7', 'Roadwork' )
INSERT INTO traffic_jam_type VALUES( '8', 'Accident' )
INSERT INTO traffic_jam_type VALUES( '9', 'Long Term Roadwork' )
INSERT INTO traffic_jam_type VALUES( '13', 'Unknown' );


-- Create the SRID lookup table
CREATE TABLE IF NOT EXISTS srid_lookup_table
	(
		longitude DOUBLE NOT NULL,
		latitude DOUBLE NOT NULL,
		srid INTEGER NULL,
		PRIMARY KEY ( longitude ASC, latitude ASC )
	);
	
-- Function to find the closest valid SRS for a given coordinate
-- Results are cached in a lookup table
CREATE OR REPLACE 
FUNCTION get_closest_srs ( x DOUBLE, y DOUBLE, source_id INTEGER )
RETURNS INTEGER
BEGIN
	DECLARE @srsid INT;
	SELECT FIRST srs_id
	INTO @srsid
	FROM ST_SPATIAL_REFERENCE_SYSTEMS
	-- Only search the WGS 84 systems
	WHERE srs_id BETWEEN 32600 AND 32800
		-- Only need to look for planar projections
		AND srs_type    = 'PROJECTED'
		AND round_earth = 'N'
		AND linear_unit_of_measure LIKE 'met%'
		-- Create a polygon of the limits of the system, transform it into the requested system, 
		-- and check if it covers the requested point
		AND NEW ST_Polygon( NEW ST_Point( min_x, min_y, srs_id ), NEW ST_Point( max_x, max_y, srs_id ) ) 
					.ST_Transform( source_id ) 
					.ST_Covers( NEW ST_Point( x, y, source_id ) ) = 1
	ORDER BY srs_id;
	-- Cache the result in the lookup table, with two decimals for the coordinates
	INSERT INTO srid_lookup_table 
	ON EXISTING SKIP 
	VALUES ( ROUND( x, 2 ), ROUND( y, 2 ), @srsid );
	RETURN @srsid;
END;

-- Procedure to calculate delays from an XML string @param
CREATE OR REPLACE
PROCEDURE get_delays( IN @param LONG VARCHAR )
RESULT 	(
			jam_type VARCHAR( 20 ),
			severity INT,
			longitude DOUBLE,
			latitude DOUBLE,
			delayTime DOUBLE,
			delayLength DOUBLE,
			chance INT 
		)
BEGIN
	-- Total time travelled after the previous step
	DECLARE @c_duration INT;
	-- Original request start time
	DECLARE @c_startTime DATETIME;
	-- LineString of this step
	DECLARE @c_lineString LONG VARCHAR;
	-- Delay for this step
	DECLARE @c_totalDelay INT;
	IF DATEDIFF( HOUR, ( SELECT MIN( lastUpdate ) FROM traffic_delay_avg ), CURRENT TIMESTAMP ) = 0 THEN
	ELSE
		DROP TABLE IF EXISTS traffic_delay_avg;
		SELECT 	severity,
				SUM( delayTime ) / SUM( delayLength ) AS delayPerMeter,
				CURRENT TIMESTAMP AS lastUpdate
		INTO traffic_delay_avg
		FROM traffic
		WHERE delayLength <> 0
			AND delayTime <> 0
		GROUP BY severity
		ORDER BY severity;
	END IF;
	
	-- Get the request start time
	SELECT CAST( timeStr AS DATETIME ) 
	INTO @c_startTime 
	FROM openxml( @param, '/route' )
	WITH ( timeStr VARCHAR( 50 ) 'time') s;
	
	-- Allow cross-domain requests
	CALL sa_set_http_header( 'Access-Control-Allow-Origin', '*' );
	
	SELECT 	type_name,								-- Type of the cluster of incidents as a string
			ROUND( AVG( h.severity ), 0 ),			-- Average severity
			AVG( h.lng ),							-- Average of longitudes for all points
			AVG( h.lat ),							-- Average of latitudes for all points
			CEILING( AVG( h.delayTime ) * chance / 100 ) AS delayTime,	-- Average delay duration in seconds scaled by chance
			CEILING( AVG( h.delayLen ) ) AS len,	-- Average length in meters
			CASE
				-- When the incident is construction, give it 100% chance but scale by weekdayFactor
				WHEN jam_type IN (7, 9)
					THEN 100
				-- For other incidents, calculate the probability as number of occurances for this incident
				-- over maximum number of occurances per incident over all incidents 
				-- times the average weekday impact factor
				ELSE 
					CAST( COUNT(*) AS DOUBLE ) / ( MAX( COUNT(*) ) OVER ( PARTITION BY jam_type ) ) * 100
			END * AVG( h.weekDayFactor ) AS chance	-- Chance that this group will cause a delay at the requested time
	FROM
	(
		SELECT 	g.jam_type,
				AVG( g.lat ) AS lat,				-- Average latitude
				AVG( g.lng ) AS lng,				-- Average longitude
				ROUND( g.lng, 2 ) AS grp_lng,		-- Keep track of the coordinates we're grouping by 
				ROUND( g.lat, 2 ) AS grp_lat,		-- so we can group with them again later
				AVG( g.delayLen ) AS delayLen,		-- Average length in meters
				SUM( g.delayTime ) AS delayTime,	-- Total duration in seconds; remember we're aggregating over different
													-- incidents in an area on the same day
				AVG( g.severity ) AS severity,		-- Average severity
				AVG( g.weekdayFactor ) as weekdayFactor
		FROM
		(
			SELECT 	DATE( a.request_time ) AS day,		-- Date of the group of incidents
					a.jam_type,							-- Incident type
					AVG( a.severity ) AS severity,		-- Average severity
					AVG( a.lat ) AS lat,				-- Average latitude
					AVG( a.lng ) AS lng,				-- Average longitude
					AVG( a.delayLength ) AS delayLen,	-- Average length in meters
					AVG( a.delayTime ) AS delayTime,	-- Average duration in seconds
					-- Strip out _1 and _2 which is for the same incident in different directions
					CASE
						WHEN jam_id LIKE '%[_][12]' THEN
							LEFT( jam_id, LEN( jam_id ) - 2 )
						ELSE							
							jam_id
						END
						AS stripped_id,
					-- Calculate a weekDayFactor for each incident as a measure of how likely 
					-- an incident is to occur on a particular day of the week
					CASE
						-- If the past incident occurred on the same day as the request date, give it full impact
						WHEN DATEPART( WEEKDAY, day ) = DATEPART( WEEKDAY, SECONDS( @c_startTime, MIN( x.duration ) ) )
							THEN 1.0
						-- If it was construction and occurred on a weekday but not on the same day, give it 5/7 impact
						WHEN jam_type IN (7, 9) AND DATEPART( weekday, day ) BETWEEN 2 AND 6
							THEN 5.0 / 7.0
						-- If it was construction and occurred on a weekend, give it 2/7 impact
						WHEN jam_type IN (7, 9) AND DATEPART( weekday, day ) NOT BETWEEN 2 AND 6
							THEN 2.0 / 7.0
						-- If it was not construction and occurred on a weekday, give it 1/5 impact
						WHEN jam_type NOT IN (7, 9) AND DATEPART( weekday, day ) BETWEEN 2 AND 6
							THEN 1.0 / 5.0
						-- If it was not construction and occurred on a weekend, give it 1/2 impact
						ELSE 
							1.0 / 2.0
					END AS weekDayFactor
			-- Parse the XML parameter as a result set
			FROM OPENXML( @param, '/route/leg/step' )
			WITH ( duration INT 'duration', lineString LONG VARCHAR 'lineString' ) AS x
			-- Join it to all the traffic incidents
			LEFT JOIN
			(
				SELECT 	request_time, 					-- Time of the incident
						jam_type,						-- Incident type 
						jam_id, 						-- Incident ID
						traffic.severity AS severity,	-- Incident Severity
						traffic.latitude AS lat, 		-- Incident latitude
						traffic.longitude AS lng, 		-- Incident longitude
						delayLength AS delayLength,		-- Length of the delay in meters	
						-- If the delayTime is not provided, calculate it by multiplying the severity and
						-- average delay time for that severity
						CASE
							WHEN delayTime > 0
								THEN delayTime
							ELSE
								(
									SELECT delayPerMeter 
									FROM traffic_delay_avg 
									WHERE traffic.severity = traffic_delay_avg.severity
								) * traffic.delayLength 
						END AS delayTime,				-- Duration of the delay in seconds
						CASE
							-- If the SRS ID isn't in the table, calculate it
							WHEN srid_lookup_table.srid IS NULL
								THEN get_closest_srs( traffic.longitude, traffic.latitude, 4326 )
							ELSE 
								srid_lookup_table.srid
						END AS srs_id		-- A SRS which contains this point
				FROM traffic
				-- Search the SRS lookup table for a SRS containing this point
				LEFT JOIN srid_lookup_table
				ON ROUND( traffic.longitude, 2 )		= srid_lookup_table.longitude
					AND ROUND( traffic.latitude, 2 ) 	= srid_lookup_table.latitude
				-- Ignore unknown and cleared types
				WHERE jam_type NOT IN( 1, 3, 13 )
					AND delayLength > 0
			) AS a
			-- Incident hour matches step start time
			ON DATEPART( hour, request_time ) = DATEPART( hour, SECONDS( @c_startTime, duration ) )
				-- Incident minute within 4 minutes of step start time
				AND ABS( DATEPART( MINUTE, request_time ) - DATEPART( MINUTE, SECONDS( @c_startTime, duration ) ) ) < 2
				-- Match only weekday incidents or weekend incidents depending on the day of step start time
				AND
				(
					(
						-- If the incident type is not construction
						jam_type NOT IN( 7, 9 )
						AND
						(
							(
								-- Only match weekdays for weekday requests
								DATEPART( weekday, request_time ) BETWEEN 2 AND 6
								AND
								DATEPART( weekday, SECONDS( @c_startTime, duration ) ) BETWEEN 2 AND 6
							)
							OR
							(
								-- Only match weekends for weekend requests
								DATEPART( weekday, request_time ) NOT BETWEEN 2 AND 6
								AND
								DATEPART( weekday, SECONDS( @c_startTime, duration ) ) NOT BETWEEN 2 AND 6
							)
						)
					)
					OR
					(
						-- For construction type incidents
						jam_type IN( 7, 9 )
						-- Only take incidents which occured before the requested datetime
						AND request_time < SECONDS( @c_startTime, duration )
						AND CAST( request_time AS DATE ) IN
							(
								-- Match incidents which occurred on the same or previous day
								CAST( SECONDS( @c_startTime, duration ) AS DATE ),
								CAST( days( SECONDS( @c_startTime, duration ), - 1 ) AS DATE ),
								-- Or the request is far in the future, also match items from the last day with data available
								( SELECT top 1 CAST( request_time AS DATE ) FROM traffic ORDER BY request_time DESC	)
							)
					)
				)
				-- Incident distance to the step line segment is less than the length of the incident
				AND NEW ST_LineString( x.lineString, 4326 )
						.ST_Transform( a.srs_id )
						.ST_Distance( NEW ST_Point( a.lng, a.lat, 4326 )
											.ST_Transform( a.srs_id ) )
						< a.delayLength
			-- Gather all incidents of the same type with the same ID and on the same day
			GROUP BY DATE( a.request_time ),
				a.jam_type,
				stripped_id
		) AS g
		-- Group by incidents of the same type on the same day within a small area
		-- This is to add all the delay durations within a vicinity
		GROUP BY g.jam_type,
					g.day,
					ROUND( g.lng, 2 ),
					ROUND( g.lat, 2 )
	) AS h
	-- Join the type id to the name as a string
	LEFT JOIN traffic_jam_type
	ON h.jam_type = traffic_jam_type.type_id
	-- Group incident clusters together without grouping by the date to count how many different days each cluster occured on 
	GROUP BY type_name, 
				jam_type,
				h.grp_lng,
				h.grp_lat
	-- Order by the length of the incident group
	ORDER BY len DESC
END;
