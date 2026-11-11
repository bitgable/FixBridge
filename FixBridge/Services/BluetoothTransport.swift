import Darwin
import Foundation

struct BluetoothDevice: Decodable, Identifiable, Sendable {
    let name: String
    let address: String
    let connected: Bool

    var id: String { address }
    var title: String { name.isEmpty ? address : name }

    static func pairedDevices() throws -> [BluetoothDevice] {
        try JSONDecoder().decode([BluetoothDevice].self, from: BluetoothTransport.query("--list"))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

enum AccessoryConnection: Sendable {
    case usb(String)
    case bluetooth(BluetoothDevice)
}

final class BluetoothTransport {
    let controllerAddress: [UInt8]
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    init(device: BluetoothDevice) throws {
        try Task.checkCancellation()
        let address = String(decoding: try Self.query("--controller"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
        let bytes = address.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, address.count == 6 else {
            throw FixBridgeError("Turn on Bluetooth on your Mac.")
        }
        controllerAddress = bytes

        let outgoing = Pipe()
        let incoming = Pipe()
        input = outgoing.fileHandleForWriting
        output = incoming.fileHandleForReading
        let fd = input.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1,
            fcntl(fd, F_SETNOSIGPIPE, 1) != -1
        else {
            throw FixBridgeError("Could not start the Bluetooth connection.", recovery: .bluetoothConnection)
        }
        try Task.checkCancellation()
        process = try Self.launch(device.address, input: outgoing, output: incoming)
        do {
            try waitUntilOpen()
        } catch {
            ToolProcess.stop(process)
            throw error
        }
    }

    private func waitUntilOpen() throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var ready: UInt8 = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let count = try withUnsafeMutableBytes(of: &ready) { try read(into: $0, timeout: 200) }
            if count == 1 && ready == 1 { return }
            if count == 1 { break }
        }
        throw FixBridgeError(
            "Could not connect over Bluetooth. Unlock your iPhone and keep it nearby.", recovery: .bluetoothConnection)
    }

    deinit {
        try? input.close()
        ToolProcess.stop(process, gracefulWait: .milliseconds(500))
    }

    func write(_ bytes: [UInt8]) throws {
        let fd = input.fileDescriptor
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw connectionError() }
                let count = Darwin.write(fd, start.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EAGAIN {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready < 0 && errno != EINTR { throw connectionError() }
                } else if count >= 0 || errno != EINTR {
                    throw connectionError()
                }
            }
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, timeout: Int32) throws -> Int {
        var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, timeout)
        if ready == 0 || (ready < 0 && errno == EINTR) { return 0 }
        guard ready > 0 else { throw connectionError() }

        let count = Darwin.read(output.fileDescriptor, buffer.baseAddress, buffer.count)
        if count < 0 && errno == EINTR { return 0 }
        guard count > 0 else { throw connectionError() }
        return count
    }

    fileprivate static func query(_ argument: String) throws -> Data {
        try ToolProcess.capture(
            helper(), arguments: [argument], timeout: .seconds(5),
            outputLimit: 256 * 1024,
            failure: "Turn on Bluetooth on your Mac and allow FixBridge to use it.")
    }

    private static func helper() throws -> URL {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "FixBridgeBluetooth") else {
            throw FixBridgeError("The Bluetooth component is missing from FixBridge. Reinstall the app.")
        }
        return executable
    }

    private static func launch(_ argument: String, input: Pipe, output: Pipe) throws -> Process {
        let executable = try helper()
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        process.standardInput = input
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            throw FixBridgeError("Could not start the Bluetooth connection.", recovery: .bluetoothConnection)
        }
        return process
    }

    private func connectionError() -> FixBridgeError {
        if !process.isRunning {
            switch process.terminationStatus {
            case 2: return FixBridgeError("Pair your iPhone with this Mac, then refresh the device list.")
            case 3: return FixBridgeError("The selected device did not advertise the Bluetooth accessory service.")
            case 4:
                return FixBridgeError(
                    "Could not connect over Bluetooth. Unlock your iPhone and keep it nearby.",
                    recovery: .bluetoothConnection)
            default: break
            }
        }
        return FixBridgeError("The Bluetooth accessory connection closed.", recovery: .bluetoothConnection)
    }
}
