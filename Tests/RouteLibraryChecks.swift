import Foundation

extension RegressionChecks {
    @MainActor static func checkRouteLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FixBridge-Routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedRouteStore(url: directory.appendingPathComponent("routes.json"))
        let file = directory.appendingPathComponent("original.gpx")
        let xml = """
            <gpx><rte>
            <rtept lat="10" lon="20"><ele>30</ele><time>2000-01-01T00:00:00Z</time></rtept>
            <rtept lat="11" lon="21"><ele>31</ele><time>2000-01-01T00:00:10Z</time></rtept>
            <rtept lat="12" lon="22"><ele>32</ele><time>2000-01-01T00:00:30Z</time></rtept>
            </rte></gpx>
            """
        try Data(xml.utf8).write(to: file)
        let editor = GPXRouteViewModel(store: store)
        editor.importFile(file) { _ in }
        try await eventually("library GPX imported") { !editor.importing }
        let saved = editor.route!
        assert(saved.name == "original" && saved.points.count == 3)
        let persisted = try store.load()
        assert(editor.isSaved && !editor.hasUnsavedChanges && persisted == [saved])
        editor.importFile(file) { _ in }
        try await eventually("same-name GPX imported") { !editor.importing }
        let second = editor.route!
        let savedCopies = try store.load()
        assert(second.name == "original (2)" && second.id != saved.id && savedCopies == [saved, second])
        try editor.deleteCurrent(expectedID: second.id)
        try FileManager.default.removeItem(at: file)
        let restored = GPXRouteViewModel(store: store)
        assert(restored.savedRoutes == [saved])
        var origin: LocationFix?
        restored.loadSaved(saved.id) { origin = $0 }
        assert(origin == saved.start && restored.route == saved && !restored.hasUnsavedChanges)
        try restored.renameCurrent(to: "Updated Walk", expectedID: saved.id)
        assert(restored.hasUnsavedChanges && (try? store.load()) == [saved])
        assert(restored.route?.points == saved.points)
        try restored.saveChanges()
        let before = restored.route!
        let snapshot = SessionLocation(fix: restored.route!.start, route: restored.route!)
        restored.attach(snapshot)
        expectFailure { try restored.renameCurrent(to: "Active", expectedID: saved.id) }
        expectFailure { try restored.deleteSaved() }
        expectFailure { try restored.saveCurrent(named: "Unsafe") }
        assert(snapshot.route == before || snapshot.route?.points == before.points)
        restored.detach()
        try restored.deleteSaved()
        let emptyLibrary = try store.load()
        assert(restored.route == nil && restored.savedRoutes.isEmpty && emptyLibrary.isEmpty)
        // Rename changes the draft, and Done commits it to the saved route.
        try Data(xml.utf8).write(to: file)
        let renameEditor = GPXRouteViewModel(store: store)
        renameEditor.importFile(file) { _ in }
        try await eventually("rename draft imported") { !renameEditor.importing }
        let renameID = renameEditor.route!.id
        let importedSnapshot = renameEditor.route!
        try renameEditor.renameCurrent(to: "Discard This Name", expectedID: renameID)
        try renameEditor.restoreDraft(importedSnapshot)
        assert(renameEditor.route == importedSnapshot && !renameEditor.hasUnsavedChanges && renameEditor.isSaved)
        try renameEditor.renameCurrent(to: "Draft Name", expectedID: renameID)
        assert(renameEditor.hasUnsavedChanges && renameEditor.isSaved)
        let beforeDone = try store.load()
        assert(beforeDone == [importedSnapshot])
        try renameEditor.saveChanges()
        let afterDone = try store.load()
        assert(afterDone == [renameEditor.route!] && renameEditor.isSaved && !renameEditor.hasUnsavedChanges)
        let savedSnapshot = renameEditor.route!
        try renameEditor.renameCurrent(to: "Discard Saved Rename", expectedID: renameID)
        try renameEditor.restoreDraft(savedSnapshot)
        assert(renameEditor.route == savedSnapshot && !renameEditor.hasUnsavedChanges)
        let savedName = renameEditor.route!.name
        try renameEditor.renameCurrent(to: "Updated Name", expectedID: renameID)
        assert(renameEditor.hasUnsavedChanges && (try? store.load().first?.name) == savedName)
        expectFailure { try renameEditor.renameCurrent(to: " ", expectedID: renameID) }
        expectFailure { try renameEditor.renameCurrent(to: "Wrong Route", expectedID: UUID()) }
        assert(renameEditor.route?.name == "Updated Name")
        try renameEditor.saveChanges()
        assert(!renameEditor.hasUnsavedChanges)
        // A failed Done leaves the working name and points available for retry.
        let committed = renameEditor.route!
        try renameEditor.renameCurrent(to: "Keep This Draft", expectedID: renameID)
        let external = try GPXRoute(name: "External", points: committed.points)
        try store.save([committed, external])
        expectFailure { try renameEditor.saveChanges() }
        assert(renameEditor.hasUnsavedChanges && renameEditor.route?.name == "Keep This Draft")
        let retained = try store.load()
        assert(retained == [committed, external])
        let draftBeforeImport = renameEditor.route
        renameEditor.importFile(file) { _ in fatalError("Failed autosave applied a new route") }
        try await eventually("conflicting autosave finished") { !renameEditor.importing }
        let retainedAfterImport = try store.load()
        assert(renameEditor.error != nil && renameEditor.route == draftBeforeImport && retainedAfterImport == retained)
        renameEditor.attach(SessionLocation(fix: committed.start, route: committed))
        expectFailure { try renameEditor.renameCurrent(to: "Active", expectedID: renameID) }
        expectFailure { try renameEditor.saveChanges() }
        expectFailure { try renameEditor.restoreDraft(committed) }
        expectFailure { try renameEditor.deleteCurrent(expectedID: renameID) }
        renameEditor.detach()
        let deleteEditor = GPXRouteViewModel(store: store)
        deleteEditor.loadSaved(committed.id) { _ in }
        expectFailure { try deleteEditor.deleteCurrent(expectedID: UUID()) }
        try deleteEditor.deleteCurrent(expectedID: committed.id)
        let afterDelete = try store.load()
        assert(deleteEditor.route == nil && afterDelete == [external])
        // Missing elevations are never published or queried before explicit user consent.
        let missingFile = directory.appendingPathComponent("missing.gpx")
        try Data(
            xml.replacingOccurrences(of: "<ele>30</ele>", with: "")
                .replacingOccurrences(of: "<ele>32</ele>", with: "").utf8
        ).write(to: missingFile)
        let lookupEditor = GPXRouteViewModel(
            store: store,
            lookupElevations: { points in
                assert(points.count == 2 && points[0].latitude == 10 && points[1].latitude == 12)
                return [101.25, 202.5]
            })
        lookupEditor.loadSaved(external.id) { _ in }
        lookupEditor.importFile(missingFile) { _ in fatalError("Unapproved import") }
        try await eventually("missing elevations require confirmation") { lookupEditor.missingElevationCount == 2 }
        assert(lookupEditor.importing && !lookupEditor.canEdit && lookupEditor.route == external)
        lookupEditor.confirmElevationLookup(false)
        try await eventually("declined elevation lookup") { !lookupEditor.importing }
        assert(lookupEditor.route == external && lookupEditor.error == nil)
        var completedFix: LocationFix?
        lookupEditor.importFile(missingFile) { completedFix = $0 }
        try await eventually("lookup confirmation") { lookupEditor.missingElevationCount == 2 }
        lookupEditor.confirmElevationLookup(true)
        try await eventually("elevations resolved") { !lookupEditor.importing }
        assert(lookupEditor.route?.points.map { $0.fix.altitude } == [101.25, 31, 202.5])
        assert(lookupEditor.route?.points.map(\.offset) == [0, 10, 30] && completedFix?.altitude == 101.25)
        let savedAfterLookup = try store.load()
        assert(lookupEditor.isSaved && !lookupEditor.hasUnsavedChanges && lookupEditor.error == nil)
        assert(savedAfterLookup.last == lookupEditor.route)
        for values in [[Double](), [Double.nan, 1]] {
            let failed = GPXRouteViewModel(store: store, lookupElevations: { _ in values })
            failed.loadSaved(external.id) { _ in }
            failed.importFile(missingFile) { _ in fatalError("Incomplete elevations published") }
            try await eventually("failed lookup confirmation") { failed.missingElevationCount != nil }
            failed.confirmElevationLookup(true)
            try await eventually("failed lookup finished") { !failed.importing }
            assert(failed.route == external && failed.error != nil && !failed.lookingUpElevations)
        }
        // Cancellation while a server ignores cancellation must not replace an existing route.
        let delayed = GPXRouteViewModel(
            store: store,
            lookupElevations: { _ in
                try? await Task.sleep(for: .milliseconds(100))
                return [101, 202]
            })
        delayed.loadSaved(external.id) { _ in }
        delayed.importFile(missingFile) { _ in fatalError("Cancelled lookup published") }
        try await eventually("cancelled confirmation ready") { delayed.missingElevationCount != nil }
        delayed.cancelImport()
        assert(!delayed.importing && delayed.missingElevationCount == nil)
        delayed.importFile(missingFile) { _ in fatalError("Cancelled network lookup published") }
        try await eventually("second confirmation ready") { delayed.missingElevationCount != nil }
        delayed.confirmElevationLookup(true)
        try await eventually("lookup running") { delayed.lookingUpElevations }
        delayed.cancelImport()
        delayed.importFile(file) { _ in }
        try await eventually("replacement import after cancelled lookup") { !delayed.importing }
        let replacement = delayed.route
        try await Task.sleep(for: .milliseconds(150))
        assert(delayed.route == replacement && delayed.route?.points.map { $0.fix.altitude } == [30, 31, 32])
        assert(!delayed.importing && delayed.error == nil && delayed.missingElevationCount == nil)
        let savedAfterCancellation = try store.load()
        assert(savedAfterCancellation.count == savedAfterLookup.count + 1 && savedAfterCancellation.last == replacement)
        // Invalid or future-version data must never be overwritten during a subsequent save.
        for invalid in [Data("not json".utf8), Data("{\"version\":999,\"routes\":[]}".utf8)] {
            try invalid.write(to: store.url)
            expectFailure { _ = try store.load() }
            expectFailure { try store.save([saved]) }
            let retainedData = try Data(contentsOf: store.url)
            assert(retainedData == invalid)
        }
        let duplicate = GPXRoute.Point(id: saved.points[0].id, fix: saved.points[1].fix, offset: 10)
        expectFailure { _ = try GPXRoute(name: "Bad", points: [saved.points[0], duplicate]) }
        expectFailure { _ = try GPXRoute(name: " ", points: saved.points) }
        print(
            "Route library checks passed: persistence without GPX, stable point IDs, rename validation, draft isolation, unchanged route points, active-session locks, atomic storage protection."
        )
    }

    @MainActor static func checkTargetCRUD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FixBridge-TargetAudit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FixBridge-TargetAudit-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let location = TargetLocationViewModel(defaults: defaults)
        location.latitude = "1"
        location.longitude = "2"
        location.altitude = "3"
        let fresh = try location.preparePoint()
        try location.savePoint(fresh, named: "Original")
        let saved = location.savedPoints[0]
        let draft = LocationDraft(
            id: saved.id, name: saved.name, latitude: saved.latitude,
            longitude: saved.longitude, altitude: saved.altitude)
        try location.updatePoint(draft, named: "Renamed", latitude: "4", longitude: "5", altitude: "6")
        assert(location.selectedPointName == "Renamed" && location.latitude == "4.0")
        expectFailure { try location.updatePoint(draft, named: "Stale", latitude: "7", longitude: "8", altitude: "9") }
        location.loadPoint(saved)  // Resolve an old menu item to the latest saved values.
        assert(location.latitude == "4.0" && location.selectedPointName == "Renamed")
        let changed = location.savedPoints[0]
        try location.removePoint(changed)
        expectFailure {
            try location.updatePoint(draft, named: "Resurrected", latitude: "7", longitude: "8", altitude: "9")
        }
        expectFailure { try location.savePoint(draft, named: "Resurrected") }
        expectFailure { try location.removePoint(changed) }
        assert(location.savedPoints.isEmpty)
        let before = location.latitude
        location.loadPoint(changed)
        assert(location.selectedPointID == nil && location.latitude == before && location.error != nil)
        try location.savePoint(try location.preparePoint(), named: "New")
        let first = location.savedPoints[0]
        let secondDraft = try location.preparePoint()
        try location.savePoint(secondDraft, named: "Second")
        let firstDraft = LocationDraft(
            id: first.id, name: first.name, latitude: first.latitude,
            longitude: first.longitude, altitude: first.altitude)
        expectFailure {
            try location.updatePoint(firstDraft, named: "SECOND", latitude: "1", longitude: "2", altitude: "3")
        }
        expectFailure {
            try location.updatePoint(firstDraft, named: "Invalid", latitude: "91", longitude: "2", altitude: "3")
        }
        assert(location.savedPoints.count == 2 && location.selectedPointID == secondDraft.id)
        try location.removePoint(first)
        assert(location.selectedPointID == secondDraft.id && location.selectedPointName == "Second")
        let snapshot = defaults.data(forKey: "savedPoints")!
        defaults.set(Data("corrupt".utf8), forKey: "savedPoints")
        expectFailure { try location.savePoint(try location.preparePoint(), named: "Do not overwrite") }
        assert(defaults.data(forKey: "savedPoints") == Data("corrupt".utf8))
        defaults.set(snapshot, forKey: "savedPoints")
        let otherPoint = SavedLocation(id: UUID(), name: "External", latitude: 7, longitude: 8, altitude: 9)
        try SavedLocationStore.save([otherPoint], defaults: defaults)
        expectFailure { try location.removePoint(location.savedPoints[0]) }
        let externalPoints = try SavedLocationStore.load(defaults: defaults)
        assert(externalPoints == [otherPoint])

        let fix = try LocationFix(latitude: 1, longitude: 2, altitude: 3, duration: 3600)
        let route = try GPXRoute(name: "First", points: [.init(fix: fix, offset: 0), .init(fix: fix, offset: 10)])
        let other = try GPXRoute(name: "Other", points: route.points)
        let store = SavedRouteStore(url: directory.appendingPathComponent("routes.json"))
        try store.save([route, other])
        let editor = GPXRouteViewModel(store: store)
        editor.loadSaved(route.id) { _ in }
        editor.loadSaved(UUID()) { _ in fatalError("Unknown route supplied a point") }
        assert(editor.route == route && editor.error != nil)
        expectFailure { try editor.saveCurrent(named: " other ") }
        assert(editor.route == route && !editor.hasUnsavedChanges)
        try store.save([route])
        expectFailure { try editor.deleteSaved() }
        assert(editor.route == route && editor.savedRoutes.count == 2)
        let externalRoutes = try store.load()
        assert(externalRoutes == [route])
        editor.clear()
        expectFailure { try editor.saveCurrent(named: "No route") }
        expectFailure { try editor.deleteSaved() }
        let directoryStore = SavedRouteStore(url: directory)
        expectFailure { _ = try directoryStore.load() }

        // Cancelled import A finishes while import B is still running. A must not clear B's busy state.
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
        }
        let importer = GPXRouteViewModel(store: SavedRouteStore(url: directory.appendingPathComponent("import.json"))) {
            url in
            if url.lastPathComponent == "first" {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
                firstFinished.signal()
                return route
            }
            secondStarted.signal()
            _ = releaseSecond.wait(timeout: .now() + 5)
            return other
        }
        var applied: [LocationFix] = []
        importer.importFile(directory.appendingPathComponent("first")) { applied.append($0) }
        try await eventually("first import started") { firstStarted.wait(timeout: .now()) == .success }
        importer.cancelImport()
        assert(!importer.importing)
        importer.importFile(directory.appendingPathComponent("second")) { applied.append($0) }
        try await eventually("second import started") { secondStarted.wait(timeout: .now()) == .success }
        releaseFirst.signal()
        try await eventually("cancelled worker returned") { firstFinished.wait(timeout: .now()) == .success }
        try await Task.sleep(for: .milliseconds(50))
        assert(importer.importing && importer.route == nil && applied.isEmpty && importer.error == nil)
        releaseSecond.signal()
        try await eventually("replacement import completed") { !importer.importing }
        assert(importer.route == other && applied == [other.start])
        importer.clear()
        importer.importFile(directory.appendingPathComponent("second")) { _ in
            fatalError("Cancelled import applied")
        }
        importer.cancelImport()
        try await Task.sleep(for: .milliseconds(30))
        assert(importer.route == nil && !importer.importing)
        print(
            "Target CRUD checks passed: stale drafts, deleted IDs, external storage changes, duplicate names, missing routes, import cancellation and replacement races."
        )
    }

}
