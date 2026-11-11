import Combine
import Foundation

/// Owns the route library, consent-based import and playback observation.
/// Editors work on an in-memory draft; persistence succeeds before the saved library is published.
@MainActor
final class GPXRouteViewModel: ObservableObject {
    @Published private(set) var savedRoutes: [GPXRoute] = []
    @Published private(set) var hasUnsavedChanges = false
    private let store: SavedRouteStore
    private let lookupElevations: @Sendable ([LocationFix]) async throws -> [Double]
    private var elevationConfirmation: CheckedContinuation<Bool, Never>?
    @Published private(set) var missingElevationCount: Int?
    @Published private(set) var lookingUpElevations = false
    private let readRoute: @Sendable (URL) throws -> GPXRoute
    var canEdit: Bool { !importing && controller == nil }
    var isSaved: Bool { route.map { current in savedRoutes.contains { $0.id == current.id } } ?? false }

    init(
        store: SavedRouteStore = SavedRouteStore(),
        readRoute: @escaping @Sendable (URL) throws -> GPXRoute = {
            try GPXRoute.read($0)
        },
        lookupElevations: @escaping @Sendable ([LocationFix]) async throws -> [Double] = {
            try await TerrainElevation.lookupMany($0)
        }
    ) {
        self.store = store
        self.readRoute = readRoute
        self.lookupElevations = lookupElevations
        do { savedRoutes = try store.load() } catch { self.error = error.localizedDescription }
    }

    @Published private(set) var route: GPXRoute?
    @Published private(set) var importing = false
    @Published var error: String?
    @Published private(set) var playback = RoutePlaybackSnapshot(state: .ready, elapsed: 0)
    private var importTask: Task<Void, Never>?
    private var importID: UUID?
    private var progressTask: Task<Void, Never>?
    private var controller: SessionLocation?

    func importFile(_ url: URL, applyStart: @escaping (LocationFix) -> Void) {
        guard !importing, controller == nil else { return }
        let id = UUID()
        importID = id
        let readRoute = self.readRoute
        importing = true
        error = nil
        importTask = Task { [weak self] in
            defer {
                if self?.importID == id {
                    self?.importing = false
                    self?.importTask = nil
                    self?.importID = nil
                    self?.missingElevationCount = nil
                    self?.lookingUpElevations = false
                }
            }
            do {
                let result: Result<GPXRoute, GPXMissingElevations> = try await BackgroundTask.run {
                    do { return .success(try readRoute(url)) } catch let missing
                        as GPXMissingElevations
                    { return .failure(missing) }
                }
                try Task.checkCancellation()
                guard let self, self.importID == id, self.controller == nil else { return }
                var parsed: GPXRoute
                switch result {
                case .success(let route): parsed = route
                case .failure(let missing):
                    self.missingElevationCount = missing.indices.count
                    let approved = await withCheckedContinuation { self.elevationConfirmation = $0 }
                    try Task.checkCancellation()
                    guard approved, self.importID == id, self.controller == nil else { return }
                    self.lookingUpElevations = true
                    let fixes = missing.indices.map { missing.route.points[$0].fix }
                    let elevations = try await self.lookupElevations(fixes)
                    try Task.checkCancellation()
                    guard self.importID == id, self.controller == nil else { return }
                    guard elevations.count == fixes.count else {
                        throw FixBridgeError(
                            "Elevation lookup returned incomplete data. The route was not imported. Try again or regenerate the GPX file with elevations."
                        )
                    }
                    var points = missing.route.points
                    for (index, elevation) in zip(missing.indices, elevations) {
                        let point = points[index]
                        points[index] = .init(
                            id: point.id,
                            fix: try LocationFix(
                                latitude: point.fix.latitude, longitude: point.fix.longitude,
                                altitude: elevation, duration: point.fix.duration), offset: point.offset)
                    }
                    parsed = try GPXRoute(id: missing.route.id, name: missing.route.name, points: points)
                }
                let imported = try self.makeImportedRoute(parsed)
                let library = self.savedRoutes + [imported]
                try self.persist(library)
                self.savedRoutes = library
                self.route = imported
                self.hasUnsavedChanges = false
                self.playback = .init(state: .ready, elapsed: 0)
                applyStart(imported.start)
            } catch is CancellationError {
            } catch {
                if self?.importID == id { self?.error = FixBridgeError.statusMessage(for: error) }
            }
        }
    }

    private func makeImportedRoute(_ parsed: GPXRoute) throws -> GPXRoute {
        let baseName = parsed.name
        var name = baseName
        var number = 2
        while savedRoutes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let suffix = " (\(number))"
            var prefix = baseName
            while prefix.utf8.count + suffix.utf8.count > GPXRoute.maximumNameBytes {
                prefix.removeLast()
            }
            name = prefix + suffix
            number += 1
        }
        let id = savedRoutes.contains(where: { $0.id == parsed.id }) ? UUID() : parsed.id
        return try GPXRoute(id: id, name: name, points: parsed.points)
    }

    func confirmElevationLookup(_ approved: Bool) {
        missingElevationCount = nil
        let confirmation = elevationConfirmation
        elevationConfirmation = nil
        confirmation?.resume(returning: approved)
    }

    func cancelImport() {
        importID = nil
        confirmElevationLookup(false)
        lookingUpElevations = false
        importTask?.cancel()
        importTask = nil
        importing = false
    }

    func clear() {
        guard !importing, controller == nil else { return }
        route = nil
        hasUnsavedChanges = false
        playback = .init(state: .ready, elapsed: 0)
        error = nil
    }

    func loadSaved(_ id: UUID, applyStart: (LocationFix) -> Void) {
        guard canEdit else { return }
        guard let saved = savedRoutes.first(where: { $0.id == id }) else {
            error = String(localized: "The route no longer exists.")
            return
        }
        route = saved
        hasUnsavedChanges = false
        playback = .init(state: .ready, elapsed: 0)
        error = nil
        applyStart(saved.start)
    }

    func saveCurrent(named name: String) throws {
        try requireEditable()
        guard let route else { throw FixBridgeError("The route no longer exists.") }
        let updated = try renamedRoute(route, name: name)
        var library = savedRoutes.filter { $0.id != updated.id }
        library.append(updated)
        try persist(library)
        savedRoutes = library
        self.route = updated
        hasUnsavedChanges = false
        error = nil
    }

    /// Rename the working draft; Done commits both its name and points together.
    func renameCurrent(to name: String, expectedID: UUID) throws {
        try requireEditable()
        guard let route, route.id == expectedID else {
            throw FixBridgeError("The route changed. Reopen it to edit.")
        }
        let updated = try renamedRoute(route, name: name)
        self.route = updated
        hasUnsavedChanges = !savedRoutes.contains(updated)
        error = nil
    }

    func saveChanges() throws {
        try requireEditable()
        guard let route else { throw FixBridgeError("The route no longer exists.") }
        if hasUnsavedChanges { try saveCurrent(named: route.name) }
    }

    func restoreDraft(_ original: GPXRoute) throws {
        try requireEditable()
        guard route?.id == original.id else { throw FixBridgeError("The route changed. Reopen it to edit.") }
        let restored = try original.validated()
        route = restored
        hasUnsavedChanges = !savedRoutes.contains(restored)
        playback = .init(state: .ready, elapsed: 0)
        error = nil
    }

    func deleteCurrent(expectedID: UUID) throws {
        try requireEditable()
        guard route?.id == expectedID else { throw FixBridgeError("The route changed. Reopen it to edit.") }
        if isSaved { try deleteSaved() } else { clear() }
    }

    private func renamedRoute(_ route: GPXRoute, name: String) throws -> GPXRoute {
        let updated = try GPXRoute(id: route.id, name: name, points: route.points)
        guard
            !savedRoutes.contains(where: {
                $0.id != updated.id && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame
            })
        else { throw FixBridgeError("A route with that name already exists.") }
        return updated
    }

    func deleteSaved() throws {
        try requireEditable()
        guard let route, isSaved else { throw FixBridgeError("The route no longer exists.") }
        let library = savedRoutes.filter { $0.id != route.id }
        try persist(library)
        savedRoutes = library
        clear()
    }

    private func persist(_ library: [GPXRoute]) throws {
        guard try store.load() == savedRoutes else {
            throw FixBridgeError(
                "Saved routes changed in another window or app instance. Quit and reopen FixBridge before saving.")
        }
        try store.save(library)
    }

    private func requireEditable() throws {
        guard canEdit else { throw FixBridgeError("Stop the location session before editing the route.") }
    }

    func attach(_ controller: SessionLocation) {
        cancelImport()
        detach()
        self.controller = controller
        playback = controller.routeSnapshot
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.playback = controller.routeSnapshot
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func detach() {
        progressTask?.cancel()
        progressTask = nil
        controller = nil
        playback = .init(state: .ready, elapsed: 0)
    }

    func togglePlayback() {
        guard let controller else { return }
        if controller.routeSnapshot.state == .playing { controller.pauseRoute() } else { controller.playRoute() }
        playback = controller.routeSnapshot
    }

    var actionTitle: String {
        switch playback.state {
        case .ready: String(localized: "Start Route")
        case .playing: String(localized: "Pause Route")
        case .paused: String(localized: "Resume Route")
        case .finished: String(localized: "Route Finished")
        }
    }

    var timeLabel: String {
        func format(_ seconds: TimeInterval) -> String {
            let value = Int(max(0, seconds))
            return String(format: "%02d:%02d", value / 60, value % 60)
        }
        let total = ceil(route?.duration ?? 0)
        let elapsed = playback.state == .finished ? total : playback.elapsed
        return format(elapsed) + " / " + format(total)
    }
}
