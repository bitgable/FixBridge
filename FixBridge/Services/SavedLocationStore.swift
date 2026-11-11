import Foundation

enum SavedLocationStore {
    private static let key = "savedPoints"

    static func load(defaults: UserDefaults = .standard) throws -> [SavedLocation] {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let data = stored as? Data else { throw unreadable() }
        guard data.count <= 2_000_000 else { throw unreadable() }
        do {
            let points = try PropertyListDecoder().decode([SavedLocation].self, from: data)
            try validate(points)
            return points
        } catch { throw unreadable() }
    }

    private static func validate(_ points: [SavedLocation]) throws {
        guard points.count <= 1_000, Set(points.map(\.id)).count == points.count else { throw unreadable() }
        for point in points {
            guard !point.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                point.name.utf8.count <= 512
            else { throw unreadable() }
            try LocationFix.validateTarget(
                latitude: point.latitude, longitude: point.longitude, altitude: point.altitude)
        }
    }

    static func unreadable() -> FixBridgeError {
        FixBridgeError("Saved locations could not be read. Existing data was left intact.")
    }

    static func save(_ points: [SavedLocation], defaults: UserDefaults = .standard) throws {
        guard points.count <= 1_000 else {
            throw FixBridgeError("The saved location library is full. Delete an unused location before saving.")
        }
        try validate(points)
        let data = try PropertyListEncoder().encode(points)
        defaults.set(data, forKey: key)
    }
}
