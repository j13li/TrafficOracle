using System;
using System.Collections.Generic;

// Class definitions for deserializing the JSON string
/* JSON string format:
 *	{
 *		"tm": 
 *		{
 *			"@id": "",					// Current time as Unix timestamp
 *			"poi": 						// Point of interest
 *			[
 *				{
 *					"id": "",			// Unique jam identifier
 *					"p": 				// Coordinates of jam
 *					{
 *						"x": 0.0,		// Longitude
 *						"y": 0.0		// Latitude
 *					},
 *					"ic": 0,			// Type
 *					"ty": 0,			// Severity
 *					"cbl": 				// Cluster's bottom-left
 *					{
 *						"x": 0.0,		// Longitude
 *						"y": 0			// Latitude
 *					},
 *					"ctr":				// Cluster's top-right
 *					{
 *						"x": 0.0,		// Longitude
 *						"y": 0			// Latitude
 *					},
 *					"cs": 0,			// Number of clustered (sub) points
 *					"cpoi": [ {} ],		// Clustered (sub) points of interest
 *					"d": "",			// Description				
 *					"f": "",			// From: Jam starting point
 *					"t": "",			// To: Jam ending point
 *					"r": ""				// Road name
 *					"l": 0,				// Length of delay in meters
 *					"dl": 0				// Duration-length of delay in seconds
 *					"c": ""				// Cause of accident			
 *				}
 *			]
 *		}
 *	}
 */
namespace TomTomDataScraper
{
    public enum Severity
    {
        No_Delay = 0,
        Slow_Traffic = 1,
        Queuing_Traffic = 2,
        Stationary_Traffic = 3,
        Closed = 4
    }

    public enum Type
    {
        Unknown1 = 1,
        Accident_Cleared = 3,
        Traffic_Jam = 6,
        Roadwork = 7,
        Accident = 8,
        Long_Term_Roadwork = 9,
        Unknown13 = 13
    }

    // Root item in the response
    public class ResultContainer
    {
        public Result tm { get; set; }
    }

    // Root item contains the timestamp and a list of POIs
    public class Result
    {
        // Unix timestamp
        public string id { get; set; }
        public List<POI> poi { get; set; }
    }

    // Class for a pair of coordinates
    public class Coordinate
    {
        public double x { get; set; }
        public double y { get; set; }
    }

    // Class definition for an POI object
    public class POI : IComparable<POI>, IEquatable<POI>
    {
        // Unique ID
        public string id { get; set; }
        // Coordinate of jam
        public Coordinate p { get; set; }
        public Type ic { get; set; }
        public Severity ty { get; set; }
        // Bottom left coordinate
        public Coordinate cbl { get; set; }
        // Top right coordinate
        public Coordinate ctr { get; set; }
        // Number of clustered points
        public int cs { get; set; }
        // List of clustered POIs
        public List<POI> cpoi { get; set; }
        // Description
        public string d { get; set; }
        // From: Jam starting point
        public string f { get; set; }
        // To: Jam ending point
        public string t { get; set; }
        // Road name
        public string r { get; set; }
        // Length of delay in meters
        public int l { get; set; }
        // Duration of delay in seconds
        public int dl { get; set; }
        // Cause
        public string c { get; set; }

        // Enables sorting for lists of POIs
        public int CompareTo(POI other)
        {
            return String.Compare(id, other.id, StringComparison.Ordinal);
        }

        public bool Equals(POI other)
        {
            return id.Equals(other.id);
        }

        public override int GetHashCode()
        {
            return id == null ? 0 : id.GetHashCode();
        }
    }
}
