import MapKit
import SwiftUI

struct RouteMapPreview: View {
    let route: GPXRoute
    @Binding var selection: UUID?
    @Binding var alignment: RouteMapAlignment
    @Binding var checkingRegion: Bool
    @StateObject private var model = RouteMapViewModel()
    @State private var camera: MapCameraPosition = .automatic

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return route.points.firstIndex { $0.id == selection }
    }

    private func numberedMarker(_ marker: RouteMapViewModel.NumberedMapPoint) -> some View {
        Button {
            selection = marker.id
        } label: {
            Text(marker.number, format: .number.grouping(.never))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22)
                .background(selection == marker.id ? Color.orange : Color.blue, in: .circle)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Point \(marker.number)"))
    }

    var body: some View {
        VStack(spacing: 8) {
            Map(position: $camera, selection: $selection) {
                MapPolyline(coordinates: model.coordinates)
                    .stroke(.blue, lineWidth: 3)
                if let first = route.points.first {
                    Marker("Route Start", systemImage: "play.fill", coordinate: model.coordinate(first)).tint(.green)
                        .tag(
                            first.id)
                }
                if let last = route.points.last {
                    Marker("Finish", systemImage: "flag.checkered", coordinate: model.coordinate(last)).tint(.red).tag(
                        last.id)
                }
                ForEach(model.markers) { marker in
                    Annotation("", coordinate: model.coordinate(marker.point)) {
                        numberedMarker(marker)
                    }
                    .tag(marker.id)
                }
                if let index = selectedIndex, index > 0, index < route.points.count - 1,
                    !model.markers.contains(where: { $0.id == route.points[index].id })
                {
                    Marker("Point \(index + 1)", coordinate: model.coordinate(route.points[index]))
                        .tint(.orange).tag(route.points[index].id)
                }
            }
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .overlay(alignment: .topLeading) {
                if let index = selectedIndex {
                    let point = route.points[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Point \(index + 1)").fontWeight(.semibold)
                        Text(
                            verbatim: String(
                                format: "%.7f, %.7f · %.2f m", locale: Locale(identifier: "en_US_POSIX"),
                                point.fix.latitude, point.fix.longitude, point.fix.altitude)
                        )
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    camera = .rect(model.routeRect)
                } label: {
                    Text("Show Entire Route")
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .onAppear { model.update(route: route, alignment: alignment) }
        .onChange(of: route) { model.update(route: route, alignment: alignment) }
        .onChange(of: alignment) { model.update(route: route, alignment: alignment) }
        .onReceive(model.$routeRect) { camera = .rect($0) }
        .onChange(of: model.checkingRegion) { checkingRegion = model.checkingRegion }
        .task(
            id: RouteMapViewModel.RegionQuery(
                latitude: route.start.latitude, longitude: route.start.longitude, alignment: alignment)
        ) {
            await model.resolveRegion(
                .init(
                    latitude: route.start.latitude, longitude: route.start.longitude, alignment: alignment))
        }
        .onDisappear {
            model.cancelRegionLookup()
            checkingRegion = false
        }
    }
}
