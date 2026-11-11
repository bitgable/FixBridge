import Foundation

/// One session's fixed origin, bounded drift, or GPX playback, shared safely with the transport.
final class SessionLocation: @unchecked Sendable {
    static let radiusMeters = 1.5

    struct Sample: Sendable {
        let fix: LocationFix
        let movementEnabled: Bool
    }

    private let lock = NSLock()
    let route: GPXRoute?
    private var routeState = RoutePlaybackState.ready
    private var routeElapsed: TimeInterval = 0
    private var routeSampleTime: TimeInterval?
    private let origin: LocationFix
    private var enabled = false
    private var randomState: UInt64
    private var segmentStart: TimeInterval?
    private var duration = 8.0
    private var east = 0.0
    private var north = 0.0
    private var fromEast = 0.0
    private var fromNorth = 0.0
    private var targetEast = 0.0
    private var targetNorth = 0.0

    init(fix: LocationFix, route: GPXRoute? = nil, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        self.route = route
        origin = route?.start ?? fix
        randomState = seed
    }

    var canBeginMovement: Bool { lock.withLock { route == nil && !enabled } }

    @discardableResult
    func beginMovement() -> Bool {
        lock.withLock {
            guard !enabled, route == nil else { return false }
            enabled = true
            return true
        }
    }

    func sample(at time: TimeInterval) -> Sample {
        lock.withLock {
            if let route {
                if routeState == .playing, time.isFinite {
                    if let previous = routeSampleTime {
                        routeElapsed = min(route.duration, routeElapsed + max(0, time - previous))
                    }
                    routeSampleTime = time
                    if routeElapsed >= route.duration { routeState = .finished }
                }
                return Sample(fix: route.fix(at: routeElapsed), movementEnabled: routeState == .playing)
            }
            guard enabled, time.isFinite else { return Sample(fix: origin, movementEnabled: enabled) }
            if segmentStart == nil || time < segmentStart! {
                startSegment(at: time)
            }
            let progress = min(1, max(0, (time - segmentStart!) / duration))
            let smooth = progress * progress * (3 - 2 * progress)
            east = fromEast + (targetEast - fromEast) * smooth
            north = fromNorth + (targetNorth - fromNorth) * smooth
            if progress == 1 { startSegment(at: time) }
            return Sample(fix: displacedFix(), movementEnabled: true)
        }
    }

    // On resume start from the last emitted offset; never jump ahead during a subscription pause.
    func pause() {
        lock.withLock {
            segmentStart = nil
            routeSampleTime = nil
        }
    }

    var routeSnapshot: RoutePlaybackSnapshot {
        lock.withLock { RoutePlaybackSnapshot(state: routeState, elapsed: routeElapsed) }
    }

    func playRoute() {
        lock.withLock {
            guard route != nil, routeState == .ready || routeState == .paused else { return }
            routeState = .playing
            routeSampleTime = nil
        }
    }

    func pauseRoute() {
        lock.withLock {
            guard routeState == .playing else { return }
            routeState = .paused
            routeSampleTime = nil
        }
    }

    private func startSegment(at time: TimeInterval) {
        fromEast = east
        fromNorth = north
        let angle = randomUnit() * 2 * .pi
        let radius = sqrt(randomUnit()) * Self.radiusMeters
        targetEast = cos(angle) * radius
        targetNorth = sin(angle) * radius
        duration = 8 + randomUnit() * 6
        segmentStart = time
    }

    private func randomUnit() -> Double {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992
    }

    private func displacedFix() -> LocationFix {
        let distance = hypot(east, north)
        guard distance > 0 else { return origin }
        let arc = distance / 6_371_008.8
        let bearing = atan2(east, north)
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180
        let nextLatitude = asin(max(-1, min(1, sin(latitude) * cos(arc) + cos(latitude) * sin(arc) * cos(bearing))))
        let nextLongitude =
            longitude
            + atan2(
                sin(bearing) * sin(arc) * cos(latitude), cos(arc) - sin(latitude) * sin(nextLatitude))
        let degrees = nextLongitude * 180 / .pi
        return
            (try? LocationFix(
                latitude: nextLatitude * 180 / .pi,
                longitude: (degrees + 540).truncatingRemainder(dividingBy: 360) - 180,
                altitude: origin.altitude, duration: origin.duration)) ?? origin
    }
}
