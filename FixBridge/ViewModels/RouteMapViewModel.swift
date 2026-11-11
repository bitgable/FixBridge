import Combine
import MapKit

// These settings affect the preview only. The GPX coordinates sent to the iPhone stay unchanged.
enum RouteMapAlignment: Hashable { case automatic, original, mainland }

@MainActor
final class RouteMapViewModel: ObservableObject {
    struct RegionQuery: Hashable {
        let latitude: Double
        let longitude: Double
        let alignment: RouteMapAlignment
    }

    @Published private(set) var mainlandRegion = false
    @Published private(set) var checkingRegion = false
    @Published private(set) var coordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var markers: [NumberedMapPoint] = []
    @Published private(set) var routeRect = MKMapRect.world
    private var route: GPXRoute?
    private var alignment = RouteMapAlignment.automatic
    private var requestID: UUID?
    private let lookupRegion: (CLLocationCoordinate2D) async throws -> Bool

    init(
        lookupRegion: @escaping (CLLocationCoordinate2D) async throws -> Bool = { coordinate in
            let places = try await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            return places.first?.isoCountryCode == "CN"
        }
    ) {
        self.lookupRegion = lookupRegion
    }

    private var usesMainlandAlignment: Bool {
        alignment == .mainland || (alignment == .automatic && mainlandRegion)
    }

    struct NumberedMapPoint: Identifiable {
        let number: Int
        let point: GPXRoute.Point
        var id: UUID { point.id }
    }

    func coordinate(_ point: GPXRoute.Point) -> CLLocationCoordinate2D {
        let original = CLLocationCoordinate2D(latitude: point.fix.latitude, longitude: point.fix.longitude)
        return usesMainlandAlignment ? MapCoordinateProjection.mainlandDisplay(original) : original
    }

    func update(route: GPXRoute, alignment: RouteMapAlignment) {
        self.route = route
        self.alignment = alignment
        refreshGeometry()
    }

    func resolveRegion(_ query: RegionQuery) async {
        guard !Task.isCancelled else { return }
        alignment = query.alignment
        let id = UUID()
        requestID = id
        mainlandRegion = false
        checkingRegion = query.alignment == .automatic
        refreshGeometry()
        guard query.alignment == .automatic else { return }
        // Canceled geocoding can finish after its replacement. Only the current request owns UI state.
        defer { if requestID == id { checkingRegion = false } }
        do {
            let isMainland = try await lookupRegion(
                .init(latitude: query.latitude, longitude: query.longitude))
            guard !Task.isCancelled, requestID == id else { return }
            mainlandRegion = isMainland
            refreshGeometry()
        } catch {
            // Automatic is a regional recommendation, not provider detection. Manual overrides remain available.
        }
    }

    func cancelRegionLookup() {
        requestID = nil
        checkingRegion = false
    }

    private func refreshGeometry() {
        guard let route else { return }
        coordinates = route.points.map(coordinate)
        // Keep every point in the polyline; limit numbered annotations for very large GPX files.
        let step = max(1, Int(ceil(Double(route.points.count) / 200)))
        markers = stride(from: 1, to: route.points.count - 1, by: step).map {
            NumberedMapPoint(number: $0 + 1, point: route.points[$0])
        }
        var rect = MKMapRect.null
        var previousX: Double?
        let worldWidth = MKMapRect.world.width
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            var x = point.x
            if let previousX {
                while x - previousX > worldWidth / 2 { x -= worldWidth }
                while previousX - x > worldWidth / 2 { x += worldWidth }
            }
            previousX = x
            rect = rect.union(.init(x: x, y: point.y, width: 1, height: 1))
        }
        routeRect = rect.insetBy(dx: -max(rect.width * 0.15, 200), dy: -max(rect.height * 0.15, 200))
    }
}
