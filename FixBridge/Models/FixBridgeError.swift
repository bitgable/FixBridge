import Foundation

struct FixBridgeError: LocalizedError {
    enum Recovery: Sendable {
        case usbConnection, usbSession, bluetoothConnection

        var message: String {
            switch self {
            case .usbConnection:
                String(localized: "USB disconnected. Reconnect and unlock your iPhone to retry.")
            case .usbSession:
                String(localized: "USB accessory session interrupted. Unlock your iPhone, then refresh to reconnect.")
            case .bluetoothConnection:
                String(
                    localized:
                        "Bluetooth connection failed. Keep your iPhone unlocked nearby with Bluetooth on, then refresh devices."
                )
            }
        }
    }

    let message: String
    let recovery: Recovery?

    init(_ message: String.LocalizationValue, status: UInt32 = 0, recovery: Recovery? = nil) {
        self.recovery = recovery
        let description = String(localized: message)
        self.message = status == 0 ? description : description + String(format: " (0x%08X)", status)
    }
    static func statusMessage(for error: Error) -> String {
        (error as? FixBridgeError)?.recovery?.message ?? error.localizedDescription
    }

    var errorDescription: String? { message }
}
