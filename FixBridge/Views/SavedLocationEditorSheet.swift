import SwiftUI

enum LocationInputPrompts {
    static let latitude = Text("37.3349 or 37°20′05.64″N")
    static let longitude = Text("-122.0090 or 122°00′32.40″W")
    static let altitude = Text(verbatim: "47.43")
}

struct SavedLocationEditorSheet: View {
    @StateObject private var editor: SavedLocationEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool
    @FocusState private var focusedField: LocationInput.Field?

    init(
        point: LocationDraft, deletePoint: (() throws -> Void)? = nil,
        save: @escaping (String, String, String, String) throws -> Void
    ) {
        _editor = StateObject(wrappedValue: SavedLocationEditorViewModel(draft: point, delete: deletePoint, save: save))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.isEditing ? "Edit Saved Location" : "Save Location").font(.headline)
            LabeledContent("Location Name") {
                TextField("Location Name", text: $editor.name, prompt: Text(verbatim: "Apple Park"))
                    .accessibilityLabel("Location Name")
                    .focused($nameFocused)
            }
            if editor.isEditing {
                LabeledContent("Latitude") {
                    TextField("Latitude", text: $editor.latitude, prompt: LocationInputPrompts.latitude)
                        .accessibilityLabel("Latitude")
                        .focused($focusedField, equals: .latitude)
                }
                LabeledContent("Longitude") {
                    TextField("Longitude", text: $editor.longitude, prompt: LocationInputPrompts.longitude)
                        .accessibilityLabel("Longitude")
                        .focused($focusedField, equals: .longitude)
                }
                LabeledContent("Altitude (m)") {
                    TextField("Altitude (m)", text: $editor.altitude, prompt: LocationInputPrompts.altitude)
                        .accessibilityLabel("Altitude (m)")
                        .focused($focusedField, equals: .altitude)
                }
            }
            HStack {
                if editor.canDelete {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Text("Delete Location").foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    focusedField = nil
                    if editor.save() { dismiss() }
                } label: {
                    Text("Save")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
            }
        }
        .labeledContentStyle(LocationEditorFieldStyle())
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 390)
        .alert("Delete Saved Location?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if editor.delete() { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(editor.original.name ?? "")
        }
        .onAppear { nameFocused = true }
        .alert(
            editor.deletionFailed ? "Could Not Delete Location" : "Could Not Save Location",
            isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.dismissError() } })
        ) {
            Button("OK", role: .cancel) {
                let field = editor.invalidField
                editor.dismissError()
                Task { @MainActor in
                    await Task.yield()
                    if let field {
                        nameFocused = false
                        focusedField = field
                    } else {
                        nameFocused = true
                    }
                }
            }
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }
}

private struct LocationEditorFieldStyle: LabeledContentStyle {
    @ScaledMetric(relativeTo: .body) private var labelWidth = 100

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            configuration.label.frame(width: labelWidth, alignment: .leading)
            configuration.content.frame(maxWidth: .infinity)
        }
    }
}
