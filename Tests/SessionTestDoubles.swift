import CoreFoundation
// Test-only boundaries. The production view model is compiled unchanged against these doubles.
import CoreLocation
import Foundation

struct MFIIdentity: Sendable {
    struct Certificate: Sendable {}
    struct CertificateValidity: Sendable {}
    var certificateValidity: CertificateValidity? { nil }
}
enum IdentityStore {
    static func load() throws -> MFIIdentity? { MFIIdentity() }
    static func readCertificate(_ url: URL) throws -> MFIIdentity.Certificate { .init() }
    static func save(certificate: MFIIdentity.Certificate, key: URL) throws -> MFIIdentity { .init() }
}
struct BluetoothDevice: Identifiable, Sendable {
    let name: String
    let address: String
    let connected: Bool
    var id: String { address }
    var title: String { name.isEmpty ? address : name }
    static func pairedDevices() throws -> [Self] {
        SessionTestDriver.shared.update { $0.discoveries += 1 }
        let state = SessionTestDriver.shared.snapshot()
        Thread.sleep(forTimeInterval: state.discoveryDelay)
        return state.devices
    }
}
enum AccessoryConnection: Sendable {
    case usb(String)
    case bluetooth(BluetoothDevice)
}
enum AccessoryEvent: Sendable {
    case transportConnected, linkReady, authenticated
    case reconnecting(Int)
    case subscribed([Int])
    case unsubscribed
    case acknowledged(Int)
    case locationSent(sequence: Int, fix: LocationFix, time: Date)
}
enum PhoneSettings {
    enum Target: Sendable {
        case usb(String)
        case bluetooth(uniqueName: String?)
    }
    static func wiredDeviceNames() throws -> [String: String] { [:] }
    static func openLocationServices(for target: Target) async throws {}
}
// Keep the exact C bridge symbol used by the production view model.
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_copy_identifiers() -> CFArray? { nil }

final class SessionTestDriver: @unchecked Sendable {
    static let shared = SessionTestDriver()
    struct State {
        var locationBurstCount = 1
        var devices = [BluetoothDevice(name: "Phone", address: "00:11:22:33:44:55", connected: false)]
        var discoveryDelay = 0.0
        var discoveries = 0
        var preflightDelay = 0.0
        var failPreflight = false
        var reconnectRequested = false
        var movementEnabled: Bool?
        var sessions = 0
        var preflights = 0
    }
    private let lock = NSLock()
    private var state = State()
    func snapshot() -> State { lock.withLock { state } }
    func update(_ action: (inout State) -> Void) { lock.withLock { action(&state) } }
    func reset() { lock.withLock { state = State() } }
}
enum AccessorySession {
    static func run(
        connection: AccessoryConnection, identity: MFIIdentity, fix: LocationFix?, locations: SessionLocation? = nil,
        refreshState: LocationRefreshState? = nil,
        emit: (AccessoryEvent) -> Void
    ) throws {
        let driver = SessionTestDriver.shared
        if fix == nil {
            driver.update { $0.preflights += 1 }
            let snapshot = driver.snapshot()
            // Intentionally ignore cancellation here to exercise stale native callbacks.
            Thread.sleep(forTimeInterval: snapshot.preflightDelay)
            emit(.transportConnected)
            if snapshot.failPreflight {
                throw FixBridgeError("Native link closed", recovery: .bluetoothConnection)
            }
            return
        }
        let movementEnabled = locations?.sample(at: 0).movementEnabled
        driver.update {
            $0.sessions += 1
            $0.movementEnabled = movementEnabled
        }
        emit(.transportConnected)
        emit(.authenticated)
        emit(.subscribed([1, 2]))
        let sentFix = locations?.sample(at: 0).fix ?? fix!
        for index in 1...max(1, driver.snapshot().locationBurstCount) {
            emit(.acknowledged(index))
            emit(.locationSent(sequence: index, fix: sentFix, time: Date()))
        }
        var reconnectSent = false
        while !Task.isCancelled {
            if !reconnectSent && driver.snapshot().reconnectRequested {
                reconnectSent = true
                emit(.reconnecting(1))
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // Simulate callbacks already queued when the user presses Stop.
        emit(.authenticated)
        emit(.acknowledged(999))
        emit(.locationSent(sequence: 999, fix: sentFix, time: Date()))
        throw CancellationError()
    }
}

// Deliberately return even after cancellation to exercise stale elevation responses.
enum TerrainElevation {
    static func lookupMany(_ points: [LocationFix]) async throws -> [Double] {
        throw FixBridgeError("Unexpected network lookup in regression checks.")
    }

    static func lookup(_ point: CLLocationCoordinate2D) async -> Double? {
        try? await Task.sleep(for: .milliseconds(80))
        return 123
    }
}
