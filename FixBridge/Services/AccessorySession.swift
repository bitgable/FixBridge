import Foundation

enum AccessoryEvent: Sendable {
    case transportConnected, linkReady, authenticated
    case reconnecting(Int)
    case subscribed([Int])
    case unsubscribed
    case acknowledged(Int)
    case locationSent(sequence: Int, fix: LocationFix, time: Date)
}

private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

private final class AccessoryLink {
    private enum Stream {
        case usb(OpaquePointer)
        case bluetooth(BluetoothTransport)
    }

    private let stream: Stream
    private let usbIdentifier: String?
    let bluetoothAddress: [UInt8]?
    private var sequence = UInt8.random(in: .min ... .max)
    private var peer: UInt8 = 0
    private var maximumPacket = 4096
    private var retry: TimeInterval = 2
    private var maximumRetransmissions = 5
    private var wireBuffer: [UInt8] = []
    private var controlBuffer: [UInt8] = []
    private var messages: [ControlMessage] = []
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)

    init(connection: AccessoryConnection) throws {
        switch connection {
        case .usb(let identifier):
            usbIdentifier = identifier
            var detail: UnsafePointer<CChar>?
            var status: UInt32 = 0
            guard let usb = fb_usb_open(identifier as CFString, &detail, &status) else {
                let message = detail.map { String(cString: $0) } ?? "Could not open the USB connection."
                let recovery: FixBridgeError.Recovery? =
                    fb_usb_device_presence(identifier as CFString) == 0 ? .usbConnection : nil
                throw FixBridgeError(String.LocalizationValue(message), status: status, recovery: recovery)
            }
            stream = .usb(usb)
            bluetoothAddress = nil
        case .bluetooth(let device):
            usbIdentifier = nil
            let transport = try BluetoothTransport(device: device)
            stream = .bluetooth(transport)
            bluetoothAddress = transport.controllerAddress
        }
    }

    deinit {
        if case .usb(let usb) = stream { fb_usb_close(usb) }
    }

    private func usbFailure(_ usb: OpaquePointer) -> FixBridgeError {
        let presence = usbIdentifier.map { fb_usb_device_presence($0 as CFString) } ?? -1
        let detail = String(cString: fb_usb_last_error(usb))
        print("[FixBridge USB Failure] time=\(Date().timeIntervalSince1970) wiredPresence=\(presence) \(detail)")
        return FixBridgeError(
            "The USB accessory session closed.", recovery: presence == 0 ? .usbConnection : .usbSession)
    }

    func detectBluetoothAccessory(timeout: TimeInterval) throws {
        guard case .bluetooth(let transport) = stream else { return }
        try AccessoryDetection.run(
            timeout: timeout, now: { uptime }, send: { try transport.write($0) },
            receive: { try transport.read(into: $0, timeout: $1) })
    }

    private func write(_ packet: LinkPacket) throws {
        try Task.checkCancellation()
        let bytes = packet.bytes
        switch stream {
        case .usb(let usb):
            let status = bytes.withUnsafeBytes { fb_usb_write(usb, $0.baseAddress, $0.count) }
            if status != 0 {
                throw usbFailure(usb)
            }
        case .bluetooth(let transport):
            try transport.write(bytes)
        }
    }

    private func read(until deadline: TimeInterval) throws -> LinkPacket? {
        while true {
            try Task.checkCancellation()
            if let packet = LinkPacket.parse(from: &wireBuffer) { return packet }
            let remaining = deadline - uptime
            guard remaining > 0 else { return nil }
            let timeout = Int32(min(200, max(1, (remaining * 1000).rounded(.up))))
            let count = try readBuffer.withUnsafeMutableBytes { buffer in
                switch stream {
                case .usb(let usb):
                    let count = fb_usb_read(usb, buffer.baseAddress, buffer.count, timeout)
                    guard count >= 0 else {
                        throw usbFailure(usb)
                    }
                    return Int(count)
                case .bluetooth(let transport):
                    return try transport.read(into: buffer, timeout: timeout)
                }
            }
            guard count <= readBuffer.count else { throw malformed() }
            wireBuffer += readBuffer.prefix(count)
        }
    }

    func handshake() throws {
        let offer = [UInt8(1), 1] + word(4096) + word(2000) + word(22) + [5, 1, 1, 0, 2]
        let syn = LinkPacket(flags: LinkPacket.syn, sequence: sequence, acknowledgement: 0, payload: offer)
        for _ in 0..<3 {
            try write(syn)
            guard let response = try read(until: uptime + 2) else { continue }
            let flags = LinkPacket.syn | LinkPacket.ack
            let data = response.payload
            guard response.flags & flags == flags, response.acknowledgement == sequence,
                let synchronization = LinkSynchronization(payload: data)
            else { throw malformed() }
            maximumPacket = synchronization.maximumPacket
            retry = synchronization.retransmissionInterval
            maximumRetransmissions = synchronization.maximumRetransmissions
            peer = response.sequence
            try acknowledge()
            return
        }
        throw FixBridgeError("The iPhone did not respond to the iAP2 handshake.")
    }

    private func acknowledge() throws {
        try write(LinkPacket(flags: LinkPacket.ack, sequence: sequence, acknowledgement: peer))
    }

    private func accept(_ packet: LinkPacket) throws {
        if packet.flags & LinkPacket.rst != 0 { throw FixBridgeError("The iPhone reset the iAP2 connection.") }
        if packet.flags & LinkPacket.syn != 0 {
            guard peer == packet.sequence else { throw malformed() }
            try acknowledge()
            return
        }
        guard !packet.payload.isEmpty, packet.flags & LinkPacket.eak == 0 else { return }
        if packet.sequence == peer &+ 1 {
            guard packet.session == 1 else { throw malformed() }
            peer = packet.sequence
            controlBuffer += packet.payload
            while controlBuffer.count >= 6 {
                let size = word(controlBuffer, 2)
                guard controlBuffer[0] == 0x40, controlBuffer[1] == 0x40, size >= 6 else {
                    throw malformed()
                }
                if controlBuffer.count < size { break }
                guard messages.count < 256 else { throw malformed() }
                messages.append(ControlMessage(id: word(controlBuffer, 4), body: Array(controlBuffer[6..<size])))
                controlBuffer.removeFirst(size)
            }
        }
        try acknowledge()
    }

    func send(_ id: Int, _ body: [UInt8]) throws {
        let frame = ControlMessage(id: id, body: body).frame
        let chunkSize = maximumPacket - 10
        for offset in stride(from: 0, to: frame.count, by: chunkSize) {
            sequence &+= 1
            let payload = Array(frame[offset..<min(offset + chunkSize, frame.count)])
            var acknowledged = false
            // One initial send, followed by the negotiated number of retransmissions (AIS R2 §24.7.5).
            for _ in 0...maximumRetransmissions {
                try write(
                    LinkPacket(
                        flags: LinkPacket.ack, sequence: sequence,
                        acknowledgement: peer, session: 1, payload: payload))
                let deadline = uptime + retry
                while uptime < deadline, let packet = try read(until: deadline) {
                    try accept(packet)
                    if packet.flags & LinkPacket.ack != 0, packet.acknowledgement == sequence {
                        acknowledged = true
                        break
                    }
                }
                if acknowledged { break }
            }
            guard acknowledged else { throw FixBridgeError("The iPhone did not acknowledge the iAP2 data.") }
        }
    }

    func receive(until deadline: TimeInterval) throws -> ControlMessage? {
        while messages.isEmpty {
            guard uptime < deadline, let packet = try read(until: deadline) else { return nil }
            try accept(packet)
        }
        return messages.removeFirst()
    }
}

enum AccessorySession {
    private static func logLocationControl(_ message: ControlMessage) {
        let hex = message.body.map { String(format: "%02X", $0) }.joined(separator: " ")
        print(String(format: "[FixBridge Location RX] id=0x%04X", message.id) + " body=[\(hex)]")
    }

    // A nil fix is a preflight. It closes the link after authentication and never sends a location.
    static func run(
        connection: AccessoryConnection, identity: MFIIdentity, fix: LocationFix?,
        locations: SessionLocation? = nil, refreshState: LocationRefreshState? = nil, emit: (AccessoryEvent) -> Void
    ) throws {
        var count = 0
        let sessionDeadline = fix.map { locations?.route == nil ? uptime + Double($0.duration) : .infinity }
        if case .usb(let identifier) = connection, fix != nil {
            try USBSessionRecovery.run(
                isDevicePresent: { fb_usb_device_presence(identifier as CFString) == 1 },
                onRetry: { emit(.reconnecting($0)) },
                waitForRefresh: { try refreshState?.waitUntilFinished(deadline: sessionDeadline) },
                operation: {
                    try runAttempt(
                        connection: connection, identity: identity, fix: fix, locations: locations,
                        sessionDeadline: sessionDeadline, count: &count, emit: emit)
                })
        } else {
            try runAttempt(
                connection: connection, identity: identity, fix: fix, locations: locations,
                sessionDeadline: sessionDeadline, count: &count, emit: emit)
        }
    }

    private static func runAttempt(
        connection: AccessoryConnection, identity: MFIIdentity, fix: LocationFix?,
        locations: SessionLocation?, sessionDeadline: TimeInterval?, count: inout Int,
        emit: (AccessoryEvent) -> Void
    ) throws {
        defer { locations?.pause() }
        try Task.checkCancellation()
        if let sessionDeadline, uptime >= sessionDeadline { return }
        let link = try AccessoryLink(connection: connection)
        emit(.transportConnected)
        try link.detectBluetoothAccessory(timeout: fix == nil ? 8 : 30)
        try link.handshake()
        emit(.linkReady)

        let deadline = sessionDeadline ?? (uptime + 12)
        let preparationDeadline = uptime + 15
        var identified = false
        var authenticated = false
        var schedule = LocationSendSchedule()

        while uptime < deadline {
            try Task.checkCancellation()
            if let message = try link.receive(until: min(deadline, uptime + 0.25)),
                let fields = message.receivedParameters()
            {
                switch message.id {
                case 0x1D00:
                    let response = ControlMessage.identity(bluetoothAddress: link.bluetoothAddress)
                    try link.send(response.id, response.body)
                case 0x1D02:
                    identified = true
                case 0x1D03:
                    throw FixBridgeError("The iPhone rejected accessory identification.")
                case 0xAA00:
                    try link.send(0xAA01, parameter(0, Array(identity.certificate)))
                case 0xAA02:
                    let challenges = fields.filter { $0.0 == 0 }
                    try link.send(0xAA03, parameter(0, Array(try identity.sign(challenge: Data(challenges[0].1)))))
                case 0xAA04:
                    throw FixBridgeError("The iPhone rejected MFi-v3 authentication.")
                case 0xAA05:
                    authenticated = true
                    emit(.authenticated)
                    if fix == nil { return }
                case 0xFFFA:
                    logLocationControl(message)
                    guard let subscription = LocationSubscription(parameters: fields) else {
                        print(
                            "[FixBridge Location RX] Ignoring invalid StartLocationInformation; subscription unchanged."
                        )
                        break
                    }
                    schedule.subscription = subscription
                    print(
                        "[FixBridge Location RX] requested=\(subscription.requestedMilliseconds) ms effective=\(subscription.sendInterval) s NMEA=\(subscription.sentenceIDs)"
                    )
                    if subscription.sentenceIDs.isEmpty { locations?.pause() }
                    emit(.subscribed(subscription.sentenceIDs))
                case 0xFFFC:
                    logLocationControl(message)
                    schedule.subscription = nil
                    locations?.pause()
                    emit(.unsubscribed)
                case 0xFFF0:
                    // Diagnostic only: this older AIS does not define this notification.
                    logLocationControl(message)
                default:
                    break
                }
            }

            if fix != nil && (!identified || !authenticated) && uptime >= preparationDeadline {
                throw FixBridgeError("The iPhone did not finish preparing the accessory session.")
            }
            guard let fix, identified, authenticated, uptime < deadline else { continue }
            let now = uptime
            if schedule.isDue(at: now), let subscription = schedule.subscription {
                let due = subscription.sentenceIDs
                let sample = locations?.sample(at: now) ?? SessionLocation.Sample(fix: fix, movementEnabled: false)
                let sentences = sample.fix.sentences()
                let body = due.compactMap { sentences[$0] }.flatMap { textParameter(0, $0) }
                let sentAt = Date()
                try link.send(0xFFFB, body)
                schedule.sent(at: uptime)
                count += 1
                emit(.acknowledged(count))
                emit(.locationSent(sequence: count, fix: sample.fix, time: sentAt))
                if sample.movementEnabled {
                    let coordinate = String(
                        format: "lat=%.7f lon=%.7f alt=%.2f m",
                        locale: Locale(identifier: "en_US_POSIX"), sample.fix.latitude, sample.fix.longitude,
                        sample.fix.altitude)
                    let nmea = due.compactMap { sentences[$0]?.trimmingCharacters(in: .newlines) }.joined(
                        separator: " | ")
                    print(
                        "[FixBridge Movement ACK] #\(count) format=separate parameters=\(due.count) bytes=\(body.count) \(coordinate) | \(nmea)"
                    )
                }

            }
        }
        if fix == nil {
            throw FixBridgeError("The iPhone did not complete the MFi authentication check.")
        }
    }
}
