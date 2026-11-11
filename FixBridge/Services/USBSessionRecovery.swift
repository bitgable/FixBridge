import Foundation

/// Shared between the main-thread guide and the background USB session.
final class LocationRefreshState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func setActive(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        active = value
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func waitUntilFinished(deadline: TimeInterval?) throws {
        while isActive {
            try Task.checkCancellation()
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try Task.checkCancellation()
    }
}

enum USBSessionRecovery {
    /// Recreate the entire session; never reuse a broken stream or authentication result.
    static func run<T>(
        isDevicePresent: () -> Bool,
        onRetry: (Int) -> Void,
        waitForRefresh: () throws -> Void = {},
        wait: (TimeInterval) throws -> Void = cancellableWait,
        operation: () throws -> T
    ) throws -> T {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                return try operation()
            } catch {
                try Task.checkCancellation()
                let recovery = (error as? FixBridgeError)?.recovery
                guard recovery == .usbSession || recovery == .usbConnection,
                    retries < 3
                else { throw error }
                retries += 1
                print("[FixBridge USB Recovery] attempt=\(retries)/3 cause=\(error.localizedDescription)")
                onRetry(retries)
                // The guide owns the off/countdown/on sequence. Do not consume retry
                // attempts or reopen the accessory while the user is still changing settings.
                try waitForRefresh()
                try Task.checkCancellation()
                try wait(Double(retries))
                try waitForRefresh()
                try Task.checkCancellation()
                guard isDevicePresent() else {
                    print("[FixBridge USB Recovery] deviceReturn=absent after refresh confirmation")
                    throw FixBridgeError("The selected USB iPhone is no longer connected.", recovery: .usbConnection)
                }
            }
        }
    }

    private static func cancellableWait(_ seconds: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: min(0.1, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
    }
}
