import Foundation

enum PhoneSettings {
    enum Target: Sendable {
        case usb(String)
        case bluetooth(uniqueName: String?)
    }

    static func openLocationServices(for target: Target) async throws {
        try await BackgroundTask.run(priority: .userInitiated) {
            try launchLocationServices(for: target)
        }
    }

    static func wiredDeviceNames() throws -> [String: String] {
        let (_, phones) = try physicalPhones()
        var names: [String: String] = [:]
        for phone in phones where phone.isWired {
            if let udid = phone.udid, let name = phone.name, !name.isEmpty {
                names[udid.lowercased()] = name
            }
        }
        return names
    }

    private static func launchLocationServices(for target: Target) throws {
        let (tool, phones) = try physicalPhones()
        let phone: DeviceList.Device
        switch target {
        case .usb(let id):
            guard let wired = phones.first(where: { $0.isWired && $0.udid?.lowercased() == id.lowercased() }) else {
                throw FixBridgeError("Could not find the selected USB iPhone in Xcode’s device tools.")
            }
            phone = wired
        case .bluetooth(let uniqueName):
            guard let uniqueName else {
                throw FixBridgeError("The Bluetooth iPhone’s name is missing or shared by another paired device.")
            }
            // Bluetooth and CoreDevice expose different identifiers. Never guess among duplicate names.
            let matches = phones.filter { $0.name == uniqueName }
            guard matches.count <= 1 else {
                throw FixBridgeError("More than one iPhone in Xcode has the selected Bluetooth device’s name.")
            }
            guard let match = matches.first else {
                throw FixBridgeError("Xcode could not find the selected Bluetooth iPhone. Check Device Hub and Wi-Fi.")
            }
            phone = match
        }

        _ = try ToolProcess.capture(
            tool,
            arguments: [
                "device", "process", "launch", "--timeout", "12", "--device", phone.identifier,
                "--payload-url", "settings-navigation://com.apple.Settings.PrivacyAndSecurity/LOCATION",
                "com.apple.Preferences",
            ], timeout: .seconds(14), outputLimit: 256 * 1024,
            failure: "Could not open Settings. Unlock your iPhone and check Developer Mode.")
    }

    private static func deviceTool() throws -> URL {
        let toolsError: String.LocalizationValue = "Automatic Settings opening requires Xcode’s device tools."
        let path: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
            path = override
        } else {
            let selector = URL(fileURLWithPath: "/usr/bin/xcode-select")
            let data = try ToolProcess.capture(
                selector, arguments: ["-p"], timeout: .seconds(3),
                outputLimit: 8192, failure: toolsError)
            path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard path.hasPrefix("/") else { throw FixBridgeError(toolsError) }
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        if directory.pathExtension == "app" {
            directory = directory.appending(path: "Contents/Developer")
        }
        let tool = directory.appending(path: "usr/bin/devicectl")
        // Check for the actual binary first. This avoids xcrun’s tool-install prompt on a fresh Mac.
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw FixBridgeError(toolsError)
        }
        return tool
    }

    private static func physicalPhones() throws -> (URL, [DeviceList.Device]) {
        let tool = try deviceTool()
        let discoveryError: String.LocalizationValue = "Could not find the iPhone with Xcode’s device tools."
        let data = try ToolProcess.capture(
            tool, arguments: ["list", "devices", "--timeout", "8", "--json-output", "-"],
            timeout: .seconds(10), outputLimit: 4 * 1024 * 1024,
            failure: discoveryError)
        guard let output = try? JSONDecoder().decode(DeviceList.self, from: data) else {
            throw FixBridgeError(discoveryError)
        }
        return (tool, output.result.devices.filter(\.isPhysicalIPhone))
    }

    private struct DeviceList: Decodable {
        let result: Result

        struct Result: Decodable {
            let devices: [Device]
        }

        struct Device: Decodable {
            let identifier: String
            let properties: Properties?
            let hardwareProperties: Hardware?
            let connectionProperties: Connection?
            let deviceProperties: DeviceProperties?

            var udid: String? { (properties?.hardware ?? hardwareProperties)?.udid }

            var name: String? { (properties?.state ?? deviceProperties)?.name }

            var isWired: Bool {
                (properties?.connection ?? connectionProperties)?.transportType == "wired"
            }

            var isPhysicalIPhone: Bool {
                let hardware = properties?.hardware ?? hardwareProperties
                return hardware?.reality == "physical" && hardware?.deviceType == "iPhone"
            }
        }

        struct Properties: Decodable {
            let hardware: Hardware?
            let connection: Connection?
            let state: DeviceProperties?
        }

        struct DeviceProperties: Decodable {
            let name: String?
        }

        struct Hardware: Decodable {
            let udid: String?
            let reality: String?
            let deviceType: String?
        }

        struct Connection: Decodable {
            let transportType: String?
        }
    }
}
