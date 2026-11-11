import Foundation

/// Raw user input. Keep text unchanged while typing; parse only for validation or submission.
/// This type is shared by the main target and the saved-location editor so their limits cannot drift.
struct LocationInput {
    static let maximumCoordinateBytes = 128
    var latitude: String
    var longitude: String
    var altitude: String

    enum Field: Hashable, CaseIterable {
        case latitude, longitude, altitude

        var title: String {
            switch self {
            case .latitude: String(localized: "Latitude")
            case .longitude: String(localized: "Longitude")
            case .altitude: String(localized: "Altitude (m)")
            }
        }
    }
    static func validationMessage(for field: Field, text: String, required: Bool = true) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            guard required else { return nil }
            switch field {
            case .latitude: return String(localized: "Enter a latitude.")
            case .longitude: return String(localized: "Enter a longitude.")
            case .altitude: return String(localized: "Enter an altitude.")
            }
        }
        switch field {
        case .latitude, .longitude:
            guard let number = coordinate(text, latitude: field == .latitude), number.isFinite else {
                return String(localized: "Use decimal degrees or degrees, minutes and seconds.")
            }
            let limit = field == .latitude ? 90.0 : 180.0
            if abs(number) > limit {
                return field == .latitude
                    ? String(localized: "Latitude must be between −90 and 90.")
                    : String(localized: "Longitude must be between −180 and 180.")
            }
        case .altitude:
            guard text.utf8.prefix(maximumCoordinateBytes + 1).count <= maximumCoordinateBytes,
                let number = Double(value), number.isFinite,
                (-100_000...100_000).contains(number)
            else { return String(localized: "Enter an altitude between −100,000 and 100,000 meters.") }
        }
        return nil
    }

    private static func coordinate(_ text: String, latitude: Bool) -> Double? {
        guard text.utf8.prefix(Self.maximumCoordinateBytes + 1).count <= Self.maximumCoordinateBytes else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decimal = Double(value) { return decimal }
        let pattern = /^([0-9]{1,3})°\s*([0-9]{1,2})['′]\s*([0-9]{1,2}(?:\.[0-9]+)?)["″]\s*([NSEWnsew])$/
        guard let match = value.wholeMatch(of: pattern),
            let degrees = Double(match.1), let minutes = Double(match.2),
            let seconds = Double(match.3), minutes < 60, seconds < 60
        else { return nil }
        let direction = match.4.uppercased()
        guard (latitude ? ["N", "S"] : ["E", "W"]).contains(direction) else { return nil }
        let magnitude = degrees + minutes / 60 + seconds / 3600
        return ["S", "W"].contains(direction) ? -magnitude : magnitude
    }

    var validationErrors: [Field: String] {
        var errors: [Field: String] = [:]
        for (field, text) in [(Field.latitude, latitude), (.longitude, longitude), (.altitude, altitude)] {
            errors[field] = Self.validationMessage(for: field, text: text)
        }
        return errors
    }

    static func validationSummary(_ errors: [Field: String]) -> String {
        Field.allCases.compactMap { field in
            errors[field].map { field.title + ": " + $0 }
        }.joined(separator: "\n\n")
    }

    func makeFix() throws -> LocationFix {
        guard let lat = Self.coordinate(latitude, latitude: true),
            let lon = Self.coordinate(longitude, latitude: false),
            altitude.utf8.prefix(Self.maximumCoordinateBytes + 1).count <= Self.maximumCoordinateBytes,
            let meters = Double(altitude.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw FixBridgeError("Check the format of the latitude, longitude, and altitude.") }
        return try LocationFix(latitude: lat, longitude: lon, altitude: meters, duration: LocationFix.maximumDuration)
    }

    var decimalCoordinates: (latitude: Double, longitude: Double)? {
        guard let lat = Self.coordinate(latitude, latitude: true),
            let lon = Self.coordinate(longitude, latitude: false),
            (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return (lat, lon)
    }
}
