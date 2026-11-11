import Combine
import Foundation

/// Owns a single editor draft. The injected operations keep storage ownership in the target view model.
/// Failed validation or persistence never dismisses the sheet or replaces the original saved record.
@MainActor
final class SavedLocationEditorViewModel: ObservableObject {
    @Published var name: String
    @Published var latitude: String
    @Published var longitude: String
    @Published var altitude: String
    @Published private(set) var errorMessage: String?
    @Published private(set) var deletionFailed = false
    private(set) var invalidField: LocationInput.Field?
    let original: LocationDraft
    private let saveDraft: (String, String, String, String) throws -> Void
    private let deleteDraft: (() throws -> Void)?

    var isEditing: Bool { original.name != nil }
    var canDelete: Bool { isEditing && deleteDraft != nil }
    var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(
        draft: LocationDraft, delete: (() throws -> Void)?,
        save: @escaping (String, String, String, String) throws -> Void
    ) {
        original = draft
        name = draft.name ?? ""
        latitude = String(draft.latitude)
        longitude = String(draft.longitude)
        altitude = String(draft.altitude)
        deleteDraft = delete
        saveDraft = save
    }

    func save() -> Bool {
        deletionFailed = false
        invalidField = nil
        let errors = LocationInput(latitude: latitude, longitude: longitude, altitude: altitude).validationErrors
        if let first = LocationInput.Field.allCases.first(where: { errors[$0] != nil }) {
            invalidField = first
            errorMessage = LocationInput.validationSummary(errors)
            return false
        }
        do {
            try saveDraft(name, latitude, longitude, altitude)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete() -> Bool {
        guard canDelete, let deleteDraft else { return false }
        do {
            try deleteDraft()
            errorMessage = nil
            return true
        } catch {
            deletionFailed = true
            invalidField = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func dismissError() { errorMessage = nil }
}
