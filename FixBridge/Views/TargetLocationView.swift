import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TargetLocationView: View {
    @ObservedObject var model: TargetLocationViewModel
    @Binding var simulationMode: SimulationMode
    @ObservedObject var routeModel: GPXRouteViewModel
    var editingEnabled = true
    private var usingRoute: Bool { simulationMode == .dynamic && routeModel.route != nil }
    private var targetEditingEnabled: Bool { editingEnabled && !usingRoute && !routeModel.importing }
    @State private var showingDiscardRouteChanges = false
    @State private var pendingRouteReplacement: (() -> Void)?
    @State private var showingRoutePreview = false
    @State private var showingRouteEditor = false
    @State private var choosingGPX = false
    @State private var showingGPXHelp = false
    @State private var showingNetworkGuide = false
    @State private var pointDraft: LocationDraft?
    @State private var pointInputError: String?
    @State private var validationMessage: String?
    @State private var invalidField: LocationInput.Field?
    @State private var showingMapPicker = false
    @State private var showingElevationSource = false
    @FocusState private var focusedField: LocationInput.Field?
    @State private var routeStatistics: GPXRoute.Statistics?

    var body: some View {
        GroupBox("Target Location") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    simulationModePicker
                        .frame(width: 164, alignment: .leading)
                    HStack(spacing: 8) {
                        savedLocationsMenu
                        if usingRoute {
                            Button("Preview Route…") { showingRoutePreview = true }
                                .fixedSize()
                                .disabled(routeModel.importing)
                        } else {
                            Button("Choose on Map…") { showingMapPicker = true }
                                .fixedSize()
                                .disabled(!targetEditingEnabled)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    simulationOptions
                        .frame(width: 164, alignment: .leading)
                    Group {
                        if usingRoute {
                            routeSummary
                        } else {
                            locationFields
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                GridRow {
                    Button("Network Setup…") { showingNetworkGuide = true }
                        .frame(width: 164, alignment: .leading)
                        .opacity(simulationMode == .dynamic ? 1 : 0)
                        .disabled(simulationMode != .dynamic)
                        .accessibilityHidden(simulationMode != .dynamic)
                    locationActions
                }
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) { Divider() }
                    .frame(width: 1)
                    .offset(x: 173)
                    .allowsHitTesting(false)
            }
            .frame(minHeight: 150, alignment: .top)
            .padding(6)
        }
        .onChange(of: model.focusRequest) { _, request in
            guard targetEditingEnabled, let request else { return }
            invalidField = request.field
            validationMessage = LocationInput.validationSummary(model.fieldErrors)
            focusedField = nil
        }
        .alert(
            "Check Location",
            isPresented: Binding(
                get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })
        ) {
            Button("OK", role: .cancel) {
                let field = invalidField
                validationMessage = nil
                Task { @MainActor in
                    await Task.yield()
                    if targetEditingEnabled { focusedField = field }
                }
            }
        } message: {
            Text(validationMessage ?? "")
        }
        .onChange(of: routeModel.route?.id, initial: true) {
            // Route points are immutable. Cache once per route instead of recalculating on playback ticks.
            routeStatistics = routeModel.route?.statistics
        }
        .onChange(of: routeModel.playback.elapsed) { _, elapsed in
            if usingRoute, let route = routeModel.route {
                model.applyLocationFix(route.fix(at: elapsed))
            }
        }
        .onChange(of: model.altitudeLookupStatus) { _, status in
            if status != .estimated { showingElevationSource = false }
        }
        .fileImporter(isPresented: $choosingGPX, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]) {
            result in
            guard editingEnabled, simulationMode == .dynamic else { return }
            switch result {
            case .success(let url):
                replaceRoute {
                    routeModel.importFile(
                        url, applyStart: model.applyLocationFix)
                }
            case .failure(let error):
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                    routeModel.error = error.localizedDescription
                }
            }
        }
        .alert(
            "Missing Route Elevations",
            isPresented: Binding(
                get: { routeModel.missingElevationCount != nil },
                set: { if !$0 { routeModel.confirmElevationLookup(false) } })
        ) {
            Button("Look Up Elevations") { routeModel.confirmElevationLookup(true) }
            Button("Cancel Import", role: .cancel) { routeModel.confirmElevationLookup(false) }
        } message: {
            Text(
                "Some points have no elevation. Choose Look Up Elevations to send those coordinates to Open-Meteo for estimates from Copernicus DEM, or cancel and export the GPX file again with elevations. Existing elevations and timestamps stay unchanged."
            )
        }
        .alert(
            "Route Error",
            isPresented: Binding(get: { routeModel.error != nil }, set: { if !$0 { routeModel.error = nil } })
        ) {
            Button("OK", role: .cancel) { routeModel.error = nil }
        } message: {
            Text(routeModel.error ?? "")
        }
        .alert("Discard Route Changes?", isPresented: $showingDiscardRouteChanges) {
            Button("Discard Changes", role: .destructive) {
                let replacement = pendingRouteReplacement
                pendingRouteReplacement = nil
                if editingEnabled, routeModel.canEdit { replacement?() }
            }
            Button("Cancel", role: .cancel) { pendingRouteReplacement = nil }
        } message: {
            Text("Save the route first if you want to keep these changes.")
        }
        .sheet(isPresented: $showingRoutePreview) {
            RoutePreviewSheet(model: routeModel)
        }
        .sheet(isPresented: $showingRouteEditor) {
            RouteDetailsSheet(model: routeModel)
        }
        .sheet(isPresented: $showingNetworkGuide) { DynamicNetworkGuide() }
        .sheet(isPresented: $showingMapPicker) {
            MapPointPicker(initialCoordinate: model.mapCoordinate) { coordinate in
                guard targetEditingEnabled else { return }
                model.applyMapCoordinate(coordinate)
            }
        }
        .sheet(item: $pointDraft) { point in
            SavedLocationEditorSheet(
                point: point,
                deletePoint: point.name == nil
                    ? nil
                    : {
                        try requireTargetEditing()
                        try model.deleteDraft(point)
                    }
            ) { name, latitude, longitude, altitude in
                try requireTargetEditing()
                if point.name == nil {
                    try model.savePoint(point, named: name)
                } else {
                    try model.updatePoint(
                        point, named: name, latitude: latitude, longitude: longitude, altitude: altitude)
                }
            }
        }

    }

    private func requireTargetEditing() throws {
        guard targetEditingEnabled else {
            throw FixBridgeError("Stop the location session before editing the target.")
        }
    }

    private var savedLocationsMenu: some View {
        Menu {
            Section("Saved Locations") {
                if model.savedPoints.isEmpty {
                    Text("No Saved Locations")
                } else {
                    ForEach(model.savedPoints) { point in
                        Button {
                            replaceRoute {
                                // Resolve the current saved point before removing the working route.
                                guard let current = model.savedPoints.first(where: { $0.id == point.id }) else {
                                    model.loadPoint(point)
                                    return
                                }
                                routeModel.clear()
                                model.loadPoint(current)
                            }
                        } label: {
                            if !usingRoute && model.selectedPointID == point.id {
                                Label(point.name, systemImage: "checkmark")
                            } else {
                                Text(point.name)
                            }
                        }
                    }
                }
            }
            savedRouteItems
            if usingRoute {
                Divider()
                Button("Use Single Location") { replaceRoute { routeModel.clear() } }
            }
        } label: {
            Label(savedTargetTitle, systemImage: "star")
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!editingEnabled || !routeModel.canEdit)
    }

    private var savedTargetTitle: String {
        if usingRoute, let route = routeModel.route { return route.name }
        return model.selectedPointName
            ?? String(localized: model.hasUnsavedTarget ? "New Location" : "Saved Locations")
    }

    private var simulationModePicker: some View {
        SegmentedModeControl(
            title: String(localized: "Simulation Mode"),
            options: [(.normal, String(localized: "Normal")), (.dynamic, String(localized: "Dynamic"))],
            selection: $simulationMode
        )
        .disabled(!editingEnabled || routeModel.importing)
    }

    private var simulationOptions: some View {
        ZStack(alignment: .topLeading) {
            modeDescription(.normal).hidden()
            modeDescription(.dynamic).hidden()
            modeDescription(simulationMode)
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func modeDescription(_ mode: SimulationMode) -> Text {
        switch mode {
        case .normal:
            Text(
                "Keeps the selected coordinates and altitude fixed for most location tests. No network rules needed."
            )
        case .dynamic:
            Text(
                "Gently varies a point or plays a GPX route using its time intervals. Set up rules to block specific location services before starting."
            )
        }
    }

    private var locationFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow(alignment: .firstTextBaseline) {
                Text("Latitude").fixedSize()
                TextField("Latitude", text: $model.latitude, prompt: Text("37.3349"))
                    .accessibilityLabel("Latitude")
                    .focused($focusedField, equals: .latitude)
                    .disabled(!targetEditingEnabled)
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Longitude").fixedSize()
                TextField("Longitude", text: $model.longitude, prompt: Text("-122.0090"))
                    .accessibilityLabel("Longitude")
                    .focused($focusedField, equals: .longitude)
                    .disabled(!targetEditingEnabled)
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Altitude (m)").fixedSize()
                altitudeField.focused($focusedField, equals: .altitude)
            }
        }
        .textFieldStyle(.roundedBorder)
        .help("Coordinates accept decimal degrees or degrees, minutes and seconds.")
    }

    private var locationActions: some View {
        HStack {
            if simulationMode == .dynamic {
                Button {
                    if routeModel.lookingUpElevations {
                        routeModel.cancelImport()
                    } else {
                        choosingGPX = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        if routeModel.importing {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        }
                        Text(
                            routeModel.lookingUpElevations
                                ? "Cancel Import" : (routeModel.importing ? "Importing GPX…" : "Import GPX…")
                        )
                        .lineLimit(1)
                    }
                }
                .disabled(!editingEnabled || (routeModel.importing && !routeModel.lookingUpElevations))
                .accessibilityValue(routeModel.lookingUpElevations ? Text("Looking up elevations…") : Text(""))
                Button {
                    showingGPXHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Creating a GPX Route")
                .popover(isPresented: $showingGPXHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Creating a GPX Route").font(.headline)
                        Text("FixBridge imports and plays GPX routes, but does not include a route editor.")
                        Text(
                            "Create your route in an online editor such as [gpx.studio](https://gpx.studio/), export it as a GPX file, then import it here."
                        )
                        Text(
                            "Include timestamps in the GPX file. FixBridge uses the intervals between them to set the playback pace."
                        )
                        .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 320)
                }
            }
            Spacer(minLength: 4)
            if usingRoute {
                Button("Edit Route…") { showingRouteEditor = true }
                    .disabled(!editingEnabled || !routeModel.canEdit)
            } else {
                savedPointActions
            }
        }
    }

    @ViewBuilder private var savedRouteItems: some View {
        Section("Saved Routes") {
            if routeModel.savedRoutes.isEmpty { Text("No Saved Routes") }
            ForEach(routeModel.savedRoutes) { route in
                Button {
                    replaceRoute {
                        routeModel.loadSaved(route.id) { fix in
                            model.applyLocationFix(fix)
                            simulationMode = .dynamic
                        }
                    }
                } label: {
                    if usingRoute && routeModel.route?.id == route.id {
                        Label(route.name, systemImage: "checkmark")
                    } else {
                        Text(route.name)
                    }
                }
                .disabled(!editingEnabled || !routeModel.canEdit)
            }
        }
    }

    private func replaceRoute(_ replacement: @escaping () -> Void) {
        guard editingEnabled, routeModel.canEdit else { return }
        if routeModel.route != nil && routeModel.hasUnsavedChanges {
            pendingRouteReplacement = replacement
            showingDiscardRouteChanges = true
        } else {
            replacement()
        }
    }

    private var routeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let route = routeModel.route {
                Text("\(route.points.count) route points").font(.headline)
                if let statistics = routeStatistics {
                    HStack(alignment: .top, spacing: 12) {
                        routeMetric(
                            "Distance",
                            value: statistics.distance < 1000
                                ? statistics.distance.formatted(.number.precision(.fractionLength(0))) + " m"
                                : (statistics.distance / 1000).formatted(.number.precision(.fractionLength(2))) + " km")
                        routeMetric(
                            "Duration",
                            value: Duration.seconds(statistics.duration)
                                .formatted(.time(pattern: .hourMinuteSecond)))
                        routeMetric(
                            "Avg. Speed",
                            value: statistics.averageSpeed
                                .formatted(.number.precision(.fractionLength(1))) + " km/h")
                        routeMetric("Est. Activity", value: statistics.activity.localizedTitle)
                    }
                }
                Text(
                    "Holds position before playback, on pause, and at the end."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 88, alignment: .topLeading)
    }

    private func routeMetric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var altitudeField: some View {
        TextField("Altitude (m)", text: $model.altitude, prompt: LocationInputPrompts.altitude)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Altitude (m)")
            .disabled(!targetEditingEnabled)
            .overlay(alignment: .trailing) {
                elevationIndicator
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 6)
            }
    }

    private var selectedPoint: SavedLocation? {
        model.savedPoints.first { $0.id == model.selectedPointID }
    }

    private var savedPointActions: some View {
        HStack(spacing: 8) {
            if let point = selectedPoint {
                Button {
                    pointDraft = LocationDraft(
                        id: point.id, name: point.name, latitude: point.latitude,
                        longitude: point.longitude, altitude: point.altitude)
                } label: {
                    Text("Edit Location…")
                }
                .disabled(!targetEditingEnabled)
            } else {
                Button {
                    guard model.validateForSubmission() else { return }
                    do { pointDraft = try model.preparePoint() } catch { pointInputError = error.localizedDescription }
                } label: {
                    Text("Save Location…")
                }
                .disabled(!targetEditingEnabled || model.altitudeLookupStatus == .loading)
                .alert(
                    "Could Not Save Location",
                    isPresented: Binding(
                        get: { pointInputError != nil },
                        set: { if !$0 { pointInputError = nil } }
                    ), presenting: pointInputError
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { error in
                    Text(error)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var elevationIndicator: some View {
        switch model.altitudeLookupStatus {
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Looking up elevation…")
        case .estimated:
            Button {
                showingElevationSource.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Elevation Source")
            .help("Elevation Source")
            .popover(isPresented: $showingElevationSource, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Elevation Source").font(.headline)
                    Text(
                        "Ground elevation estimated by [Open-Meteo](https://open-meteo.com/en/docs/elevation-api) using [Copernicus DEM](https://doi.org/10.5270/ESA-c5d3d65)."
                    )
                    Text("You can edit this estimate.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(width: 280)
            }
        case .idle:
            Color.clear.accessibilityHidden(true)
        }
    }

}
