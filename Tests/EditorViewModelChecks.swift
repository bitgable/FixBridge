import CoreLocation
import Foundation

extension RegressionChecks {
    @MainActor static func checkEditorViewModels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FixBridge-Editors-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = try GPXRoute(
            name: "Original",
            points: [
                .init(fix: try LocationFix(latitude: 10, longitude: 20, altitude: 30, duration: 3600), offset: 0),
                .init(fix: try LocationFix(latitude: 11, longitude: 21, altitude: 31, duration: 3600), offset: 10),
            ])
        let library = GPXRouteViewModel(
            store: SavedRouteStore(url: directory.appendingPathComponent("routes.json")),
            readRoute: { _ in route })
        library.importFile(directory.appendingPathComponent("fixture.gpx")) { _ in }
        try await eventually("editor fixture") { !library.importing }
        let untouched = RouteEditorViewModel(library: library)
        let first = RouteEditorViewModel(library: library)
        let stale = RouteEditorViewModel(library: library)
        first.beginRename()
        first.name = "Working"
        assert(first.commitRename() && library.route?.name == "Working")
        stale.name = "Overwrite"
        assert(!stale.save() && !stale.delete() && library.route?.name == "Working")
        assert(untouched.discard() && library.route?.name == "Working")
        assert(first.discard() && library.route == route)
        let savedEditor = RouteEditorViewModel(library: library)
        savedEditor.name = "Saved"
        assert(savedEditor.save() && library.isSaved && !library.hasUnsavedChanges)
        let conflict = RouteEditorViewModel(library: library)
        conflict.beginRename()
        conflict.name = "Local Draft"
        assert(conflict.commitRename())
        try library.renameCurrent(to: "Another Writer", expectedID: route.id)
        assert(!conflict.discard() && library.route?.name == "Another Writer")
        let active = RouteEditorViewModel(library: library)
        library.attach(SessionLocation(fix: route.start, route: route))
        assert(!active.save() && !active.delete())
        library.detach()

        let failureEditor = RouteEditorViewModel(library: library)
        let beforeFailure = library.route!
        let external = try GPXRoute(name: "External", points: route.points)
        let routeStore = SavedRouteStore(url: directory.appendingPathComponent("routes.json"))
        try routeStore.save(library.savedRoutes + [external])
        failureEditor.name = "Unsaved Name"
        assert(!failureEditor.save() && failureEditor.operationError != nil)
        assert(failureEditor.discard() && library.route == beforeFailure)
        let retainedLibrary = try routeStore.load()
        assert(retainedLibrary.last == external)

        let draft = LocationDraft(id: UUID(), name: "Point", latitude: 10, longitude: 20, altitude: 30)
        var writes = 0
        let pointEditor = SavedLocationEditorViewModel(
            draft: draft,
            delete: {
                throw FixBridgeError("The saved location changed or no longer exists. Reopen it to edit.")
            },
            save: { _, _, _, _ in writes += 1 }
        )
        pointEditor.latitude = "invalid"
        pointEditor.longitude = "181"
        assert(!pointEditor.save() && pointEditor.invalidField == .latitude && writes == 0)
        assert(pointEditor.errorMessage?.contains("Longitude") == true)
        pointEditor.latitude = "10"
        pointEditor.longitude = "20"
        assert(pointEditor.save() && writes == 1)
        assert(!pointEditor.delete() && pointEditor.deletionFailed)
        let failedSave = SavedLocationEditorViewModel(draft: draft, delete: nil) { _, _, _, _ in
            throw FixBridgeError("The saved location changed or no longer exists. Reopen it to edit.")
        }
        assert(!failedSave.save() && failedSave.errorMessage != nil && !failedSave.deletionFailed)
        assert(!failedSave.canDelete && !failedSave.delete())
        let suite = "FixBridge-DeleteDraft-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = TargetLocationViewModel(defaults: defaults)
        let newDraft = LocationDraft(id: UUID(), latitude: 10, longitude: 20, altitude: 30)
        try target.savePoint(newDraft, named: "Point")
        let original = LocationDraft(id: newDraft.id, name: "Point", latitude: 10, longitude: 20, altitude: 30)
        try target.updatePoint(original, named: "Changed", latitude: "10", longitude: "20", altitude: "30")
        expectFailure { try target.deleteDraft(original) }
        assert(target.savedPoints.count == 1 && target.savedPoints.first?.name == "Changed")
        print(
            "Editor checks passed: validation without writes, failed persistence, stale same-ID saves/deletes, cancel isolation and active-session locks."
        )
    }

    @MainActor static func checkAsyncPresentation() async throws {
        // Deliberately ignore cancellation: delayed external services may still complete out of order.
        var replies: [CheckedContinuation<Bool, Error>] = []
        let map = RouteMapViewModel { _ in try await withCheckedThrowingContinuation { replies.append($0) } }
        let old = Task { await map.resolveRegion(.init(latitude: 10, longitude: 20, alignment: .automatic)) }
        try await eventually("old region request") { replies.count == 1 }
        old.cancel()
        let current = Task { await map.resolveRegion(.init(latitude: 11, longitude: 21, alignment: .automatic)) }
        try await eventually("new region request") { replies.count == 2 }
        replies[0].resume(returning: true)
        await old.value
        assert(map.checkingRegion && !map.mainlandRegion)
        replies[1].resume(returning: false)
        await current.value
        assert(!map.checkingRegion && !map.mainlandRegion)
        let pending = Task { await map.resolveRegion(.init(latitude: 12, longitude: 22, alignment: .automatic)) }
        try await eventually("region before manual override") { replies.count == 3 }
        await map.resolveRegion(.init(latitude: 12, longitude: 22, alignment: .original))
        replies[2].resume(returning: true)
        await pending.value
        assert(!map.checkingRegion && !map.mainlandRegion && replies.count == 3)

        let dateline = try GPXRoute(
            name: "Dateline",
            points: [
                .init(fix: try LocationFix(latitude: 10, longitude: 179.99, altitude: 0, duration: 3600), offset: 0),
                .init(fix: try LocationFix(latitude: 10, longitude: -179.99, altitude: 0, duration: 3600), offset: 10),
            ])
        map.update(route: dateline, alignment: .original)
        assert(map.coordinates.count == 2 && map.routeRect.width < 100_000)
        assert(map.coordinates[0].longitude == dateline.start.longitude)
        let many = try GPXRoute(
            name: "Many Points",
            points: (0..<1001).map { index in
                .init(fix: dateline.start, offset: Double(index))
            })
        map.update(route: many, alignment: .original)
        assert(map.coordinates.count == 1001 && map.markers.count <= 200)

        let suite = "FixBridge-ElevationRace-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var elevations: [CheckedContinuation<Double?, Never>] = []
        let target = TargetLocationViewModel(defaults: defaults) { _ in
            await withCheckedContinuation { elevations.append($0) }
        }
        target.applyMapCoordinate(.init(latitude: 10, longitude: 20))
        try await eventually("first terrain request") { elevations.count == 1 }
        target.applyMapCoordinate(.init(latitude: 11, longitude: 21))
        try await eventually("replacement terrain request") { elevations.count == 2 }
        elevations[0].resume(returning: 999)
        await Task.yield()
        assert(target.altitudeLookupStatus == .loading && target.altitude != "999.0")
        target.altitude = "123"
        elevations[1].resume(returning: 456)
        try await Task.sleep(for: .milliseconds(20))
        assert(target.altitude == "123" && target.altitudeLookupStatus == .idle)
        print(
            "Async presentation checks passed: stale region results, loading ownership, manual overrides and user edits during elevation lookup. No external requests."
        )
    }
}
