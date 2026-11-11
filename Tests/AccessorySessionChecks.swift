import CoreFoundation
import Foundation

// Only transport and signing are replaced. AccessorySession and the wire codec are production code.
struct MFIIdentity: Sendable {
    let certificate = Data([1, 2, 3])
    func sign(challenge: Data) throws -> Data {
        precondition(challenge.count == 32)
        Phone.shared.signatures += 1
        return Data(repeating: 7, count: 64)
    }
}
struct BluetoothDevice: Sendable {}
enum AccessoryConnection: Sendable {
    case usb(String)
    case bluetooth(BluetoothDevice)
}
final class BluetoothTransport {
    let controllerAddress: [UInt8] = []
    init(device: BluetoothDevice) throws { fatalError("Unexpected Bluetooth access") }
    func write(_ bytes: [UInt8]) throws { fatalError("Unexpected Bluetooth access") }
    func read(into buffer: UnsafeMutableRawBufferPointer, timeout: Int32) throws -> Int {
        fatalError("Unexpected Bluetooth access")
    }
}

final class Phone: @unchecked Sendable {
    static let shared = Phone()
    var pending: [UInt8] = []
    var control: [UInt8] = []
    var peer: UInt8 = 200
    var signatures = 0
    var locations = 0
    var locationAttempts = 0
    var opened = 0
    var closed = 0
    var sentTypes: [Int] = []

    func enqueue(_ id: Int, _ body: [UInt8] = []) {
        peer &+= 1
        pending +=
            LinkPacket(
                flags: 0x40, sequence: peer, acknowledgement: 0, session: 1,
                payload: ControlMessage(id: id, body: body).frame
            ).bytes
    }
    func sent(_ bytes: [UInt8]) {
        var buffer = bytes
        let packet = LinkPacket.parse(from: &buffer)!
        if packet.flags & LinkPacket.syn != 0 {
            var reply = packet.payload
            reply[4] = 0
            reply[5] = 20  // Valid 20 ms retransmission timeout.
            reply[6] = 0
            reply[7] = 0
            pending +=
                LinkPacket(
                    flags: 0xC0, sequence: peer, acknowledgement: packet.sequence,
                    payload: reply
                ).bytes
            enqueue(0x9876, [0])  // Unknown malformed message must not kill the session.
            enqueue(0x1D00)
            enqueue(0xAA00)
            return
        }
        guard !packet.payload.isEmpty else { return }
        if packet.payload.count >= 6, word(packet.payload, 4) == 0xFFFB {
            locationAttempts += 1
            if locationAttempts <= 4 { return }  // Exhaust the old hardcoded four-attempt limit.
        }
        pending += LinkPacket(flags: 0x40, sequence: peer, acknowledgement: packet.sequence).bytes
        control += packet.payload
        guard control.count >= 6, control.count == word(control, 2) else { return }
        let id = word(control, 4)
        sentTypes.append(id)
        control = []
        switch id {
        case 0x1D01: enqueue(0x1D02)
        case 0xAA01:
            enqueue(0xAA02, parameter(0, [1, 2]))  // Invalid MFi-v3 challenge is ignored.
            enqueue(0xAA02, parameter(0, [UInt8](repeating: 3, count: 32)))
        case 0xAA03:
            enqueue(0xAA05)
            enqueue(0xFFFA, [0, 5, 0, 0])  // Truncated TLV, then valid subscription.
            enqueue(0xFFFA, parameter(0, [0, 0, 0, 250]) + parameter(1) + parameter(2))
        case 0xFFFB:
            locations += 1
            enqueue(0xFFFC, [0])  // Malformed stop must not supersede the valid stop that follows.
            enqueue(0xFFFC)
        default: fatalError("Unexpected outgoing control message")
        }
    }
}
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_open(
    _ identifier: CFString, _ detail: UnsafeMutablePointer<UnsafePointer<CChar>?>,
    _ status: UnsafeMutablePointer<UInt32>
) -> OpaquePointer? {
    Phone.shared.opened += 1
    return OpaquePointer(bitPattern: 1)
}
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_close(_ usb: OpaquePointer) { Phone.shared.closed += 1 }
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_device_presence(_ identifier: CFString) -> Int32 { 1 }
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_last_error(_ usb: OpaquePointer) -> UnsafePointer<CChar> { fatalError("Unexpected USB failure") }
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_write(_ usb: OpaquePointer, _ buffer: UnsafeRawPointer?, _ length: Int) -> Int32 {
    Phone.shared.sent(Array(UnsafeRawBufferPointer(start: buffer, count: length)))
    return 0
}
// swift-format-ignore: AlwaysUseLowerCamelCase
func fb_usb_read(_ usb: OpaquePointer, _ buffer: UnsafeMutableRawPointer?, _ length: Int, _ timeout: Int32) -> Int {
    let phone = Phone.shared
    let count = min(7, length, phone.pending.count)
    if count == 0 {
        Thread.sleep(forTimeInterval: 0.001)
        return 0
    }
    let bytes = Array(phone.pending.prefix(count))
    bytes.withUnsafeBytes { buffer!.copyMemory(from: $0.baseAddress!, byteCount: count) }
    phone.pending.removeFirst(count)
    return count
}

@main struct AccessorySessionChecks {
    static func main() async throws {
        let task = Task {
            var authenticated = 0
            var subscribed = 0
            var unsubscribed = 0
            var delivered = 0
            do {
                try AccessorySession.run(
                    connection: .usb("fixture"), identity: MFIIdentity(),
                    fix: LocationFix(latitude: 37.3349, longitude: -122.009, altitude: 47.43, duration: 3),
                    emit: { event in
                        switch event {
                        case .authenticated: authenticated += 1
                        case .subscribed(let ids):
                            subscribed += 1
                            assert(ids == [1, 2])
                        case .unsubscribed:
                            unsubscribed += 1
                            withUnsafeCurrentTask { $0?.cancel() }
                        case .acknowledged(let count): delivered = count
                        default: break
                        }
                    })
                fatalError("Fixture should stop via cancellation after StopLocationInformation")
            } catch is CancellationError {}
            assert(authenticated == 1 && subscribed == 1 && unsubscribed == 1 && delivered == 1)
            assert(Phone.shared.signatures == 1 && Phone.shared.locations == 1 && Phone.shared.locationAttempts == 5)
            assert(Phone.shared.opened == 1 && Phone.shared.closed == 1)
            assert(Phone.shared.sentTypes == [0x1D01, 0xAA01, 0xAA03, 0xFFFB])
        }
        try await task.value
        print(
            "Accessory session checks passed: real handshake/authentication/subscription flow survives malformed messages and four lost ACKs, delivers once, honors stop and closes on cancellation. Simulated USB and signer only."
        )
    }
}
