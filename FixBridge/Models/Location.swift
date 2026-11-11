import Foundation

struct SavedLocation: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

struct LocationDraft: Identifiable {
    let id: UUID
    var name: String? = nil
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

enum SimulationMode: String, Hashable {
    case normal, dynamic
}

enum ConnectionMode: String, Hashable {
    case usb, bluetooth
}

struct LocationFix: Codable, Equatable, Sendable {
    static let maximumDuration = 3600

    let latitude: Double
    let longitude: Double
    let altitude: Double
    let duration: Int

    init(latitude: Double, longitude: Double, altitude: Double, duration: Int) throws {
        try Self.validateTarget(latitude: latitude, longitude: longitude, altitude: altitude)
        guard (1...Self.maximumDuration).contains(duration) else {
            throw FixBridgeError("Duration must be between 1 and 3600 seconds.")
        }
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.duration = duration
    }

    static func validateTarget(latitude: Double, longitude: Double, altitude: Double) throws {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw FixBridgeError("Latitude must be between −90 and 90, and longitude between −180 and 180.")
        }
        guard altitude.isFinite, (-100_000...100_000).contains(altitude) else {
            throw FixBridgeError("Enter an altitude between −100,000 and 100,000 meters.")
        }
    }

    func sentences() -> [Int: String] {
        func coordinate(_ value: Double, latitude: Bool) -> String {
            let units = Int((abs(value) * 600_000).rounded())
            let degrees = units / 600_000
            let minutes = units % 600_000
            let hemisphere = latitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
            let format = latitude ? "%02d%02d.%04d" : "%03d%02d.%04d"
            return String(format: format, degrees, minutes / 10_000, minutes % 10_000)
                + "," + hemisphere
        }
        func nmea(_ body: String) -> String {
            let checksum = body.utf8.reduce(0, ^)
            return "$" + body + String(format: "*%02X\r\n", checksum)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let now = Date()
        formatter.dateFormat = "HHmmss"
        let time = formatter.string(from: now) + ".00"
        formatter.dateFormat = "ddMMyy"
        let date = formatter.string(from: now)
        let point = coordinate(latitude, latitude: true) + "," + coordinate(longitude, latitude: false)
        let meters = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), altitude)
        return [
            1: nmea("GPGGA,\(time),\(point),1,08,0.9,\(meters),M,0.0,M,,"),
            2: nmea("GPRMC,\(time),A,\(point),0.0,0.0,\(date),,,A"),
        ]
    }
}
