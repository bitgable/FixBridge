import Foundation

@main
struct IAP2ProtocolChecks {
    static func reject(_ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Expected rejection")
        } catch {}
    }

    static func main() throws {
        let message = ControlMessage(id: 0xFFFA, body: parameter(2) + parameter(0, [0, 0, 0, 250]) + parameter(1))
        let packet = LinkPacket(
            flags: .init(0x40), sequence: 255, acknowledgement: 0, session: 1, payload: message.frame)
        let wire = packet.bytes
        // Every possible split of a frame survives a transport timeout without losing bytes.
        for split in 0..<wire.count {
            var buffer = Array(wire.prefix(split))
            assert(LinkPacket.parse(from: &buffer) == nil)
            buffer += wire.dropFirst(split)
            let decoded = LinkPacket.parse(from: &buffer)!
            assert(decoded.sequence == 255 && decoded.payload == message.frame && buffer.isEmpty)
        }
        var headerDamage = wire
        headerDamage[8] ^= 1
        var payloadDamage = wire
        payloadDamage[payloadDamage.count - 1] ^= 1
        // Discard corruption, not the following valid frame; two frames in one read are distinct.
        for damage in [headerDamage, payloadDamage, Array(wire.dropFirst()), [UInt8](repeating: 0xFF, count: 50_000)] {
            var buffer = damage + wire + wire
            let first = LinkPacket.parse(from: &buffer)!
            let second = LinkPacket.parse(from: &buffer)!
            assert(first.payload == message.frame && second.sequence == 255 && buffer.isEmpty)
        }
        for invalidSize in [0, 8, 10, 4097, 65535] {
            var invalid: [UInt8] = [0xFF, 0x5A] + word(invalidSize) + [0x40, 1, 1, 1]
            invalid.append(0 &- invalid.reduce(0, &+))
            var buffer = invalid + wire
            assert(LinkPacket.parse(from: &buffer)?.payload == message.frame)
        }
        // Preserve a packet marker split across reads, even after unframed garbage.
        var buffer = [UInt8](repeating: 0x12, count: 100) + [0xFF]
        assert(LinkPacket.parse(from: &buffer) == nil && buffer.count <= 8)
        buffer += wire.dropFirst()
        assert(LinkPacket.parse(from: &buffer)?.sequence == 255)
        let ack = LinkPacket(flags: 0x40, sequence: 0, acknowledgement: 255)
        buffer = ack.bytes
        assert(LinkPacket.parse(from: &buffer)?.payload.isEmpty == true)
        let maximum = LinkPacket(
            flags: 0x40, sequence: 0, acknowledgement: 255, session: 1,
            payload: [UInt8](repeating: 0x33, count: 4086))
        buffer = maximum.bytes
        assert(buffer.count == 4096 && (LinkPacket.parse(from: &buffer)?.payload.count) == 4086)

        let fields = message.receivedParameters()!
        assert(LocationSubscription(parameters: fields)?.requestedMilliseconds == 250)
        for body: [UInt8] in [[0], [0, 3, 0, 0], [0, 5, 0, 0]] {
            assert(ControlMessage(id: 0xFFFA, body: body).receivedParameters() == nil)
        }
        // Bad challenge parameters are ignored before touching the private key.
        for body in [
            [], parameter(0), parameter(0, [UInt8](repeating: 0, count: 31)),
            parameter(0, [UInt8](repeating: 0, count: 32)) + parameter(0),
        ] {
            assert(ControlMessage(id: 0xAA02, body: body).receivedParameters() == nil)
        }
        let validChallenge = ControlMessage(
            id: 0xAA02,
            body:
                parameter(42, [9, 8]) + parameter(0, [UInt8](repeating: 7, count: 32)))
        assert(validChallenge.receivedParameters()?.count == 2)
        assert(ControlMessage(id: 0xFFFC, body: []).receivedParameters()?.isEmpty == true)

        let offer: [UInt8] = [1, 1] + word(4096) + word(2000) + word(22) + [5, 1, 1, 0, 2]
        let accepted = LinkSynchronization(payload: offer)!
        assert(accepted.maximumPacket == 4096 && accepted.retransmissionInterval == 2)
        assert(accepted.maximumRetransmissions == 5)
        var slow = offer
        slow[4] = 0xFF
        slow[5] = 0xFF
        slow[8] = 30
        assert(LinkSynchronization(payload: slow)?.retransmissionInterval == 65.535)
        var fast = offer
        fast[4] = 0
        fast[5] = 20
        fast[6] = 0
        fast[7] = 0
        assert(LinkSynchronization(payload: fast)?.retransmissionInterval == 0.02)
        for (offset, value): (Int, UInt8) in [(0, 2), (1, 0), (1, 128), (8, 0), (8, 31), (9, 2), (10, 0), (12, 1)] {
            var invalid = offer
            invalid[offset] = value
            assert(LinkSynchronization(payload: invalid) == nil)
        }
        for value in [0, 19] {
            var invalid = fast
            invalid[5] = UInt8(value)
            assert(LinkSynchronization(payload: invalid) == nil)
        }
        var invalidAck = fast
        invalidAck[7] = 11
        assert(LinkSynchronization(payload: invalidAck) == nil)
        var invalidPacket = offer
        invalidPacket[2] = 0
        invalidPacket[3] = 23
        assert(LinkSynchronization(payload: invalidPacket) == nil)
        assert(LinkSynchronization(payload: Array(offer.dropLast())) == nil)

        var clock = 0.0
        var probes: [Double] = []
        var responseOffset = 0
        try AccessoryDetection.run(
            timeout: 10, now: { clock },
            send: { bytes in
                assert(bytes == AccessoryDetection.marker)
                probes.append(clock)
            },
            receive: { buffer, timeout in
                clock += Double(timeout) / 1000
                guard clock >= 2.5 else { return 0 }
                buffer[0] = AccessoryDetection.marker[responseOffset]
                responseOffset += 1
                return 1
            })
        assert(probes.count == 3 && responseOffset == 6)
        for pair in zip(probes, probes.dropFirst()) { assert(pair.1 - pair.0 >= 1) }

        clock = 0
        probes = []
        reject {
            try AccessoryDetection.run(
                timeout: 2.5, now: { clock }, send: { _ in probes.append(clock) },
                receive: { _, timeout in
                    clock += Double(timeout) / 1000
                    return 0
                })
        }
        assert(probes.count == 3 && clock < 2.51)
        clock = 0
        probes = []
        reject {
            try AccessoryDetection.run(
                timeout: 3, now: { clock }, send: { _ in probes.append(clock) },
                receive: { buffer, _ in
                    buffer[0] = 0x55
                    clock += 0.1
                    return 1
                })
        }
        assert(probes.count == 1)
        reject {
            try AccessoryDetection.run(timeout: 1, now: { 0 }, send: { _ in }, receive: { _, _ in 7 })
        }
        do {
            try AccessoryDetection.run(
                timeout: 1, now: { 0 }, send: { _ in throw CancellationError() },
                receive: { _, _ in fatalError("Read after cancellation") })
            fatalError("Expected cancellation")
        } catch is CancellationError {}
        print(
            "iAP2 protocol checks passed: fragmented/max-size frames, checksums, stream resynchronization, invalid controls/challenges, detection retry/timeout/cancellation. No device access."
        )
    }
}
