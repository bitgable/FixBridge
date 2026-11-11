import Combine
import Foundation

/// Coordinates device readiness and one accessory session for the window.
/// Generation checks reject callbacks from stopped sessions or windows that have already closed.
@MainActor
final class FixBridgeViewModel: ObservableObject {
    // MARK: - Types
    struct PreflightRequest: Equatable {
        let mode: ConnectionMode
        let deviceID: String
        let revision: Int
    }

    enum Preflight {
        case idle, checking, connected, passed
        case failed(String, connected: Bool)

        var isChecking: Bool {
            switch self {
            case .checking, .connected: true
            default: false
            }
        }

        var linkVerified: Bool {
            switch self {
            case .connected, .passed: true
            case .failed(_, let connected): connected
            default: false
            }
        }

        var passed: Bool {
            if case .passed = self { return true }
            return false
        }

        var error: String? {
            if case .failed(let message, _) = self { return message }
            return nil
        }
    }

    enum StatusKind {
        case normal, working, success, error
    }

    struct StatusDisplay {
        let message: String
        let kind: StatusKind
    }

    struct DeviceChoice: Identifiable {
        let id: String
        let title: String
    }

    private enum PreferenceKey {
        static let connectionMode = "preferredConnectionMode"
        static let simulationMode = "preferredSimulationMode"
    }
    private let defaults: UserDefaults

    // MARK: - State

    @Published private(set) var hasIdentity = false
    var certificateValidity: MFIIdentity.CertificateValidity? { identity?.certificateValidity }
    @Published private(set) var importingCredentials = false
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published var usbDeviceID: String? {
        didSet {
            if usbDeviceID != oldValue, usbDeviceID != nil { resetSessionSummary() }
        }
    }
    @Published private(set) var usbDeviceIDs: [String] = []
    @Published private var usbDeviceNames: [String: String] = [:]

    @Published var mode = ConnectionMode.usb {
        didSet {
            if mode != oldValue {
                defaults.set(mode.rawValue, forKey: PreferenceKey.connectionMode)
                resetSessionSummary()
            }
        }
    }
    @Published var bluetoothDeviceID: BluetoothDevice.ID? {
        didSet {
            if bluetoothDeviceID != oldValue, bluetoothDeviceID != nil { resetSessionSummary() }
        }
    }
    @Published private(set) var bluetoothDevices: [BluetoothDevice] = []
    @Published private(set) var loadingBluetoothDevices = false
    @Published private(set) var loadingUSBDeviceNames = false
    @Published private(set) var preflight = Preflight.idle
    @Published private var preflightRevision = 0
    @Published private(set) var transportConnected = false

    @Published private(set) var authenticated = false
    @Published private(set) var sending = false
    struct SentLocation: Identifiable {
        let id = UUID()
        let sequence: Int
        let fix: LocationFix
        let line: String

        init(sequence: Int, fix: LocationFix, time: Date) {
            self.sequence = sequence
            self.fix = fix
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            line = String(
                format: "%@ #%d  lat=%.7f lon=%.7f alt=%.2f m",
                locale: Locale(identifier: "en_US_POSIX"), formatter.string(from: time),
                sequence, fix.latitude, fix.longitude, fix.altitude)
        }
    }
    @Published private(set) var sentLocations: [SentLocation] = []
    static let maximumSentLocations = 200
    @Published private(set) var delivered = 0
    @Published private(set) var sessionInterrupted = false
    @Published private(set) var hasStartedSession = false
    @Published private var status: String?
    @Published private var error: String?
    private var identity: MFIIdentity?
    private var task: Task<Void, Never>?
    private var refreshState = LocationRefreshState()
    private weak var activeRouteModel: GPXRouteViewModel?
    private var sessionLocation: SessionLocation?
    @Published private(set) var movementRunning = false

    @Published private(set) var simulationMode = SimulationMode.normal {
        didSet {
            if simulationMode != oldValue {
                defaults.set(simulationMode.rawValue, forKey: PreferenceKey.simulationMode)
            }
        }
    }

    func selectSimulationMode(_ mode: SimulationMode) {
        guard !running, !stopping else { return }
        simulationMode = mode
    }

    private var credentialImportTask: Task<Void, Never>?
    private var usbNameTask: Task<Void, Never>?
    private var bluetoothDiscoveryTask: Task<Void, Never>?
    private var bluetoothDiscoveryID: UUID?
    private var windowIsClosed = false
    private var windowGeneration = 0
    private var sessionGeneration = 0
    private var preflightTask: Task<Void, Never>?
    private var checkedRequest: PreflightRequest?
    private var preflightGeneration = 0
    private var settingsTask: Task<Void, Never>?
    private var sessionSettingsTarget: PhoneSettings.Target?
    private var openSettingsAfterStop = false

    // MARK: - Presentation

    private var selectedConnection: AccessoryConnection? {
        switch mode {
        case .usb:
            guard let usbDeviceID, usbDeviceIDs.contains(usbDeviceID) else { return nil }
            return .usb(usbDeviceID)
        case .bluetooth:
            return bluetoothDevice.map(AccessoryConnection.bluetooth)
        }
    }

    var preflightRequest: PreflightRequest? {
        guard hasIdentity, let connection = selectedConnection else { return nil }
        let deviceID: String
        switch connection {
        case .usb(let id): deviceID = id
        case .bluetooth(let device): deviceID = device.id
        }
        return PreflightRequest(mode: mode, deviceID: deviceID, revision: preflightRevision)
    }

    private var statusMessage: String {
        if !running && !stopping && selectedConnection == nil {
            if mode == .bluetooth { return String(localized: "Select a paired iPhone.") }
            return usbDeviceIDs.isEmpty
                ? String(localized: "Connect and unlock your iPhone.")
                : String(localized: "Select a USB iPhone.")
        }
        if let status { return status }
        switch preflight {
        case .checking: return String(localized: "Checking the accessory connection…")
        case .connected: return String(localized: "Checking MFi authentication…")
        case .passed: return String(localized: "Connection and MFi checks passed. Ready to start.")
        case .failed(let message, _): return message
        case .idle: break
        }
        return hasIdentity
            ? String(localized: "Ready to check the accessory connection.")
            : String(localized: "Import the MFi certificate and private key to check the connection.")
    }

    func statusDisplay(locationError: String?, routePlayback: RoutePlaybackSnapshot? = nil) -> StatusDisplay {
        // One presentation path for all errors, so a generic status never repeats them.
        if let message = error ?? locationError ?? preflight.error {
            return StatusDisplay(message: message, kind: .error)
        }
        if running, !stopping, sending, let routePlayback {
            switch routePlayback.state {
            case .ready:
                return StatusDisplay(
                    message: String(localized: "Holding at the route’s start. Click Start Route to begin playback."),
                    kind: .normal)
            case .playing:
                return StatusDisplay(message: String(localized: "Playing the route."), kind: .normal)
            case .paused:
                return StatusDisplay(
                    message: String(localized: "Route paused. Holding position. Click Resume Route to continue."),
                    kind: .normal)
            case .finished:
                return StatusDisplay(
                    message: String(localized: "Route finished. Holding the endpoint until you click Stop."),
                    kind: .success)
            }
        }
        let ready =
            !running && !stopping && status == nil && preflight.passed
            && preflightRequest == checkedRequest
        let working = preflight.isChecking || stopping || (running && !sending)
        let kind: StatusKind = ready ? .success : (working ? .working : .normal)
        return StatusDisplay(message: statusMessage, kind: kind)
    }

    var canStart: Bool {
        !windowIsClosed && preflight.passed && preflightRequest == checkedRequest && !running && !stopping
            && !loadingBluetoothDevices && !importingCredentials
    }

    private var bluetoothDevice: BluetoothDevice? {
        bluetoothDevices.first { $0.id == bluetoothDeviceID }
    }

    var deviceChoices: [DeviceChoice] {
        switch mode {
        case .usb:
            usbDeviceIDs.map { DeviceChoice(id: $0, title: usbDeviceTitle($0)) }
        case .bluetooth:
            bluetoothDevices.map { device in
                let duplicated = bluetoothDevices.filter { $0.title == device.title }.count > 1
                let title = duplicated ? "\(device.title) (\(device.address.suffix(5)))" : device.title
                return DeviceChoice(id: device.id, title: title)
            }
        }
    }

    var selectedDeviceID: String? {
        get { mode == .usb ? usbDeviceID : bluetoothDeviceID }
        set {
            guard !running, !stopping else { return }
            if mode == .usb { usbDeviceID = newValue } else { bluetoothDeviceID = newValue }
        }
    }

    var selectedDeviceTitle: String {
        deviceChoices.first { $0.id == selectedDeviceID }?.title ?? String(localized: "Select an iPhone")
    }

    var loadingDevices: Bool {
        mode == .usb ? loadingUSBDeviceNames : loadingBluetoothDevices
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ConnectionMode(rawValue: defaults.string(forKey: PreferenceKey.connectionMode) ?? "") ?? .usb
        simulationMode =
            SimulationMode(rawValue: defaults.string(forKey: PreferenceKey.simulationMode) ?? "") ?? .normal
        do {
            identity = try IdentityStore.load()
            hasIdentity = identity != nil
        } catch {
            self.error = FixBridgeError.statusMessage(for: error)
        }
    }

    private func resetSessionSummary() {
        guard !running, !stopping else { return }
        status = nil
        error = nil
        sessionInterrupted = false
        hasStartedSession = false
        delivered = 0
    }

    // MARK: - Window lifecycle

    func openWindow() {
        windowIsClosed = false
    }

    func closeWindow() {
        windowIsClosed = true
        windowGeneration += 1
        credentialImportTask?.cancel()
        usbNameTask?.cancel()
        bluetoothDiscoveryTask?.cancel()
        bluetoothDiscoveryTask = nil
        bluetoothDiscoveryID = nil
        loadingBluetoothDevices = false
        cancelPreflight()
        openSettingsAfterStop = false
        settingsTask?.cancel()
        settingsTask = nil
        if running { stop() } else { stopping = false }
    }

    // MARK: - Credentials

    func readCertificate(_ url: URL) async throws -> MFIIdentity.Certificate {
        try await BackgroundTask.run(priority: .userInitiated) {
            try IdentityStore.readCertificate(url)
        }
    }

    func importIdentity(certificate: MFIIdentity.Certificate, key: URL) {
        guard !windowIsClosed, !running, !stopping, !importingCredentials else { return }
        importingCredentials = true
        error = nil
        let generation = windowGeneration
        credentialImportTask = Task {
            defer {
                importingCredentials = false
                credentialImportTask = nil
            }
            do {
                let imported = try await BackgroundTask.run(priority: .userInitiated) {
                    try IdentityStore.save(certificate: certificate, key: key)
                }
                guard !windowIsClosed, windowGeneration == generation else { return }
                identity = imported
                hasIdentity = true
                retryPreflight()
            } catch is CancellationError {
                return
            } catch {
                guard !windowIsClosed, windowGeneration == generation else { return }
                self.error = FixBridgeError.statusMessage(for: error)
            }
        }
    }

    // MARK: - Device discovery

    func monitorUSB() async {
        let generation = windowGeneration
        while !Task.isCancelled && !windowIsClosed {
            guard
                let ids = try? await BackgroundTask.run(operation: {
                    let list = fb_usb_copy_identifiers() as? [String] ?? []
                    return Set(list).sorted()
                }), !windowIsClosed, windowGeneration == generation
            else { return }
            if usbDeviceIDs != ids {
                usbDeviceIDs = ids
                if !ids.contains(usbDeviceID ?? "") {
                    usbDeviceID = ids.count == 1 ? ids.first : nil
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refreshUSBDeviceNames() async {
        guard !windowIsClosed, !usbDeviceIDs.isEmpty else { return }
        if let usbNameTask {
            await usbNameTask.value
            return
        }
        // Coalesce list changes without cancelling the current lookup when a cable changes.
        let generation = windowGeneration
        loadingUSBDeviceNames = true
        let lookup = Task {
            defer {
                loadingUSBDeviceNames = false
                usbNameTask = nil
            }
            var requestedIDs: [String]
            repeat {
                requestedIDs = usbDeviceIDs
                let names = try? await BackgroundTask.run { try PhoneSettings.wiredDeviceNames() }
                guard !Task.isCancelled, !windowIsClosed, windowGeneration == generation else { return }
                if let names {
                    let connectedIDs = Set(usbDeviceIDs.map { $0.lowercased() })
                    usbDeviceNames = names.filter { connectedIDs.contains($0.key) }
                }
            } while !usbDeviceIDs.isEmpty && usbDeviceIDs != requestedIDs
        }
        usbNameTask = lookup
        await lookup.value
    }

    private func usbDeviceTitle(_ id: String) -> String {
        let name = usbDeviceNames[id.lowercased()]
        if let name, usbDeviceIDs.filter({ usbDeviceNames[$0.lowercased()] == name }).count == 1 {
            return name
        }
        return "\(name ?? "iPhone") (\(id.suffix(6)))"
    }

    func refreshBluetoothDevices() async {
        guard !windowIsClosed, mode == .bluetooth, !running, !stopping else { return }
        // SwiftUI cancels its task when the transport changes. Discovery belongs to this window,
        // so switching back joins the in-flight request instead of leaving an empty device list.
        if let bluetoothDiscoveryTask {
            await bluetoothDiscoveryTask.value
            return
        }
        let generation = windowGeneration
        let id = UUID()
        bluetoothDiscoveryID = id
        loadingBluetoothDevices = true
        let lookup = Task { [weak self] in
            guard let self else { return }
            defer {
                if bluetoothDiscoveryID == id {
                    loadingBluetoothDevices = false
                    bluetoothDiscoveryTask = nil
                    bluetoothDiscoveryID = nil
                }
            }
            do {
                let devices = try await BackgroundTask.run { try BluetoothDevice.pairedDevices() }
                guard !Task.isCancelled, !windowIsClosed, windowGeneration == generation, bluetoothDiscoveryID == id,
                    mode == .bluetooth, !running,
                    !stopping
                else { return }
                bluetoothDevices = devices
                if bluetoothDevice == nil {
                    let connected = devices.filter(\.connected)
                    bluetoothDeviceID =
                        devices.count == 1
                        ? devices.first?.id
                        : (connected.count == 1 ? connected.first?.id : nil)
                }
                error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !windowIsClosed, windowGeneration == generation, bluetoothDiscoveryID == id,
                    mode == .bluetooth, !running,
                    !stopping
                else { return }
                bluetoothDevices = []
                bluetoothDeviceID = nil
                self.error = FixBridgeError.statusMessage(for: error)
            }
        }
        bluetoothDiscoveryTask = lookup
        await lookup.value
    }

    func refreshDevices() async {
        guard !windowIsClosed, !running, !stopping, !preflight.isChecking else { return }
        switch mode {
        case .usb:
            guard !loadingUSBDeviceNames else { return }
            retryPreflight()
            await refreshUSBDeviceNames()
        case .bluetooth:
            guard !loadingBluetoothDevices else { return }
            await refreshBluetoothDevices()
            guard !Task.isCancelled, mode == .bluetooth, !running, !stopping else { return }
            retryPreflight()
        }
    }

    // MARK: - Preflight

    private func retryPreflight() {
        preflightRevision += 1
    }

    func cancelPreflight() {
        preflightTask?.cancel()
        preflightGeneration += 1
        checkedRequest = nil
        preflight = .idle
    }

    func schedulePreflight() {
        let previous = preflightTask
        cancelPreflight()
        guard !windowIsClosed, !running, !stopping, let request = preflightRequest,
            let connection = selectedConnection, let identity
        else { return }
        if sessionInterrupted {
            error = nil
            sessionInterrupted = false
        }
        status = nil
        preflight = .checking
        let generation = preflightGeneration
        preflightTask = Task.detached { [weak self] in
            await previous?.value
            let outcome: Result<Void, Error>
            do {
                try Task.checkCancellation()
                try AccessorySession.run(connection: connection, identity: identity, fix: nil) { event in
                    guard case .transportConnected = event else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.windowIsClosed, self.preflightGeneration == generation,
                            self.preflightRequest == request
                        else { return }
                        self.preflight = .connected
                    }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.windowIsClosed, self.preflightGeneration == generation,
                    self.preflightRequest == request
                else { return }
                self.preflightTask = nil
                switch outcome {
                case .success:
                    self.checkedRequest = request
                    self.preflight = .passed
                case .failure(let error):
                    let disconnected = (error as? FixBridgeError)?.recovery != nil
                    self.preflight = .failed(
                        FixBridgeError.statusMessage(for: error),
                        connected: !disconnected && self.preflight.linkVerified)
                }
            }
        }
    }

    // MARK: - Location session

    func start(routeModel: GPXRouteViewModel? = nil, makeFix: () throws -> LocationFix) {
        guard canStart, routeModel?.importing != true, let connection = selectedConnection, let identity else { return }
        do {
            let route = simulationMode == .dynamic ? routeModel?.route : nil
            let fix = try route?.start ?? makeFix()
            let refreshState = LocationRefreshState()
            self.refreshState = refreshState
            let locations = SessionLocation(fix: fix, route: route)
            if simulationMode == .dynamic && route == nil { locations.beginMovement() }
            if route != nil {
                activeRouteModel = routeModel
                routeModel?.attach(locations)
            }
            sessionLocation = locations
            movementRunning = simulationMode == .dynamic && route == nil
            error = nil
            authenticated = false
            sending = false
            delivered = 0
            sentLocations.removeAll(keepingCapacity: true)
            transportConnected = false
            switch connection {
            case .usb(let id):
                sessionSettingsTarget = .usb(id)
            case .bluetooth(let device):
                let isUnique = !device.name.isEmpty && bluetoothDevices.filter { $0.name == device.name }.count == 1
                sessionSettingsTarget = .bluetooth(uniqueName: isUnique ? device.name : nil)
            }
            hasStartedSession = true
            running = true
            status =
                mode == .usb
                ? String(localized: "Connecting to your iPhone over USB…")
                : String(localized: "Connecting to your iPhone over Bluetooth…")
            sessionGeneration += 1
            let generation = sessionGeneration
            task = Task.detached { [weak self] in
                let outcome: Result<Void, Error>
                do {
                    try AccessorySession.run(
                        connection: connection, identity: identity, fix: fix, locations: locations,
                        refreshState: refreshState
                    ) { event in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.sessionGeneration == generation else { return }
                            self.handle(event)
                        }
                    }
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    self.finish(outcome)
                }
            }
        } catch {
            self.error = FixBridgeError.statusMessage(for: error)
        }
    }

    func setLocationRefreshInProgress(_ active: Bool) {
        guard running, !stopping else { return }
        refreshState.setActive(active)
    }

    func openSettingsForRefresh() async {
        guard let sessionSettingsTarget else { return }
        await openSettings(for: sessionSettingsTarget)
    }

    private func openSettings(for target: PhoneSettings.Target) async {
        try? await PhoneSettings.openLocationServices(for: target)
    }

    func stop(openSettings: Bool = false) {
        guard running, !stopping else { return }
        openSettingsAfterStop = openSettings
        stopping = true
        status = String(localized: "Closing the location session…")
        task?.cancel()
    }

    private func finish(_ outcome: Result<Void, Error>) {
        let stopped = stopping
        let settingsTarget = openSettingsAfterStop ? sessionSettingsTarget : nil
        openSettingsAfterStop = false
        sessionSettingsTarget = nil
        task = nil
        if movementRunning { print("[FixBridge Movement] Session ended.") }
        activeRouteModel?.detach()
        activeRouteModel = nil
        sessionLocation = nil
        movementRunning = false
        running = false
        transportConnected = false
        authenticated = false
        sending = false
        switch outcome {
        case .failure(let error) where !(error is CancellationError):
            print("[FixBridge Session End] \(error.localizedDescription)")
            cancelPreflight()
            sessionInterrupted = true
            self.error = FixBridgeError.statusMessage(for: error)
            status = String(localized: "The location session ended.")
        default:
            status =
                stopped
                ? String(localized: "Location updates stopped.")
                : String(localized: "The one-hour session limit was reached. Location updates stopped.")
        }
        if let settingsTarget {
            settingsTask = Task {
                await openSettings(for: settingsTarget)
                guard !Task.isCancelled else { return }
                settingsTask = nil
                stopping = false
            }
        } else {
            stopping = false
        }
    }

    private func handle(_ event: AccessoryEvent) {
        guard !windowIsClosed, running, !stopping else { return }
        switch event {
        case .reconnecting(let attempt):
            transportConnected = false
            authenticated = false
            sending = false
            status = String(localized: "USB accessory session interrupted. Reconnecting (\(attempt)/3)…")
        case .transportConnected:
            transportConnected = true
            if !stopping {
                status =
                    mode == .usb
                    ? String(localized: "USB connected. Preparing the accessory session…")
                    : String(localized: "Bluetooth connected. Preparing the accessory session…")
            }
        case .linkReady:
            if !stopping { status = String(localized: "Authenticating the accessory…") }
        case .authenticated:
            authenticated = true
            if !stopping {
                status = String(localized: "MFi authentication passed. Waiting for an iPhone location request.")
            }
        case .subscribed(let sentences):
            if sentences.isEmpty {
                sending = false
                if !stopping {
                    status = String(localized: "MFi authentication passed. Waiting for an iPhone location request.")
                }
            } else if !stopping && !sending {
                status = String(localized: "Waiting for iPhone to acknowledge the first location update…")
            }
        case .unsubscribed:
            sending = false
            if !stopping { status = String(localized: "iPhone paused location requests. Waiting for it to resume.") }
        case .locationSent(let sequence, let fix, let time):
            sentLocations.append(SentLocation(sequence: sequence, fix: fix, time: time))
            if sentLocations.count > Self.maximumSentLocations {
                sentLocations.removeFirst(sentLocations.count - Self.maximumSentLocations)
            }
        case .acknowledged(let count):
            delivered = count
            if !stopping && !sending {
                sending = true
                status =
                    movementRunning
                    ? String(localized: "Sending subtle location changes.")
                    : String(localized: "Sending location updates.")
            }
        }
    }
}
