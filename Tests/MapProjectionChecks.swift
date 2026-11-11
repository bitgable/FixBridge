import CoreLocation
import Foundation

extension RegressionChecks {
    static func checkMapProjection() {
        let beijing = MapCoordinateProjection.mainlandDisplay(.init(latitude: 39.916527, longitude: 116.397128))
        assert(abs(beijing.latitude - 39.91793074924595) < 1e-9)
        assert(abs(beijing.longitude - 116.40337249402477) < 1e-9)
        let park = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009)
        let unchanged = MapCoordinateProjection.mainlandDisplay(park)
        assert(unchanged.latitude == park.latitude && unchanged.longitude == park.longitude)
        let origin = CLLocationCoordinate2D(latitude: 24.861606, longitude: 102.854081)
        let display = MapCoordinateProjection.mainlandDisplay(origin)
        let distance = CLLocation(latitude: display.latitude, longitude: display.longitude).distance(
            from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
        assert(display.latitude < origin.latitude && display.longitude > origin.longitude)
        assert(distance > 200 && distance < 800)
        let pole = MapCoordinateProjection.mainlandDisplay(.init(latitude: 90, longitude: 180))
        assert(pole.latitude == 90 && pole.longitude == 180)
        print(
            "Map projection checks passed: reference coordinates, outside-region identity, bounded local offset. Display projection does not mutate route input."
        )
    }
}
