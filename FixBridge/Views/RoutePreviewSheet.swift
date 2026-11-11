import SwiftUI

struct RoutePreviewSheet: View {
    @ObservedObject var model: GPXRouteViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mapAlignment = RouteMapAlignment.automatic
    @State private var checkingMapRegion = false
    @State private var selection: UUID?
    @State private var statistics: GPXRoute.Statistics?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(model.route?.name ?? String(localized: "Preview Route"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let route = model.route, let statistics {
                    routeSummary(statistics, pointCount: route.points.count)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            if let route = model.route {
                RouteMapPreview(
                    route: route, selection: $selection, alignment: $mapAlignment,
                    checkingRegion: $checkingMapRegion
                )
                .padding(.horizontal, 12).padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 8) {
                mapCoordinatesPicker
                Spacer(minLength: 8)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 480)
        .onChange(of: model.route, initial: true) { statistics = model.route?.statistics }
        .onChange(of: model.route?.id) { dismiss() }
        .onExitCommand { dismiss() }
    }

    private var mapCoordinatesPicker: some View {
        HStack(spacing: 8) {
            Picker("Map Coordinates", selection: $mapAlignment) {
                Text("Automatic").tag(RouteMapAlignment.automatic)
                Text("WGS-84 (Original)").tag(RouteMapAlignment.original)
                Text("GCJ-02 (Mainland China)").tag(RouteMapAlignment.mainland)
            }
            .pickerStyle(.menu)
            .fixedSize()
            if mapAlignment == .automatic && checkingMapRegion {
                ProgressView().controlSize(.mini)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func routeSummary(_ statistics: GPXRoute.Statistics, pointCount: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            summaryValue("Route Points", value: pointCount.formatted(.number.grouping(.never)))
            summaryValue(
                "Duration",
                value: Duration.seconds(statistics.duration).formatted(.time(pattern: .hourMinuteSecond)))
            summaryValue(
                "Distance",
                value: (statistics.distance / 1000).formatted(.number.precision(.fractionLength(2))) + " km")
            summaryValue(
                "Avg. Speed",
                value: statistics.averageSpeed.formatted(.number.precision(.fractionLength(1))) + " km/h")
            summaryValue("Est. Activity", value: statistics.activity.localizedTitle)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route Statistics")
    }

    private func summaryValue(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

struct RouteDetailsSheet: View {
    @ObservedObject var model: GPXRouteViewModel
    @StateObject private var editor: RouteEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false

    init(model: GPXRouteViewModel) {
        self.model = model
        _editor = StateObject(wrappedValue: RouteEditorViewModel(library: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Route").font(.headline)
            LabeledContent("Route Name") { TextField("Route Name", text: $editor.name) }
                .textFieldStyle(.roundedBorder)
                .disabled(!model.canEdit)
            if let error = editor.operationError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(role: .destructive) {
                    confirmingDeletion = true
                } label: {
                    Text("Delete Route").foregroundStyle(model.canEdit ? Color.red : Color.secondary)
                }
                .disabled(!model.canEdit)
                Spacer()
                Button("Cancel") { if editor.discard() { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    if editor.save() { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canEdit || editor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 390)
        .onChange(of: editor.name) { editor.dismissError() }
        .onChange(of: model.route?.id) { dismiss() }
        .alert("Delete Route?", isPresented: $confirmingDeletion) {
            Button("Delete", role: .destructive) {
                if editor.delete() { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The route and all its points will be deleted. This cannot be undone.")
        }
    }
}
