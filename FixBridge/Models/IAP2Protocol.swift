import Foundation

// Wire layouts follow AIS R2 chapters 24–26; no transport or device access.
func word(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

func word(_ data: [UInt8], _ offset: Int) -> Int {
    Int(data[offset]) << 8 | Int(data[offset + 1])
}

func parameter(_ id: Int, _ bytes: [UInt8] = []) -> [UInt8] {
    word(bytes.count + 4) + word(id) + bytes
}

func textParameter(_ id: Int, _ text: String) -> [UInt8] {
    parameter(id, Array(text.utf8) + [0])
}

struct ControlMessage {
    let id: Int
    let body: [UInt8]

    var frame: [UInt8] { [0x40, 0x40] + word(body.count + 6) + word(id) + body }

    func parameters() throws -> [(Int, [UInt8])] {
        var result: [(Int, [UInt8])] = []
        var offset = 0
        while offset < body.count {
            guard body.count - offset >= 4 else { throw malformed() }
            let length = word(body, offset)
            guard length >= 4, offset + length <= body.count else { throw malformed() }
            result.append((word(body, offset + 2), Array(body[(offset + 4)..<(offset + length)])))
            offset += length
        }
        return result
    }

    /// AIS R2 §25.2.2: invalid control messages are ignored, not fatal to the link.
    /// The 32-byte challenge is the MFi-v3 format used by this app (older AIS uses v2).
    func receivedParameters() -> [(Int, [UInt8])]? {
        guard let fields = try? parameters() else { return nil }
        if id == 0xAA02 {
            let challenges = fields.filter { $0.0 == 0 }
            guard challenges.count == 1, challenges[0].1.count == 32 else { return nil }
        }
        return fields
    }

    static func identity(bluetoothAddress: [UInt8]?) -> ControlMessage {
        var body = ["Accessory Location Lab", "AL-1", "Local Research", "AL-LOCAL-001", "0.1", "1"]
            .enumerated().flatMap { textParameter($0.offset, $0.element) }
        body += parameter(6, word(0xFFFB))
        body += parameter(7, word(0xFFFA) + word(0xFFFC))
        body += parameter(8, [0]) + parameter(9, [0, 0])
        body += textParameter(12, "en") + textParameter(13, "en")
        let transport = parameter(0, [0, 0]) + textParameter(1, "Location Transport") + parameter(2)
        if let bluetoothAddress {
            body += parameter(17, transport + parameter(3, bluetoothAddress))
        } else {
            body += parameter(16, transport)
        }
        let gps = parameter(0, [0, 0]) + textParameter(1, "GPS")
        body += parameter(22, gps + parameter(17) + parameter(18))
        return ControlMessage(id: 0x1D01, body: body)
    }
}

func malformed() -> FixBridgeError {
    FixBridgeError("The iPhone returned invalid iAP2 data.")
}

struct LinkPacket {
    static let syn: UInt8 = 0x80
    static let ack: UInt8 = 0x40
    static let eak: UInt8 = 0x20
    static let rst: UInt8 = 0x10

    let flags: UInt8
    let sequence: UInt8
    let acknowledgement: UInt8
    var session: UInt8 = 0
    var payload: [UInt8] = []

    var bytes: [UInt8] {
        var header: [UInt8] = [0xFF, 0x5A] + word(9 + (payload.isEmpty ? 0 : payload.count + 1))
        header += [flags, sequence, acknowledgement, session]
        header.append(0 &- header.reduce(0, &+))
        if !payload.isEmpty {
            header += payload
            header.append(0 &- payload.reduce(0, &+))
        }
        return header
    }

    /// AIS R2 §24.1.7/9: recover at the next packet marker after a bad checksum.
    /// Retain incomplete frames across transport reads; cap frames at our advertised 4096 bytes.
    static func parse(from buffer: inout [UInt8]) -> LinkPacket? {
        var offset = 0
        defer { if offset > 0 { buffer.removeFirst(offset) } }
        while buffer.count - offset >= 9 {
            let size = word(buffer, offset + 2)
            guard buffer[offset] == 0xFF, buffer[offset + 1] == 0x5A,
                buffer[offset..<(offset + 9)].reduce(0, &+) == 0,
                (9...4096).contains(size), size != 10
            else {
                offset += 1
                continue
            }
            guard buffer.count - offset >= size else { return nil }
            guard buffer[(offset + 9)..<(offset + size)].reduce(0, &+) == 0 else {
                offset += 1
                continue
            }
            let packet = LinkPacket(
                flags: buffer[offset + 4], sequence: buffer[offset + 5], acknowledgement: buffer[offset + 6],
                session: buffer[offset + 7],
                payload: size == 9 ? [] : Array(buffer[(offset + 9)..<(offset + size - 1)]))
            offset += size
            return packet
        }
        return nil
    }
}

/// AIS R2 §24.7.2: retry detection once a second only while the peer is silent.
enum AccessoryDetection {
    static let marker: [UInt8] = [0xFF, 0x55, 0x02, 0, 0xEE, 0x10]

    static func run(
        timeout: TimeInterval, now: () -> TimeInterval,
        send: ([UInt8]) throws -> Void,
        receive: (UnsafeMutableRawBufferPointer, Int32) throws -> Int
    ) throws {
        let deadline = now() + timeout
        var nextProbe = now()
        var reply = [UInt8](repeating: 0, count: marker.count)
        var offset = 0
        while offset < marker.count {
            try Task.checkCancellation()
            let current = now()
            guard current < deadline else {
                throw FixBridgeError(
                    "The iPhone did not respond to Bluetooth accessory detection.", recovery: .bluetoothConnection)
            }
            if offset == 0, current >= nextProbe {
                try send(marker)
                nextProbe = now() + 1
            }
            let remaining = min(0.2, deadline - now())
            let count = try reply.withUnsafeMutableBytes {
                try receive(UnsafeMutableRawBufferPointer(rebasing: $0[offset...]), Int32(max(1, remaining * 1000)))
            }
            guard (0...(marker.count - offset)).contains(count) else { throw malformed() }
            offset += count
            // Any non-iAP2 response is final, including an iAP1 prefix; never retry it.
            guard reply.prefix(offset).elementsEqual(marker.prefix(offset)) else { throw malformed() }
        }
    }
}

/// Accepted SYN parameters. Receive limits remain our own advertised limits.
struct LinkSynchronization {
    let maximumPacket: Int
    let retransmissionInterval: TimeInterval
    let maximumRetransmissions: Int

    init?(payload: [UInt8]) {
        guard payload.count >= 13, payload[0] == 1, (1...127).contains(payload[1]),
            word(payload, 2) >= 24, (20...65535).contains(word(payload, 4)),
            (1...30).contains(payload[8]), payload[9] <= min(127, payload[1]),
            (payload.count - 10).isMultiple(of: 3)
        else { return nil }
        let ackTimeout = word(payload, 6)
        guard ackTimeout == 0 || (10...(word(payload, 4) / 2)).contains(ackTimeout),
            stride(from: 10, to: payload.count, by: 3).contains(where: {
                payload[$0] == 1 && payload[$0 + 1] == 0 && payload[$0 + 2] == 2
            })
        else { return nil }
        maximumPacket = min(word(payload, 2), 4096)
        retransmissionInterval = Double(word(payload, 4)) / 1000
        maximumRetransmissions = Int(payload[8])
    }
}
