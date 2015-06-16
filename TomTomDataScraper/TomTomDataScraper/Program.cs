using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using iAnywhere.Data.SQLAnywhere;

namespace TomTomDataScraper
{
	class Program
	{
		public const string Zoom = "7";
		static void Main()
		{
			// Show trace messages in tracefile.log and the console
			var traceFile = File.CreateText(@"tracefile.log");
			var listener = new TextWriterTraceListener(traceFile);
			Trace.Listeners.Add(listener);
			Trace.Listeners.Add(new ConsoleTraceListener());
			Trace.AutoFlush = true;

			// Create SQLAnywhere connection
			var myConnection = new SAConnection(Properties.Settings.Default.SAConnectionString);

			// Coordinates defining a square grid around Toronto
			var lowerLeftLatitude = 43;
			var lowerLeftLongitude = -80;
			var upperRightLatitude = 45;
			var upperRightLongitude = -78;

			while (true)
			{
				try
				{
					// Request URL for TomTom web service
					string reqUri =
			 String.Format("http://www.tomtom.com/livetraffic/lbs/services/traffic/tm/1/{0},{1},{2},{3}/{4}/0,0,0,0/0/json/2bbdd0e2-6452-494a-b6b6-5aceb39048eb;projection=EPSG900913;language=en;style=s3;expandCluster=true",
							 MercatorProjection.latToY(lowerLeftLatitude), MercatorProjection.lonToX(lowerLeftLongitude),
							 MercatorProjection.latToY(upperRightLatitude), MercatorProjection.lonToX(upperRightLongitude),
							 Zoom);
					var request = (HttpWebRequest)WebRequest.Create(reqUri);
					// Need to go through the SAP proxy
					request.Proxy = new WebProxy(Properties.Settings.Default.ProxyHost, 8080);
					var response = request.GetResponse();
					Trace.WriteLine(DateTime.Now + "\tGot response for request");
					var responseStream = response.GetResponseStream();
					Debug.Assert(responseStream != null, "ResponseStream is null");
					var readStream = new StreamReader(responseStream, Encoding.UTF8);
					// Response JSON contains a @id element which isn't a valid
					// variable name in C#. Need to replace it to deserialize
					var result = readStream.ReadToEnd().Replace("@id", "id");
					var jss = new JavaScriptSerializer();
					// Deserialize into a list of POIs
					var data = jss.Deserialize<ResultContainer>(result);
					if (data.tm.poi == null) continue;
					var pois = new List<POI>();

					// Expand clusters in the list by extracting the cpoi element
					foreach (POI poi in data.tm.poi)
					{
						if (poi.cs == 0)
						{
							pois.Add(poi);
						}
						else if (poi.cpoi != null)
						{
							pois.AddRange(poi.cpoi);
						}
					}
					pois.Sort();

					// Open the SQLAnywhere connection 
					myConnection.Open();
					var insertCmd = new SACommand("INSERT INTO Traffic(request_time, jam_id, description, jam_type, severity, latitude, longitude, starting, ending, road, delayLength, delayTime, cause) " +
										"VALUES( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )", myConnection);
					// request_time
					var parm = new SAParameter { SADbType = SADbType.DateTime };
					insertCmd.Parameters.Add(parm);
					// jam_id
					parm = new SAParameter { SADbType = SADbType.VarChar };
					insertCmd.Parameters.Add(parm);
					// description
					parm = new SAParameter { SADbType = SADbType.VarChar };
					insertCmd.Parameters.Add(parm);
					// jam_type
					parm = new SAParameter { SADbType = SADbType.Integer };
					insertCmd.Parameters.Add(parm);
					// severity
					parm = new SAParameter { SADbType = SADbType.Integer };
					insertCmd.Parameters.Add(parm);
					// latitude
					parm = new SAParameter { SADbType = SADbType.Double };
					insertCmd.Parameters.Add(parm);
					// longitude
					parm = new SAParameter { SADbType = SADbType.Double };
					insertCmd.Parameters.Add(parm);
					// starting
					parm = new SAParameter { SADbType = SADbType.VarChar };
					insertCmd.Parameters.Add(parm);
					// ending
					parm = new SAParameter { SADbType = SADbType.VarChar };
					insertCmd.Parameters.Add(parm);
					// road
					parm = new SAParameter { SADbType = SADbType.VarChar };
					insertCmd.Parameters.Add(parm);
					// delayLength
					parm = new SAParameter { SADbType = SADbType.BigInt };
					insertCmd.Parameters.Add(parm);
					// delayTime
					parm = new SAParameter { SADbType = SADbType.BigInt };
					insertCmd.Parameters.Add(parm);
					// cause
					parm = new SAParameter { SADbType = SADbType.VarChar };
					insertCmd.Parameters.Add(parm);

					foreach (POI poi in pois)
					{
						// Convert the timestamp in the response from unix timestamp to DateTime
						insertCmd.Parameters[0].Value = UnixTimeStamp.ConvertFromUnixTimestamp(Double.Parse(data.tm.id));
						insertCmd.Parameters[1].Value = poi.id;
						insertCmd.Parameters[2].Value = poi.d;
						insertCmd.Parameters[3].Value = poi.ic;
						insertCmd.Parameters[4].Value = poi.ty;
						// Convert coordinates from EPSG900913 to WGS84
						insertCmd.Parameters[5].Value = MercatorProjection.yToLat(poi.p.y);
						insertCmd.Parameters[6].Value = MercatorProjection.xToLon(poi.p.x);
						insertCmd.Parameters[7].Value = poi.f;
						insertCmd.Parameters[8].Value = poi.t;
						insertCmd.Parameters[9].Value = poi.r;
						insertCmd.Parameters[10].Value = poi.l;
						insertCmd.Parameters[11].Value = poi.dl;
						insertCmd.Parameters[12].Value = poi.c;
						insertCmd.ExecuteNonQuery();
					}
				}
				catch (Exception e)
				{
					Trace.WriteLine(DateTime.Now + "\t" + e.Message);
				}
				finally
				{
					// Close the connection. 
					myConnection.Close();
					// Sleep for 2 minutes
					Thread.Sleep(2 * 60 * 1000);
				}
			}
		}
	}
}
