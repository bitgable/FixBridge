import CoreLocation
import Foundation

/// Display-only approximation for GCJ-02 tiles. Never use this result for GPX storage or NMEA.
/// WGS84/GCJ02 equations adapted from wandergis/coordtransform (MIT); see ThirdPartyNotices.txt.
enum MapCoordinateProjection {
    static func mainlandDisplay(_ source: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let latitude = source.latitude
        let longitude = source.longitude
        // This is a coarse applicability bound, not a national boundary or provider detector.
        guard CLLocationCoordinate2DIsValid(source), longitude > 73.66, longitude < 135.05,
            latitude > 3.86, latitude < 53.55
        else { return source }
        let x = longitude - 105
        let y = latitude - 35
        let pi = Double.pi
        let common = (20 * sin(6 * x * pi) + 20 * sin(2 * x * pi)) * 2 / 3
        var north = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x)) + common
        north += (20 * sin(y * pi) + 40 * sin(y * pi / 3)) * 2 / 3
        north += (160 * sin(y * pi / 12) + 320 * sin(y * pi / 30)) * 2 / 3
        var east = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x)) + common
        east += (20 * sin(x * pi) + 40 * sin(x * pi / 3)) * 2 / 3
        east += (150 * sin(x * pi / 12) + 300 * sin(x * pi / 30)) * 2 / 3
        let a = 6_378_245.0
        let eccentricity = 0.00669342162296594323
        let radians = latitude * pi / 180
        let m = 1 - eccentricity * pow(sin(radians), 2)
        return .init(
            latitude: latitude + north * 180 / (a * (1 - eccentricity) / (m * sqrt(m)) * pi),
            longitude: longitude + east * 180 / (a / sqrt(m) * cos(radians) * pi))
    }
}
