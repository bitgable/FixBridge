import Foundation

private final class ElevationFixture: @unchecked Sendable {
    let lock = NSLock()
    private var requests: [URLRequest] = []
    private var status = 200
    private var response: Data?

    func reset(status: Int = 200, response: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        self.response = response.map { Data($0.utf8) }
        requests = []
    }

    func serve(_ request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let items = components.queryItems!
        let latitudes = items.first { $0.name == "latitude" }!.value!.split(separator: ",")
        let longitudes = items.first { $0.name == "longitude" }!.value!.split(separator: ",")
        assert(components.scheme == "https" && components.host == "api.open-meteo.com")
        assert(components.path == "/v1/elevation" && latitudes.count <= 100 && latitudes.count == longitudes.count)
        let values = latitudes.map { Double($0)! + 100 }
        return (status, response ?? (try! JSONSerialization.data(withJSONObject: ["elevation": values])))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

private final class ElevationProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = ElevationFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.fixture.serve(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct TerrainElevationChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let points = try (0..<205).map { index in
            try LocationFix(latitude: Double(index) / 100, longitude: 20, altitude: 0, duration: 3600)
        }
        let fixture = ElevationProtocol.fixture
        fixture.reset()
        let client = TerrainElevation.Client(session: session, spacing: 0)
        let input = points + Array(points.prefix(20))
        let result = try await client.lookup(input)
        assert(result == input.map { $0.latitude + 100 } && fixture.count == 3)
        let cached = try await client.lookup(input)
        assert(cached == result && fixture.count == 3)
        let empty = try await client.lookup([])
        assert(empty.isEmpty && fixture.count == 3)
        for (status, body) in [
            (429, "{}"), (500, "{}"), (200, "invalid"), (200, "{\"elevation\":[1]}"),
            (200, "{\"elevation\":[1,null]}"), (200, "{\"elevation\":[1,100001]}"),
            (200, "{\"elevation\":[1,1e999]}"),
        ] {
            fixture.reset(status: status, response: body)
            let failed = TerrainElevation.Client(session: session, spacing: 0)
            do {
                _ = try await failed.lookup(Array(points.prefix(2)))
                fatalError("Invalid elevation response accepted")
            } catch let error as FixBridgeError {
                if status == 429 { assert(error.message.contains("rate limit")) }
            }
            assert(fixture.count == 1)  // No retry storm after rate limits or malformed responses.
        }
        fixture.reset()
        let cancelled = Task {
            try await Task.sleep(for: .seconds(5))
            return try await client.lookup(points)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancellation ignored")
        } catch is CancellationError {}
        assert(fixture.count == 0)
        print(
            "Elevation checks passed: 100-coordinate batches, deduplication, order, cache, incomplete/null/out-of-range responses, HTTP 429, no retry storm, cancellation. No external requests."
        )
    }
}
