var directionsDisplay;
var lastRequest;
var ignoreCalc = false;
var serv = new google.maps.DirectionsService();
var circles = new Array();
var lastIndex = -1;
var circleInfoWin = new google.maps.InfoWindow();
var majObj;
var serverUrl = "http://torvm3-sup213.sybase.com/getDelay";

// Convert a duration in seconds to human readable form
function secondsToHms(d) {
	d = Number(d);
	var h = Math.floor(d / 3600);
	var m = Math.floor(d % 3600 / 60);
	var s = Math.floor(d % 3600 % 60);
	// Format is "H hr MM min SS sec"
	return ((h > 0 ? h + " hr " : "") + (m > 0 ? (h > 0 && m < 10 ? "0" : "") + m + " min " : "0:") + (s < 10 ? "0" : "") + s + " sec");
}

// Calculate the delay for a given route index
function calculateDelay(r) {
	// Sometimes we need to suppress the calculation, e.g. when manually triggering
	// the directions_updated event to update the map
	if(ignoreCalc) return;

	// Clear the lastIndex so that currently displayed circles are not redrawn
	lastIndex = -1;

	// Hide currently displayed circles
	for(i in circles[directionsDisplay.routeIndex]) {
		circles[directionsDisplay.routeIndex][i].setVisible(false);
	}

	// Get the date value from the datepicker
	var time = $('#datepicker').datepicker('getDate');

	// If datepicker is empty, default to current date
	if(!time) {
		time = new Date();
	}
	
	// Set the hours and minutes from the timepicker
	time.setHours($('#timepicker').timepicker('getHour'));
	time.setMinutes($('#timepicker').timepicker('getMinute'));

	// Display a message to show progress
	directionsDisplay.directions.routes[r].warnings.push("Estimating delay for route...");
	
	// Track the current travelled duration
	var baseDuration = 0;
	
	// For each route, the response contains one or more legs with multiple steps
	// For each step, the response contains a duration and a list of coordinates for the path
	/* Construct the XML parameter with the format:
		<route>
			<time>DateTime to calculate the delay for</time>
			<leg>
				<step>
					<duration>Total duration travelled so far</duration>
					<lineString>A lineString in the WKT format</lineString>
				</step>
				<step>
					... remaining steps of the leg
				</step>
			</leg>
			<leg>
				... remaining legs of the route
			</leg>
		</route>
	*/
	var param = "<route><time>" + time.toISOString() + "</time>";
	for(l in directionsDisplay.directions.routes[r].legs) {
		param += "<leg>";
		for(s in directionsDisplay.directions.routes[r].legs[l].steps) {
			var step = directionsDisplay.directions.routes[r].legs[l].steps[s];
			param += "<step><duration>" + baseDuration + "</duration><lineString>";
			// Add the duration of the current step so we know how much time 
			// has passed when we start the next step
			baseDuration += step.duration.value;
			var lineStr = "LineString(";
			for(p in step.path) {
				// Ya is the latitude and Xa is the longitude, both in WGS84 
				lineStr += step.path[p].Ya + " " + step.path[p].Xa + ", ";
			}
			lineStr = lineStr.slice(0, -2);
			lineStr += ")</lineString></step>";
			param += lineStr;
		}
		param += "</leg>";
	}
	param += "</route>";
	
	// Send the request and store the object in case we need to abort it later
	lastRequest = $.ajax({
		type:"POST",
		url: serverUrl,
		data: {"param" : param},
		beforeSend: function(jqXHR, settings) {
			// Store the routeIndex so when we get the response we know which route it's for
			jqXHR.routeIndex = r;
		},
		success: function(data, textStatus, jqXHR) {
			// Read the route index from the response header
			var route = parseInt(jqXHR.routeIndex, 10);
			// If the index isn't in the header, assume it's the currently displayed route
			if(!route) {
				route = directionsDisplay.routeIndex;
			}
			// If that's null, set it to the first route
			if(!route) {
				route = 0;
			}
			// Store the index of the last received route
			if(route == directionsDisplay.routeIndex) {
				lastIndex = route;
			}
			var delay = 0;
			// Remove any existing circles for this route
			for(c in circles[route]) {
				circles[route][c].setMap(null);
			}
			circles[route] = new Array();
			if(typeof(data) == "string") {
				// Parse the response JSON string into an object
				data = jQuery.parseJSON(data);
			}
			
			for(d in data) {
				// Ignore incident clusters with less than 10% chance
				if(data[d].chance < 10) continue;
				// Add the delay time of the cluster to the total delay time
				delay += data[d].delayTime;
				var color;
				// Set the color of the circle depending on the severity of the cluster
				switch(data[d].severity) {
					case 1:
						color = "yellow";
						break;
					case 2:
						color = "orange";
						break;
					case 3:
						color = "red";
						break;
					case 4:
						color = "white";
						break;
				}
				// Create a new circle on the map to display the incident cluster
				var c = new google.maps.Circle({
					// Set the center to the location of the incident
					center: new google.maps.LatLng(data[d].latitude, data[d].longitude),
					// Set color based on severity
					fillColor: color, 
					// Set opacity based on chance of incident occurring
					fillOpacity : 0.5 * ( data[d].chance / 100),
					// Set radius to the length of incident in meters
					radius: data[d].delayLength,
					map: directionsDisplay.map,
					strokeWeight: 1,
					strokeColor: "blue",
					strokeOpacity: 0.5
				});
				// Store the incident item as part of the circle
				c.item = data[d];
				
				// Debug function for removing individual circles from the map
				/*google.maps.event.addListener(c, 'rightclick', function(e) {
					this.setVisible(false);
				});*/
				
				// On mouseover of a circle, highlight it by increasing the stroke
				// and show the incident information in the info pane
				google.maps.event.addListener(c, 'mouseover', function(e) {
					this.setOptions({ strokeWeight: 3 });
					$("#info").html("<span>lat: " + this.item.latitude +
												"</span><br><span>lng: " + this.item.longitude + 
												"</span><br><span>length: " + this.item.delayLength + 
												"</span><br><span>duration: " + this.item.delayTime + 
												"</span><br><span>type: " + this.item.jam_type + 
												"</span>").show();
				});
				
				// Unhighlight and hide the info pane
				google.maps.event.addListener(c, 'mouseout', function(e) {
					this.setOptions({ strokeWeight: 1 });
					$("#info").html("").hide();
				});

				// If this route isn't currently displayed on the map, hide the circle
				if(route != directionsDisplay.routeIndex) {
					c.setVisible(false);
				}
				// Add the circle to the list of circles for this route
				circles[route].push(c);
			}
			// Clear the warnings for this route 
			directionsDisplay.directions.routes[route].warnings = [];

			// Show a message with the total delay in the directionsDisplay panel
			if(delay > 0) {
				var warningStr = "Route may be delayed by " + secondsToHms(delay) + " due to traffic conditions";
				directionsDisplay.directions.routes[route].warnings.push(warningStr);
				warningStr = "Estimated total travel time is " + secondsToHms(baseDuration + delay);
				directionsDisplay.directions.routes[route].warnings.push(warningStr);
			} else {
				directionsDisplay.directions.routes[route].warnings.push("No expected delays on route");
			}
			//console.log(data);
		},
		error: function(jqXHR, textStatus, errorThrown) {
			// On error, display the error in the directionsDisplay panel
			var route = parseInt(jqXHR.routeIndex, 10);
			if(!route) {
				route = directionsDisplay.routeIndex;
			}
			if(!route) {
				route = 0;
			}
			directionsDisplay.directions.routes[route].warnings = [];
			var warningStr = "Failed to estimate traffic delay: " + textStatus;
			directionsDisplay.directions.routes[route].warnings.push(warningStr);
			if(errorThrown) {
				warningStr = "HTTP error: " + errorThrown;
				directionsDisplay.directions.routes[route].warnings.push(warningStr);
			}
		},
		complete: function(jqXHR, textStatus) {
			// Trigger the directions_changed event to update the map, 
			// but prevent the calcDelay function from running again
			ignoreCalc = true;
			google.maps.event.trigger(directionsDisplay, 'directions_changed');
			ignoreCalc = false;
		}				
	});
}

// Handler for when the Route button is clicked
function calcRoute() {			
	// Clear any existing error messages
	$('#errorMsg').text("");
	// Hide the incident info window
	circleInfoWin.close();
	// Create the google.maps.DirectionsRequest object
	var req = {
		origin: $("#start").val(),
		destination: $("#dest").val(),
		waypoints: [],
		provideRouteAlternatives: true,
		travelMode: google.maps.TravelMode.DRIVING,
		unitSystem: google.maps.UnitSystem.METRIC
	};

	// Submit the request 
	serv.route(req, function(response, status) {
		if (status == google.maps.DirectionsStatus.OK) {
			// Pass the route response to the DirectionsRenderer
			directionsDisplay.setDirections(response);
			// Calculate the delay for all routes except the initial one,
			// since that will trigger a directions_changed event 
			for(i in directionsDisplay.directions.routes) {
				if(i == 0) continue;
				calculateDelay(i);
			}
		}
		else { 
			$('#errorMsg').text("ERROR: " + status);
		}
	});
}
