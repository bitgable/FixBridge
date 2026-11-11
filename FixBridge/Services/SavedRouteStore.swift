import Foundation

/// Versioned route documents contain their own points; the original GPX is never required after saving.
struct SavedRouteStore: Sendable {
    private struct Library: Codable {
        let version: Int
        let routes: [GPXRoute]
    }
    let url: URL
    init(url: URL? = nil) {
        let supportDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
        self.url =
            url
            ?? supportDirectory
            .appendingPathComponent(
                ApplicationIdentity.storageDirectory(for: ApplicationIdentity.currentIdentifier), isDirectory: true
            )
            .appendingPathComponent("routes-v1.json")
    }

    func load() throws -> [GPXRoute] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 32_000_000 else {
                throw unreadable()
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 32_000_001) ?? Data()
            guard data.count <= 32_000_000 else { throw unreadable() }
            let library = try JSONDecoder().decode(Library.self, from: data)
            guard library.version == 1 else { throw unreadable() }
            try validate(library.routes)
            return library.routes
        } catch { throw unreadable() }
    }

    func save(_ routes: [GPXRoute]) throws {
        // Never overwrite an unreadable existing library.
        _ = try load()
        try validate(routes)
        let data = try JSONEncoder().encode(Library(version: 1, routes: routes))
        guard data.count <= 32_000_000 else {
            throw FixBridgeError("The route library is full. Delete an unused route before saving.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func validate(_ routes: [GPXRoute]) throws {
        guard routes.count <= 200, Set(routes.map(\.id)).count == routes.count,
            routes.reduce(0, { $0 + $1.points.count }) <= 200_000
        else { throw FixBridgeError("The route library is full. Delete an unused route before saving.") }
        for route in routes { _ = try route.validated() }
    }

    private func unreadable() -> FixBridgeError {
        FixBridgeError("Saved routes could not be read. Existing data was left intact.")
    }
}
