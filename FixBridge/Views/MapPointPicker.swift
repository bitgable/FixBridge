import MapKit
import SwiftUI

struct MapPointPicker: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var position: MapCameraPosition
    @StateObject private var model: MapPointPickerViewModel
    @State private var hoveredResultID: MapPointPickerViewModel.SearchResult.ID?
    let useCoordinate: (CLLocationCoordinate2D) -> Void

    init(initialCoordinate: CLLocationCoordinate2D?, useCoordinate: @escaping (CLLocationCoordinate2D) -> Void) {
        _model = StateObject(wrappedValue: MapPointPickerViewModel(initialCoordinate: initialCoordinate))
        let center = initialCoordinate ?? CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        _position = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: center, latitudinalMeters: 4_000, longitudinalMeters: 4_000
                )))
        self.useCoordinate = useCoordinate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Location").font(.headline)
            Text("Click the map or search for a place, then click Use This Location to estimate ground elevation.")
                .foregroundStyle(.secondary)
            addressSearch
                .zIndex(1)
            MapReader { proxy in
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    if let selectedCoordinate = model.selectedCoordinate {
                        Marker("Selected Location", coordinate: selectedCoordinate)
                    }
                }
                .mapControls { MapZoomStepper() }
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { tap in
                        searchFocused = false
                        if model.showsSearchDropdown {
                            model.clearSearch()
                            return
                        }
                        if let point = proxy.convert(tap.location, from: .local), CLLocationCoordinate2DIsValid(point) {
                            model.selectedCoordinate = point
                        }
                    })
            }
            .clipShape(.rect(cornerRadius: 8))
            HStack {
                if let selectedCoordinate = model.selectedCoordinate {
                    let latitude = String(
                        format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), selectedCoordinate.latitude)
                    let longitude = String(
                        format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), selectedCoordinate.longitude)
                    Text(verbatim: "\(latitude)°, \(longitude)°")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Location") {
                    guard let selectedCoordinate = model.selectedCoordinate else { return }
                    useCoordinate(selectedCoordinate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(searchFocused ? nil : .defaultAction)
                .disabled(model.selectedCoordinate == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 500)
        .onDisappear(perform: model.clearSearch)
    }

    private var addressSearch: some View {
        HStack {
            TextField("Search for an address or place", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(model.search)
                .onChange(of: model.query) { model.clearSearch() }
                .onKeyPress(.escape) {
                    guard model.showsSearchDropdown else { return .ignored }
                    model.clearSearch()
                    return .handled
                }
                .overlay {
                    if model.showsSearchDropdown {
                        GeometryReader { field in
                            searchDropdown
                                .frame(width: field.size.width)
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(y: field.size.height + 5)
                        }
                    }
                }
            Button("Search", action: model.search)
                .disabled(!model.canSearch)
        }
    }

    private var searchDropdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isSearching {
                ProgressView("Searching…")
                    .controlSize(.small)
                    .padding(6)
            } else if let searchMessage = model.searchMessage {
                Text(searchMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                Text("Search Results")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.searchResults) { result in
                            Button {
                                model.select(result)
                                position = .region(
                                    MKCoordinateRegion(
                                        center: result.coordinate, latitudinalMeters: 1_000, longitudinalMeters: 1_000
                                    ))
                                searchFocused = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name).lineLimit(1)
                                        if let address = result.address, address != result.name {
                                            Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: 42)
                                .background {
                                    if hoveredResultID == result.id {
                                        RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.08))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering || hoveredResultID == result.id {
                                    hoveredResultID = hovering ? result.id : nil
                                }
                            }
                            .help(result.address ?? result.name)
                        }
                    }
                }
                .frame(height: CGFloat(min(model.searchResults.count, 5)) * 42)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.12))
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.20), radius: 12, y: 4)
    }

}
