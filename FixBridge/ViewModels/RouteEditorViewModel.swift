import Combine
import Foundation

/// A transaction for one route editor, shared by inline renaming and the details sheet.
/// The original snapshot supports Cancel; expectedDraft prevents overwriting another editor's changes.
@MainActor
final class RouteEditorViewModel: ObservableObject {
    @Published var name: String
    @Published private(set) var isRenaming = false
    @Published private(set) var renameError: String?
    @Published private(set) var operationError: String?
    private let library: GPXRouteViewModel
    private let originalRoute: GPXRoute?
    private var expectedDraft: GPXRoute?

    init(library: GPXRouteViewModel) {
        self.library = library
        originalRoute = library.route
        expectedDraft = library.route
        name = library.route?.name ?? ""
    }

    func beginRename() {
        guard library.canEdit, library.route?.id == originalRoute?.id else { return }
        name = expectedDraft?.name ?? ""
        renameError = nil
        isRenaming = true
    }

    func commitRename() -> Bool {
        guard isRenaming else { return true }
        do {
            let route = try currentDraft()
            try library.renameCurrent(to: name, expectedID: route.id)
            expectedDraft = library.route
            name = library.route?.name ?? name
            isRenaming = false
            renameError = nil
            return true
        } catch {
            renameError = error.localizedDescription
            return false
        }
    }

    func cancelRename() {
        isRenaming = false
        renameError = nil
        name = expectedDraft?.name ?? ""
    }

    func save() -> Bool {
        do {
            let route = try currentDraft()
            if route.name != name {
                try library.renameCurrent(to: name, expectedID: route.id)
                expectedDraft = library.route
            }
            try library.saveChanges()
            expectedDraft = library.route
            isRenaming = false
            renameError = nil
            operationError = nil
            return true
        } catch {
            // Name errors remain next to the title; storage failures use the operation alert.
            if isRenaming {
                renameError = error.localizedDescription
            } else {
                operationError = error.localizedDescription
            }
            return false
        }
    }

    func discard() -> Bool {
        cancelRename()
        // Opening a read-only preview or canceling an untouched editor must never undo another writer.
        guard expectedDraft != originalRoute else { return true }
        do {
            _ = try currentDraft()
            if let originalRoute { try library.restoreDraft(originalRoute) }
            expectedDraft = originalRoute
            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    func delete() -> Bool {
        do {
            let route = try currentDraft()
            try library.deleteCurrent(expectedID: route.id)
            operationError = nil
            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    func dismissError() { operationError = nil }
    func clearRenameError() { renameError = nil }

    private func currentDraft() throws -> GPXRoute {
        guard library.canEdit else { throw FixBridgeError("Stop the location session before editing the route.") }
        guard let current = library.route, current == expectedDraft, current.id == originalRoute?.id else {
            throw FixBridgeError("The route changed. Reopen it to edit.")
        }
        return current
    }
}
