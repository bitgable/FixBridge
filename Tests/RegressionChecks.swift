import CoreLocation
import Foundation

@main
struct RegressionChecks {
    @MainActor static func eventually(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { fatalError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Expected rejection")
        } catch {}
    }

    @MainActor static func checkModePreferences() {
        let suite = "FixBridge-ModePreferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = FixBridgeViewModel(defaults: defaults)
        assert(fresh.mode == .usb && fresh.simulationMode == .normal)
        fresh.mode = .bluetooth
        fresh.selectSimulationMode(.dynamic)
        fresh.closeWindow()
        let restored = FixBridgeViewModel(defaults: defaults)
        assert(restored.mode == .bluetooth && restored.simulationMode == .dynamic)
        assert(!restored.running && !restored.authenticated && restored.delivered == 0)
        assert(!restored.canStart && restored.sentLocations.isEmpty)
        restored.mode = .usb
        restored.selectSimulationMode(.normal)
        let changed = FixBridgeViewModel(defaults: defaults)
        assert(changed.mode == .usb && changed.simulationMode == .normal)
        for invalid: Any in ["future-mode", 999, ["unexpected"]] {
            defaults.set(invalid, forKey: "preferredConnectionMode")
            defaults.set(invalid, forKey: "preferredSimulationMode")
            let fallback = FixBridgeViewModel(defaults: defaults)
            assert(fallback.mode == .usb && fallback.simulationMode == .normal && !fallback.running)
        }
        defaults.removeObject(forKey: "preferredConnectionMode")
        defaults.set("dynamic", forKey: "preferredSimulationMode")
        let independent = FixBridgeViewModel(defaults: defaults)
        assert(independent.mode == .usb && independent.simulationMode == .dynamic)
        print(
            "Mode preferences checks passed: first launch defaults, restoration, changed choices, invalid data fallback, independent selections, no automatic session start."
        )
    }

    static func checkApplicationIdentity() {
        let original = "org.example.original"
        assert(ApplicationIdentity.storageDirectory(for: original, legacyIdentifier: original) == "FixBridge")
        assert(
            ApplicationIdentity.storageDirectory(for: original, legacyIdentifier: nil)
                == "FixBridge-org.example.original")
        assert(ApplicationIdentity.storageDirectory(for: "org.example.fixbridge") == "FixBridge-org.example.fixbridge")
        assert(ApplicationIdentity.storageDirectory(for: "FixBridge") != "FixBridge")
        for invalid in ["..", ".", "", "../escape", "/absolute", "a/b"] {
            let directory = ApplicationIdentity.storageDirectory(for: invalid)
            assert(!directory.contains("/") && directory != "." && directory != "..")
        }
    }

    @MainActor static func main() async throws {
        checkApplicationIdentity()
        checkMapProjection()
        try checkGPX()
        try await checkRouteLibrary()
        try await checkEditorViewModels()
        try await checkAsyncPresentation()
        try await checkTargetCRUD()
        checkModePreferences()
        // The required big-endian interval governs messages, even across repeated subscriptions.
        let request = LocationSubscription(parameters: [(0, [0, 0, 9, 196]), (1, []), (2, []), (0x8001, [0])])!
        assert(request.requestedMilliseconds == 2500 && request.sendInterval == 2.5)
        assert(request.sentenceIDs == [1, 2])
        assert(LocationSubscription(parameters: [(1, [])]) == nil)
        assert(LocationSubscription(parameters: [(0, [0, 0, 1])]) == nil)
        assert(LocationSubscription(parameters: [(0, [0, 0, 0, 0]), (0, [0, 0, 0, 0])]) == nil)
        assert(LocationSubscription(parameters: [(0, [0, 0, 0, 0]), (2, [1])]) == nil)
        assert(LocationSubscription(parameters: [(0, [0, 0, 0, 0]), (1, []), (1, [])]) == nil)
        assert(LocationSubscription(parameters: [(0, [255, 255, 255, 255])])!.requestedMilliseconds == UInt32.max)
        let fast = LocationSubscription(parameters: [(0, [0, 0, 0, 0]), (1, [])])!
        assert(fast.sendInterval == 1)
        var schedule = LocationSendSchedule(subscription: request)
        assert(schedule.isDue(at: 0))
        schedule.sent(at: 1)
        assert(!schedule.isDue(at: 3.49) && schedule.isDue(at: 3.5))
        schedule.subscription = nil
        assert(!schedule.isDue(at: 100))
        schedule.subscription = request
        assert(!schedule.isDue(at: 2) && schedule.isDue(at: 3.5))
        schedule.subscription = LocationSubscription(parameters: [(0, [0, 0, 0, 1]), (3, [])])!
        assert(!schedule.isDue(at: 100))  // GSV is not advertised or implemented.

        // Real recovery policy: bounded retries, user-controlled refresh gate, cancellable waits.
        var attempts = 0
        var retries = [Int]()
        let result: Int = try USBSessionRecovery.run(
            isDevicePresent: { true }, onRetry: { retries.append($0) }, wait: { _ in },
            operation: {
                attempts += 1
                if attempts < 3 { throw FixBridgeError("Closed", recovery: .usbSession) }
                return 42
            })
        assert(result == 42 && attempts == 3 && retries == [1, 2])
        for recovery in [FixBridgeError.Recovery.bluetoothConnection] {
            attempts = 0
            expectFailure {
                try USBSessionRecovery.run(isDevicePresent: { true }, onRetry: { _ in fatalError() }, wait: { _ in }) {
                    attempts += 1
                    throw FixBridgeError("Not a USB service interruption", recovery: recovery)
                }
            }
            assert(attempts == 1)
        }
        attempts = 0
        expectFailure {
            try USBSessionRecovery.run(isDevicePresent: { true }, onRetry: { _ in }, wait: { _ in }) {
                attempts += 1
                throw FixBridgeError("Closed", recovery: .usbSession)
            }
        }
        assert(attempts == 4)
        // No device-presence check or new connection until the guide confirms completion.
        attempts = 0
        var confirmed = false
        var confirmationWaits = 0
        let recovered: Int = try USBSessionRecovery.run(
            isDevicePresent: {
                assert(confirmed)
                return true
            }, onRetry: { _ in },
            waitForRefresh: {
                confirmationWaits += 1
                confirmed = true
            }, wait: { _ in },
            operation: {
                attempts += 1
                if attempts == 1 { throw FixBridgeError("Device disappeared", recovery: .usbConnection) }
                assert(confirmed)
                return 7
            })
        assert(recovered == 7 && attempts == 2 && confirmationWaits == 2)
        // Once the guide ends, an absent device must fail instead of waiting another fixed ten seconds.
        var absentWaits = [TimeInterval]()
        attempts = 0
        expectFailure {
            try USBSessionRecovery.run(
                isDevicePresent: { false }, onRetry: { _ in }, wait: { absentWaits.append($0) },
                operation: {
                    attempts += 1
                    throw FixBridgeError("Unplugged", recovery: .usbConnection)
                })
        }
        assert(attempts == 1 && absentWaits == [1])
        // Stop while waiting on user input must prevent opening another session.
        attempts = 0
        do {
            try USBSessionRecovery.run(
                isDevicePresent: { fatalError("Checked presence before confirmation") }, onRetry: { _ in },
                waitForRefresh: { throw CancellationError() }, wait: { _ in },
                operation: {
                    attempts += 1
                    throw FixBridgeError("Unplugged", recovery: .usbConnection)
                })
            fatalError("Refresh wait ignored cancellation")
        } catch is CancellationError {}
        assert(attempts == 1)
        let refreshGate = LocationRefreshState()
        assert(!refreshGate.isActive)
        refreshGate.setActive(true)
        assert(refreshGate.isActive)
        let waiting = Task.detached { try refreshGate.waitUntilFinished(deadline: nil) }
        waiting.cancel()
        do {
            try await waiting.value
            fatalError("Refresh state swallowed Stop")
        } catch is CancellationError {}
        refreshGate.setActive(false)
        try refreshGate.waitUntilFinished(deadline: nil)
        refreshGate.setActive(true)
        let enteredRefreshWait = DispatchSemaphore(value: 0)
        let finishedRefreshWait = DispatchSemaphore(value: 0)
        let userConfirmation = Task.detached {
            enteredRefreshWait.signal()
            try refreshGate.waitUntilFinished(deadline: nil)
            finishedRefreshWait.signal()
        }
        assert(enteredRefreshWait.wait(timeout: .now() + 1) == .success)
        assert(finishedRefreshWait.wait(timeout: .now()) == .timedOut)
        refreshGate.setActive(false)  // The guide's final OK or Cancel action.
        try await userConfirmation.value
        assert(finishedRefreshWait.wait(timeout: .now()) == .success)
        // The existing session lifetime also bounds an abandoned guide.
        refreshGate.setActive(true)
        try refreshGate.waitUntilFinished(deadline: ProcessInfo.processInfo.systemUptime - 1)
        refreshGate.setActive(false)
        expectFailure {
            try USBSessionRecovery.run(isDevicePresent: { false }, onRetry: { _ in }, wait: { _ in }) {
                throw FixBridgeError("Closed", recovery: .usbSession)
            }
        }
        expectFailure {
            try USBSessionRecovery.run(isDevicePresent: { true }, onRetry: { _ in fatalError() }, wait: { _ in }) {
                throw FixBridgeError("MFi rejected")
            }
        }
        attempts = 0
        do {
            try USBSessionRecovery.run(
                isDevicePresent: { true }, onRetry: { _ in }, wait: { _ in throw CancellationError() },
                operation: {
                    attempts += 1
                    throw FixBridgeError("Closed", recovery: .usbSession)
                })
            fatalError("Cancellation was swallowed")
        } catch is CancellationError {}
        assert(attempts == 1)
        assert(FixBridgeError.statusMessage(for: FixBridgeError("Closed", recovery: .usbSession)).contains("session"))

        // Invalid coordinates and non-finite values must never reach NMEA integer conversion.
        for (lat, lon, alt) in [(Double.nan, 0.0, 0.0), (0, .infinity, 0), (91, 0, 0), (0, -181, 0), (0, 0, .nan)] {
            expectFailure { _ = try LocationFix(latitude: lat, longitude: lon, altitude: alt, duration: 3600) }
        }
        let fix = try LocationFix(latitude: 37.3349, longitude: -122.009, altitude: 47.43, duration: 3600)
        for sentence in fix.sentences().values {
            let parts = sentence.trimmingCharacters(in: .newlines).dropFirst().split(separator: "*")
            assert(parts.count == 2)
            assert(String(format: "%02X", parts[0].utf8.reduce(0, ^)) == parts[1])
            assert(sentence.contains("3720.0940,N,12200.5400,W"))
        }
        _ = try LocationFix(latitude: -90, longitude: 180, altitude: -100, duration: 3600).sentences()

        // Long-running drift stays near its original center, with bounded speed and no altitude drift.
        for (lat, lon) in [(37.3349, -122.009), (0.0, 179.999999), (-45.0, 120.0), (89.99, 0.0)] {
            let origin = try LocationFix(latitude: lat, longitude: lon, altitude: 47.43, duration: 3600)
            let drift = SessionLocation(fix: origin, seed: 123)
            assert(!drift.sample(at: 0).movementEnabled && drift.canBeginMovement)
            assert(drift.beginMovement() && !drift.beginMovement())
            let center = CLLocation(latitude: lat, longitude: lon)
            var previous = center
            var unique = Set<String>()
            for second in 0...10_000 {
                let sample = drift.sample(at: Double(second))
                let current = CLLocation(latitude: sample.fix.latitude, longitude: sample.fix.longitude)
                assert(sample.movementEnabled && sample.fix.altitude == origin.altitude)
                assert(current.distance(from: center) <= 1.52)
                assert(current.distance(from: previous) <= 0.58)
                unique.insert(sample.fix.sentences()[1]!.components(separatedBy: ",")[2...5].joined())
                previous = current
            }
            assert(unique.count > 10)  // Real changes must survive NMEA coordinate quantization.
            let before = drift.sample(at: 10_001).fix
            drift.pause()
            let resumed = drift.sample(at: 50_000).fix
            assert(before.latitude == resumed.latitude && before.longitude == resumed.longitude)
            assert(drift.sample(at: .nan).fix.latitude == origin.latitude)
        }
        let firstDrift = SessionLocation(fix: fix, seed: 42)
        let secondDrift = SessionLocation(fix: fix, seed: 42)
        firstDrift.beginMovement()
        secondDrift.beginMovement()
        for second in 0...100 {
            assert(
                firstDrift.sample(at: Double(second)).fix.longitude
                    == secondDrift.sample(at: Double(second)).fix.longitude)
        }

        // Reject corrupt writes without touching the last valid saved locations.
        let suiteName = "FixBridge-Regression-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let point = SavedLocation(id: UUID(), name: "Test", latitude: 37.3349, longitude: -122.009, altitude: 47.43)
        try SavedLocationStore.save([point], defaults: defaults)
        expectFailure { try SavedLocationStore.save([point, point], defaults: defaults) }
        let stored = try SavedLocationStore.load(defaults: defaults)
        assert(stored.count == 1)
        defaults.set(Data([0, 1, 2]), forKey: "savedPoints")
        expectFailure { _ = try SavedLocationStore.load(defaults: defaults) }
        assert(defaults.data(forKey: "savedPoints") == Data([0, 1, 2]))

        // Field validation accepts existing coordinate formats and rejects invalid submission before connecting.
        let validation = TargetLocationViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        assert(!validation.validateForSubmission())
        assert(validation.fieldErrors.count == 3 && validation.focusRequest?.field == .latitude)
        let summary = LocationInput.validationSummary(validation.fieldErrors)
        let expectedSummary = LocationInput.Field.allCases.map {
            $0.title + ": " + validation.fieldErrors[$0]!
        }.joined(separator: "\n\n")
        assert(summary == expectedSummary)  // One alert includes every invalid field in input order.
        assert(LocationInput.validationSummary([:]).isEmpty)

        let firstRequest = validation.focusRequest
        assert(!validation.validateForSubmission() && validation.focusRequest != firstRequest)
        validation.latitude = "-"
        assert(validation.fieldErrors[.latitude] == nil)  // Do not report intermediate typing as an error.
        validation.validateField(.latitude)
        assert(validation.fieldErrors[.latitude] != nil)
        validation.latitude = "37°20′05.64″N"
        validation.longitude = "122°00′32.40″W"
        validation.altitude = "47.43"
        assert(validation.validateForSubmission() && validation.fieldErrors.isEmpty)
        for (field, value) in [
            (LocationInput.Field.latitude, "91"), (.longitude, "-181"),
            (.altitude, "nan"), (.altitude, "inf"), (.altitude, String(repeating: "9", count: 129)),
        ] {
            assert(LocationInput.validationMessage(for: field, text: value) != nil)
        }
        assert(
            LocationInput.validationMessage(for: .latitude, text: String(repeating: " ", count: 129) + "1") != nil)
        assert(
            LocationInput.validationMessage(for: .altitude, text: String(repeating: " ", count: 129) + "1") != nil)
        assert(LocationInput.validationMessage(for: .latitude, text: "-90") == nil)
        assert(LocationInput.validationMessage(for: .longitude, text: "180") == nil)
        assert(LocationInput.validationMessage(for: .altitude, text: "-100000") == nil)
        assert(LocationInput.validationMessage(for: .latitude, text: "", required: false) == nil)
        validation.applyLocationFix(try LocationFix(latitude: 1, longitude: 2, altitude: 3, duration: 1))
        assert(validation.fieldErrors.isEmpty && validation.focusRequest == nil)

        // Map lookups cannot replace coordinates or altitude that the user has since edited.
        defaults.removeObject(forKey: "savedPoints")
        let location = TargetLocationViewModel(defaults: defaults)
        assert(!location.hasUnsavedTarget)
        location.latitude = "  "
        assert(!location.hasUnsavedTarget)

        location.latitude = "37°20′05.64″N"
        assert(location.hasUnsavedTarget)
        location.longitude = "122°00′32.40″W"
        location.altitude = "47.43"
        let parsed = try location.makeFix()
        assert(abs(parsed.latitude - 37.3349) < 0.0000001)
        assert(abs(parsed.longitude + 122.009) < 0.0000001)
        location.latitude = "37°20′05.64″E"
        expectFailure { _ = try location.makeFix() }
        location.applyMapCoordinate(CLLocationCoordinate2D(latitude: 1, longitude: 1))
        location.altitude = "99"
        try await Task.sleep(for: .milliseconds(150))
        assert(location.altitude == "99" && location.altitudeLookupStatus == .idle)
        location.applyMapCoordinate(CLLocationCoordinate2D(latitude: 2, longitude: 2))
        try await eventually("elevation result") { location.altitudeLookupStatus == .estimated }
        assert(Double(location.altitude) == 123)
        let draft = try location.preparePoint()
        try location.savePoint(draft, named: "Test point")
        expectFailure { try location.savePoint(draft, named: " ") }
        assert(location.savedPoints.count == 1)
        assert(location.selectedPointID == draft.id && !location.hasUnsavedTarget)
        let savedForEditing = location.savedPoints[0]
        location.altitude = "124"
        assert(location.selectedPointID == nil && location.hasUnsavedTarget)  // Typing creates an unsaved target.
        location.loadPoint(savedForEditing)
        assert(location.selectedPointID == draft.id)
        // Explicit map selection creates a new target even at exactly the saved coordinates.
        location.applyMapCoordinate(
            CLLocationCoordinate2D(
                latitude: savedForEditing.latitude, longitude: savedForEditing.longitude))
        assert(location.selectedPointID == nil && location.hasUnsavedTarget)
        assert(location.savedPoints[0].altitude == savedForEditing.altitude)
        location.cancelAltitudeLookup()
        location.loadPoint(savedForEditing)
        try location.removePoint(savedForEditing)
        assert(location.savedPoints.isEmpty && location.selectedPointID == nil && location.hasUnsavedTarget)
        defaults.set(Data([0, 1, 2]), forKey: "savedPoints")
        let unreadableLocations = TargetLocationViewModel(defaults: defaults)
        expectFailure { try unreadableLocations.removePoint(savedForEditing) }
        assert(unreadableLocations.error != nil)

        // A typed error preserves its diagnostic while supplying a localized recovery instruction.
        let connectionError = FixBridgeError("Native link closed", recovery: .bluetoothConnection)
        assert(connectionError.localizedDescription == "Native link closed")
        assert(FixBridgeError.statusMessage(for: connectionError).contains("refresh"))
        assert(FixBridgeError.statusMessage(for: FixBridgeError("Bad certificate")) == "Bad certificate")

        let output = try ToolProcess.capture(
            URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["ready"], timeout: .seconds(1), outputLimit: 5, failure: "Tool failed")
        assert(String(decoding: output, as: UTF8.self) == "ready")
        expectFailure {
            _ = try ToolProcess.capture(
                URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["123456"], timeout: .seconds(1), outputLimit: 5, failure: "Tool failed")
        }
        let started = ContinuousClock.now
        expectFailure {
            _ = try ToolProcess.capture(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec /bin/sleep 5"], timeout: .milliseconds(50),
                outputLimit: 5, failure: "Tool failed")
        }
        assert(started.duration(to: .now) < .seconds(2))

        // Every session test owns its preferences; never alter the user's saved mode selections.
        var sessionSuites: [String] = []
        defer {
            for suite in sessionSuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
        func makeSessionModel() -> FixBridgeViewModel {
            let suite = "FixBridge-SessionChecks-\(UUID())"
            sessionSuites.append(suite)
            return FixBridgeViewModel(defaults: UserDefaults(suiteName: suite)!)
        }
        let driver = SessionTestDriver.shared
        driver.reset()
        let model = makeSessionModel()
        model.mode = .bluetooth
        await model.refreshBluetoothDevices()
        assert(model.deviceChoices.count == 1 && model.selectedDeviceID != nil)
        model.schedulePreflight()
        try await eventually("preflight success") { model.preflight.passed }
        assert(model.statusDisplay(locationError: nil).kind == .success && model.canStart)
        assert(model.statusDisplay(locationError: "Invalid altitude").kind == .error)

        // Invalid target input remains retryable after the user corrects it.
        model.start { throw FixBridgeError("Invalid coordinates") }
        assert(!model.running && model.canStart)
        model.start { fix }
        try await eventually("first receipt") { model.delivered == 1 }
        assert(model.simulationMode == .normal && !model.movementRunning)
        assert(driver.snapshot().movementEnabled == false)
        model.selectSimulationMode(.dynamic)
        assert(model.simulationMode == .normal)  // Mode cannot change during a running session.
        model.stop()
        try await eventually("normal mode stopped") { !model.running && !model.stopping }
        assert(model.canStart)
        model.selectSimulationMode(.dynamic)
        model.start { fix }
        try await eventually("dynamic first receipt") { model.delivered == 1 && model.running }
        assert(model.movementRunning && driver.snapshot().movementEnabled == true)
        model.selectSimulationMode(.normal)
        assert(model.simulationMode == .dynamic)
        assert(model.statusDisplay(locationError: nil).kind == .normal)  // Active sending is not loading.
        assert(driver.snapshot().sessions == 2)  // One session per Start; no extra movement session.
        driver.update { $0.reconnectRequested = true }
        try await eventually("reconnecting clears authentication") { !model.authenticated && !model.sending }
        assert(model.running && !model.canStart && model.delivered == 1)
        assert(model.statusDisplay(locationError: nil).kind == .working)
        assert(model.movementRunning)  // Recovery preserves the session's coordinates and movement controller.
        model.stop()
        try await eventually("stopped") { !model.running && !model.stopping }
        assert(!model.authenticated && !model.sending && model.delivered == 1)
        assert(!model.movementRunning)
        assert(model.statusDisplay(locationError: nil).kind == .normal)
        model.selectSimulationMode(.normal)
        model.start { fix }
        try await eventually("normal after dynamic") { model.delivered == 1 && model.running }
        assert(!model.movementRunning && driver.snapshot().movementEnabled == false)
        model.stop()
        try await eventually("final normal stop") { !model.running && !model.stopping }
        let gpxURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FixBridge-Route-\(UUID().uuidString).gpx")
        defer { try? FileManager.default.removeItem(at: gpxURL) }
        let routeXML = """
            <gpx><rte><rtept lat="1" lon="2"><ele>3</ele><time>2000-01-01T00:00:00Z</time></rtept>
            <rtept lat="2" lon="3"><ele>4</ele><time>2000-01-01T00:00:10Z</time></rtept></rte></gpx>
            """
        try Data(routeXML.utf8).write(to: gpxURL)
        let routeModel = GPXRouteViewModel(
            store: SavedRouteStore(url: gpxURL.deletingPathExtension().appendingPathExtension("json")))
        var appliedRouteOrigin = false
        routeModel.importFile(gpxURL) { point in
            appliedRouteOrigin = point.latitude == 1 && point.altitude == 3
        }
        try await eventually("GPX imported") { !routeModel.importing }
        assert(appliedRouteOrigin && routeModel.route?.duration == 10)
        driver.update {
            $0.reconnectRequested = false
            $0.locationBurstCount = 205
        }
        model.selectSimulationMode(.dynamic)
        model.start(routeModel: routeModel) { throw FixBridgeError("Route must supply its own origin") }
        try await eventually("GPX session sends origin") { model.running && model.sending }
        try await eventually("bounded sent-location history") { model.sentLocations.last?.sequence == 205 }
        assert(model.sentLocations.count == FixBridgeViewModel.maximumSentLocations)
        assert(model.sentLocations.first?.sequence == 6)
        assert(model.sentLocations.last?.fix == routeModel.route?.start)
        assert(model.sentLocations.last?.line.contains("lat=1.0000000 lon=2.0000000 alt=3.00 m") == true)
        driver.update { $0.locationBurstCount = 1 }
        assert(!model.movementRunning && driver.snapshot().movementEnabled == false)
        assert(routeModel.playback.state == .ready)
        assert(
            model.statusDisplay(locationError: nil, routePlayback: routeModel.playback).message.contains("Start Route"))
        assert(model.statusDisplay(locationError: "Input error", routePlayback: routeModel.playback).kind == .error)
        let finishedStatus = model.statusDisplay(
            locationError: nil, routePlayback: .init(state: .finished, elapsed: 10))
        assert(finishedStatus.kind == .success && finishedStatus.message.contains("endpoint"))
        routeModel.clear()
        assert(routeModel.route != nil)  // Cannot remove an active route.
        routeModel.togglePlayback()
        assert(routeModel.playback.state == .playing)
        assert(model.statusDisplay(locationError: nil, routePlayback: routeModel.playback).kind == .normal)
        routeModel.togglePlayback()
        assert(routeModel.playback.state == .paused && model.running)
        assert(
            model.statusDisplay(locationError: nil, routePlayback: routeModel.playback).message.contains("Resume Route")
        )
        routeModel.togglePlayback()
        assert(routeModel.playback.state == .playing && model.running)
        model.stop()
        try await eventually("GPX Stop detaches playback") { !model.running && !model.stopping }
        assert(routeModel.playback.state == .ready && routeModel.route != nil)
        // Late Stop callbacks must not append to the finished session's history.
        assert(model.sentLocations.count == 200 && model.sentLocations.last?.sequence == 205)
        assert(
            !model.statusDisplay(locationError: nil, routePlayback: routeModel.playback).message.contains("Start Route")
        )
        try Data("<gpx/>".utf8).write(to: gpxURL)
        routeModel.importFile(gpxURL) { _ in fatalError("Invalid file replaced origin") }
        try await eventually("GPX invalid import") { !routeModel.importing }
        assert(routeModel.error != nil && routeModel.route?.duration == 10)
        routeModel.clear()
        assert(routeModel.route == nil)
        model.closeWindow()
        assert(!model.canStart)

        // Failed preflight exposes one actionable error and never leaves the link green.
        driver.reset()
        driver.update { $0.failPreflight = true }
        let failed = makeSessionModel()
        failed.mode = .bluetooth
        await failed.refreshBluetoothDevices()
        failed.schedulePreflight()
        try await eventually("failed preflight") { failed.preflight.error != nil }
        assert(!failed.canStart && !failed.preflight.linkVerified)
        let failedStatus = failed.statusDisplay(locationError: nil)
        assert(failedStatus.kind == .error && failedStatus.message.contains("refresh"))
        failed.closeWindow()

        // Native work returning after the window closes must not restore readiness.
        driver.reset()
        driver.update { $0.preflightDelay = 0.15 }
        let closed = makeSessionModel()
        closed.mode = .bluetooth
        await closed.refreshBluetoothDevices()
        closed.schedulePreflight()
        try await eventually("preflight entered") { driver.snapshot().preflights == 1 }
        closed.closeWindow()
        try await Task.sleep(for: .milliseconds(250))
        assert(!closed.preflight.passed && !closed.preflight.linkVerified && !closed.canStart)

        // Changing the selected transport invalidates queued callbacks before SwiftUI reschedules.
        driver.reset()
        driver.update { $0.preflightDelay = 0.1 }
        let switched = makeSessionModel()
        switched.mode = .bluetooth
        await switched.refreshBluetoothDevices()
        switched.schedulePreflight()
        try await eventually("second preflight entered") { driver.snapshot().preflights == 1 }
        switched.mode = .usb
        try await Task.sleep(for: .milliseconds(180))
        assert(!switched.preflight.passed && !switched.canStart)
        switched.closeWindow()

        // A discovery result for an old mode cannot overwrite the current device state.
        driver.reset()
        driver.update { $0.discoveryDelay = 0.1 }
        let discovery = makeSessionModel()
        discovery.mode = .bluetooth
        let refresh = Task { await discovery.refreshBluetoothDevices() }
        try await Task.sleep(for: .milliseconds(20))
        discovery.mode = .usb
        await refresh.value
        assert(discovery.bluetoothDevices.isEmpty)
        discovery.closeWindow()

        // Canceling the view task during a quick mode switch must not strand discovery.
        driver.reset()
        driver.update { $0.discoveryDelay = 0.12 }
        let resumedDiscovery = makeSessionModel()
        resumedDiscovery.mode = .bluetooth
        let oldViewTask = Task { await resumedDiscovery.refreshBluetoothDevices() }
        try await eventually("discovery started before switch") { resumedDiscovery.loadingBluetoothDevices }
        resumedDiscovery.mode = .usb
        oldViewTask.cancel()
        resumedDiscovery.mode = .bluetooth
        await resumedDiscovery.refreshBluetoothDevices()
        await oldViewTask.value
        assert(!resumedDiscovery.loadingBluetoothDevices && resumedDiscovery.bluetoothDevices.count == 1)
        resumedDiscovery.closeWindow()

        // A reopened window starts a new request; the old completion cannot clear its busy state.
        driver.reset()
        driver.update { $0.discoveryDelay = 0.08 }
        let reopenedDiscovery = makeSessionModel()
        reopenedDiscovery.mode = .bluetooth
        let closing = Task { await reopenedDiscovery.refreshBluetoothDevices() }
        try await eventually("discovery before close") { driver.snapshot().discoveries == 1 }
        reopenedDiscovery.closeWindow()
        driver.update { $0.discoveryDelay = 0.20 }
        reopenedDiscovery.openWindow()
        let reopened = Task { await reopenedDiscovery.refreshBluetoothDevices() }
        try await eventually("discovery after reopen") { driver.snapshot().discoveries == 2 }
        await closing.value
        assert(reopenedDiscovery.loadingBluetoothDevices && reopenedDiscovery.bluetoothDevices.isEmpty)
        await reopened.value
        assert(!reopenedDiscovery.loadingBluetoothDevices && reopenedDiscovery.bluetoothDevices.count == 1)
        reopenedDiscovery.closeWindow()

        // Cancellation is propagated into blocking helpers and their result is discarded.
        let background = Task {
            try await BackgroundTask.run {
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                return 1
            }
        }
        background.cancel()
        do {
            _ = try await background.value
            fatalError("Cancellation was lost")
        } catch is CancellationError {}
        print(
            "Regression checks passed: input limits, NMEA checksums, saved-data integrity, typed errors, retry, Stop, stale callbacks, discovery cancellation."
        )
    }
}
