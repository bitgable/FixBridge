import Foundation

// Never publish this draft until the user approves and all missing elevations are resolved.
struct GPXMissingElevations: Error, Sendable {
    let route: GPXRoute
    let indices: [Int]
}

struct GPXRoute: Codable, Identifiable, Equatable, Sendable {
    struct Point: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let fix: LocationFix
        let offset: TimeInterval

        init(id: UUID = UUID(), fix: LocationFix, offset: TimeInterval) {
            self.id = id
            self.fix = fix
            self.offset = offset
        }
    }
    let id: UUID
    let name: String
    static let maximumNameBytes = 512
    let points: [Point]
    var duration: TimeInterval { points.last!.offset }
    var start: LocationFix { points[0].fix }

    init(id: UUID = UUID(), name: String, points: [Point]) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= Self.maximumNameBytes, (2...100_000).contains(points.count),
            Set(points.map(\.id)).count == points.count,
            points.first?.offset == 0
        else { throw FixBridgeError("A route needs a name, at least two points, and a first point at 0 seconds.") }
        var previous = -1.0
        for point in points {
            _ = try LocationFix(
                latitude: point.fix.latitude, longitude: point.fix.longitude,
                altitude: point.fix.altitude, duration: point.fix.duration)
            guard point.offset.isFinite, point.offset > previous, point.offset <= 30 * 24 * 3600 else {
                throw FixBridgeError("Point times must increase in route order. Total duration cannot exceed 30 days.")
            }
            previous = point.offset
        }
        self.id = id
        self.name = name
        self.points = points
    }

    struct Statistics: Equatable {
        enum Activity { case stationary, walking, running, cycling, motorVehicle }
        let duration: TimeInterval
        let distance: Double
        var averageSpeed: Double { distance / duration * 3.6 }
        // A rough pace classification, not identification of the actual transport mode.
        var activity: Activity {
            switch averageSpeed {
            case ..<1: .stationary
            case ..<7: .walking
            case ..<15: .running
            case ..<35: .cycling
            default: .motorVehicle
            }
        }
    }

    var statistics: Statistics {
        var distance = 0.0
        for index in 1..<points.count {
            let a = points[index - 1].fix
            let b = points[index].fix
            let latitudeA = a.latitude * .pi / 180
            let latitudeB = b.latitude * .pi / 180
            let deltaLatitude = latitudeB - latitudeA
            let deltaLongitude = (b.longitude - a.longitude) * .pi / 180
            let h =
                pow(sin(deltaLatitude / 2), 2)
                + cos(latitudeA) * cos(latitudeB) * pow(sin(deltaLongitude / 2), 2)
            distance += 6_371_008.8 * 2 * asin(sqrt(min(1, max(0, h))))
        }
        return Statistics(duration: duration, distance: distance)
    }

    func validated() throws -> GPXRoute { try GPXRoute(id: id, name: name, points: points) }

    static func read(_ url: URL) throws -> GPXRoute {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 8_000_000 else {
            throw FixBridgeError("Choose a GPX file smaller than 8 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8_000_001) ?? Data()
        return try parse(data, name: url.deletingPathExtension().lastPathComponent)
    }

    static func parse(_ data: Data, name: String) throws -> GPXRoute {
        guard !data.isEmpty, data.count <= 8_000_000,
            let xml = String(data: data, encoding: .utf8),
            !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
            !xml.localizedCaseInsensitiveContains("<!ENTITY")
        else { throw FixBridgeError("The GPX file is empty, too large, or contains unsupported XML.") }
        // Missing elevations use a private placeholder only; the draft cannot be imported as-is.
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.points.count >= 2 else {
            if let error = delegate.error { throw error }
            throw FixBridgeError(
                "Choose a GPX file containing a single track segment or route with at least two points. Each point needs valid coordinates and a timestamp later than the previous point."
            )
        }
        let route = try GPXRoute(name: name, points: delegate.points)
        if !delegate.missingElevations.isEmpty {
            throw GPXMissingElevations(route: route, indices: delegate.missingElevations)
        }
        return route
    }

    func fix(at elapsed: TimeInterval) -> LocationFix {
        guard elapsed > 0 else { return start }
        guard elapsed < duration else { return points.last!.fix }
        var lower = 0
        var upper = points.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if points[middle].offset <= elapsed { lower = middle } else { upper = middle }
        }
        let a = points[lower]
        let b = points[upper]
        let fraction = (elapsed - a.offset) / (b.offset - a.offset)
        let deltaLongitude = (b.fix.longitude - a.fix.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let longitude = (a.fix.longitude + deltaLongitude * fraction + 540).truncatingRemainder(dividingBy: 360) - 180
        return
            (try? LocationFix(
                latitude: a.fix.latitude + (b.fix.latitude - a.fix.latitude) * fraction,
                longitude: longitude,
                altitude: a.fix.altitude + (b.fix.altitude - a.fix.altitude) * fraction,
                duration: LocationFix.maximumDuration)) ?? a.fix
    }
}

private final class GPXParser: NSObject, XMLParserDelegate {
    var points: [GPXRoute.Point] = []
    var valid = true
    var error: FixBridgeError?
    var missingElevations: [Int] = []
    private var stack: [String] = []
    private var groups = 0
    private var latitude: Double?
    private var longitude: Double?
    private var elevation: String?
    private var timestamp: String?
    private var text = ""
    private var firstTime: Date?
    private var lastTime: Date?
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    override init() {
        super.init()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        if Task.isCancelled {
            fail(parser)
            return
        }
        let parent = stack.last
        stack.append(elementName)
        guard stack.count <= 128 else {
            fail(parser)
            return
        }
        text = ""
        if stack.count == 1 && elementName != "gpx" { fail(parser) }
        if elementName == "trkseg" || elementName == "rte" {
            groups += 1
            if groups > 1 { fail(parser) }
        }
        if elementName == "trkpt" || elementName == "rtept" {
            guard (elementName == "trkpt" && parent == "trkseg") || (elementName == "rtept" && parent == "rte"),
                points.count < 100_000
            else {
                fail(parser)
                return
            }
            latitude = attributes["lat"].flatMap(Double.init)
            longitude = attributes["lon"].flatMap(Double.init)
            elevation = nil
            timestamp = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer {
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }
        let parent = stack.dropLast().last
        if parent == "trkpt" || parent == "rtept" {
            if elementName == "ele" {
                guard elevation == nil else {
                    fail(parser)
                    return
                }
                elevation = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if elementName == "time" {
                guard timestamp == nil else {
                    fail(parser)
                    return
                }
                timestamp = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard elementName == "trkpt" || elementName == "rtept" else { return }
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else {
            error = FixBridgeError("Cannot import GPX. Every route point must include valid latitude and longitude.")
            fail(parser)
            return
        }
        guard let timestamp,
            let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp)
        else {
            error = FixBridgeError(
                "Cannot import GPX. Every route point must include a valid timestamp. Regenerate the file with timestamps."
            )
            fail(parser)
            return
        }
        guard lastTime.map({ date > $0 }) ?? true else {
            error = FixBridgeError("Cannot import GPX. Timestamps must increase in route order.")
            fail(parser)
            return
        }
        let missing = elevation == nil || elevation?.isEmpty == true
        guard let altitude = missing ? 0 : elevation.flatMap(Double.init),
            let fix = try? LocationFix(
                latitude: latitude, longitude: longitude, altitude: altitude,
                duration: LocationFix.maximumDuration)
        else {
            error = FixBridgeError(
                "Cannot import GPX. Elevations must be valid numbers between −100,000 and 100,000 meters.")
            fail(parser)
            return
        }
        if missing { missingElevations.append(points.count) }
        if firstTime == nil { firstTime = date }
        let offset = date.timeIntervalSince(firstTime!)
        guard offset.isFinite, offset <= 30 * 24 * 3600 else {
            fail(parser)
            return
        }
        points.append(.init(fix: fix, offset: offset))
        lastTime = date
    }

    private func fail(_ parser: XMLParser) {
        valid = false
        parser.abortParsing()
    }
}

enum RoutePlaybackState: Sendable { case ready, playing, paused, finished }
struct RoutePlaybackSnapshot: Sendable {
    let state: RoutePlaybackState
    let elapsed: TimeInterval
}

// Shared presentation names for the preview popover and the main route summary.
extension GPXRoute.Statistics.Activity {
    var localizedTitle: String {
        switch self {
        case .stationary: String(localized: "Stationary")
        case .walking: String(localized: "Walking")
        case .running: String(localized: "Running")
        case .cycling: String(localized: "Cycling")
        case .motorVehicle: String(localized: "Motor Vehicle")
        }
    }
}
