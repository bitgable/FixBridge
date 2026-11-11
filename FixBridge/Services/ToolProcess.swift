import Darwin
import Foundation

enum ToolProcess {
    static func capture(
        _ executable: URL,
        arguments: [String],
        timeout: Duration,
        outputLimit: Int,
        failure: String.LocalizationValue
    ) throws -> Data {
        try Task.checkCancellation()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw FixBridgeError(failure)
        }
        defer { stop(process) }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let fd = pipe.fileHandleForReading.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 8192)
        var output = Data()
        var reachedEOF = false
        while !reachedEOF || process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw FixBridgeError(failure) }
            if reachedEOF {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw FixBridgeError(failure) }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, count <= outputLimit - output.count else { throw FixBridgeError(failure) }
            reachedEOF = count == 0
            output.append(contentsOf: bytes.prefix(count))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw FixBridgeError(failure) }
        return output
    }

    static func stop(_ process: Process, gracefulWait: Duration = .zero) {
        waitForExit(process, for: gracefulWait)
        guard process.isRunning else { return }
        process.terminate()
        waitForExit(process, for: .milliseconds(250))
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            waitForExit(process, for: .milliseconds(250))
        }
    }

    private static func waitForExit(_ process: Process, for timeout: Duration) {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
