import CoreLocation
import Foundation

enum TerrainElevation {
    private static let client = Client()

    static func lookup(_ point: CLLocationCoordinate2D) async -> Double? {
        guard
            let fix = try? LocationFix(
                latitude: point.latitude, longitude: point.longitude,
                altitude: 0, duration: LocationFix.maximumDuration)
        else { return nil }
        return try? await client.lookup([fix]).first
    }

    static func lookupMany(_ points: [LocationFix]) async throws -> [Double] {
        try await client.lookup(points)
    }

    // One shared queue for single-point and route requests. No unbounded fan-out for large files.
    actor Client {
        private struct Coordinate: Hashable {
            let latitude: Double
            let longitude: Double
            init(_ fix: LocationFix) {
                latitude = fix.latitude
                longitude = fix.longitude
            }
        }
        private struct Response: Decodable { let elevation: [Double?] }
        private let session: URLSession
        private let spacing: TimeInterval
        private var busy = false
        private var lastRequest: Date?
        private var cache: [Coordinate: Double] = [:]

        init(session: URLSession = .shared, spacing: TimeInterval = 1.1) {
            self.session = session
            self.spacing = spacing
        }

        func lookup(_ points: [LocationFix]) async throws -> [Double] {
            while busy { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            busy = true
            defer { busy = false }
            for point in points {
                try LocationFix.validateTarget(latitude: point.latitude, longitude: point.longitude, altitude: 0)
            }
            let keys = points.map(Coordinate.init)
            var seen: Set<Coordinate> = []
            let missing = keys.filter { cache[$0] == nil && seen.insert($0).inserted }
            var resolved: [Coordinate: Double] = [:]
            for key in keys { resolved[key] = cache[key] }
            for start in stride(from: 0, to: missing.count, by: 100) {
                try Task.checkCancellation()
                if let lastRequest {
                    let delay = spacing - Date().timeIntervalSince(lastRequest)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                }
                let batch = Array(missing[start..<min(start + 100, missing.count)])
                var endpoint = URLComponents()
                endpoint.scheme = "https"
                endpoint.host = "api.open-meteo.com"
                endpoint.path = "/v1/elevation"
                endpoint.queryItems = [
                    URLQueryItem(name: "latitude", value: batch.map { String($0.latitude) }.joined(separator: ",")),
                    URLQueryItem(name: "longitude", value: batch.map { String($0.longitude) }.joined(separator: ",")),
                ]
                guard let url = endpoint.url else { throw lookupFailure() }
                lastRequest = Date()
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
                } catch {
                    try Task.checkCancellation()
                    throw lookupFailure()
                }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw lookupFailure() }
                if http.statusCode == 429 {
                    // Stop rather than hammering a shared IP quota or waiting indefinitely.
                    throw FixBridgeError(
                        "The elevation service rate limit was reached. The route was not imported. Wait before retrying, or regenerate the GPX file with elevations."
                    )
                }
                guard (200..<300).contains(http.statusCode), data.count <= 1_000_000,
                    let result = try? JSONDecoder().decode(Response.self, from: data),
                    result.elevation.count == batch.count
                else { throw lookupFailure() }
                var values: [Double] = []
                for value in result.elevation {
                    guard let value, value.isFinite, (-100_000...100_000).contains(value) else {
                        throw lookupFailure()
                    }
                    values.append(value)
                }
                if cache.count + batch.count > 10_000 { cache.removeAll(keepingCapacity: true) }
                for (key, value) in zip(batch, values) {
                    resolved[key] = value
                    cache[key] = value
                }
            }
            try Task.checkCancellation()
            return try keys.map { key in
                guard let value = resolved[key] else { throw lookupFailure() }
                return value
            }
        }

        private func lookupFailure() -> FixBridgeError {
            FixBridgeError(
                "Could not retrieve all route elevations. The route was not imported. Check your connection and try again, or regenerate the GPX file with elevations."
            )
        }
    }
}
