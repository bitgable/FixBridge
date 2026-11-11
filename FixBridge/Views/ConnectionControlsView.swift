import SwiftUI

struct ConnectionControlsView: View {
    @ObservedObject var model: FixBridgeViewModel
    let openGuide: () -> Void

    private var guideTitle: LocalizedStringKey {
        model.mode == .usb ? "USB Connection Guide" : "Bluetooth Pairing Guide"
    }

    private var menuGuideTitle: LocalizedStringKey {
        model.mode == .usb ? "USB Connection Guide…" : "Bluetooth Pairing Guide…"
    }

    var body: some View {
        GroupBox("iPhone Connection") {
            VStack(alignment: .leading, spacing: 8) {
                SegmentedModeControl(
                    title: String(localized: "Transport"),
                    options: [(.usb, "USB"), (.bluetooth, String(localized: "Bluetooth"))],
                    selection: $model.mode
                )
                .frame(maxWidth: .infinity)

                HStack {
                    if model.deviceChoices.isEmpty {
                        Button(action: openGuide) {
                            Label(guideTitle, systemImage: "questionmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .help(Text(guideTitle))
                    } else {
                        Menu {
                            ForEach(model.deviceChoices) { device in
                                Button {
                                    model.selectedDeviceID = device.id
                                } label: {
                                    if model.selectedDeviceID == device.id {
                                        Label(device.title, systemImage: "checkmark")
                                    } else {
                                        Text(device.title)
                                    }
                                }
                            }
                            Divider()
                            Button(menuGuideTitle, action: openGuide)
                        } label: {
                            Text(model.selectedDeviceTitle)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("iPhone")

                        Button {
                            Task { await model.refreshDevices() }
                        } label: {
                            Label("Refresh Devices", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .help("Refresh Devices")
                        .disabled(model.preflight.isChecking || model.loadingDevices)
                    }
                }
                .frame(height: 24)
            }
            .padding(6)
            .disabled(model.running || model.stopping)
        }
    }
}
