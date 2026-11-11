import AppKit
import SwiftUI

struct FixBridgeView: View {
    @StateObject private var model = FixBridgeViewModel()
    @StateObject private var location = TargetLocationViewModel()
    @StateObject private var routeModel = GPXRouteViewModel()
    @State private var credentialSelectionTask: Task<Void, Never>?
    @State private var certificateSelectionError: String?
    @State private var showingCertificateDetails = false
    @State private var showingLocationRefreshGuide = false
    @State private var hasShownLocationRefreshGuide = false
    private enum ConnectionGuide: Identifiable {
        case usb, bluetooth
        var id: Self { self }
    }

    @State private var connectionGuide: ConnectionGuide?
    private var choosingCredentials: Bool { credentialSelectionTask != nil }

    private var hasRoute: Bool {
        model.simulationMode == .dynamic && routeModel.route != nil
    }

    private var controlsRoute: Bool { model.running && hasRoute }

    private var primaryActionTitle: String {
        controlsRoute ? routeModel.actionTitle : String(localized: "Start")
    }

    private var primaryActionDisabled: Bool {
        if controlsRoute {
            return model.stopping || routeModel.importing || routeModel.playback.state == .finished
                || !(model.sending || routeModel.playback.state != .ready)
        }
        return !model.canStart || choosingCredentials || location.altitudeLookupStatus == .loading
            || routeModel.importing
    }

    private func performPrimaryAction() {
        // Recheck readiness for keyboard actions and rapid clicks as the session state changes.
        guard !primaryActionDisabled else { return }
        if controlsRoute {
            routeModel.togglePlayback()
        } else {
            guard hasRoute || location.validateForSubmission() else { return }
            model.start(routeModel: routeModel, makeFix: location.makeFix)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                mainContent
                    .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack {
                if model.running && model.authenticated && !model.stopping {
                    Button("Refresh iPhone Location…") {
                        showingLocationRefreshGuide = true
                    }
                }
                Spacer()
                Button("Stop") { model.stop(openSettings: true) }
                    .disabled(!model.running || model.stopping)
                Button(primaryActionTitle, action: performPrimaryAction)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryActionDisabled)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 480, idealHeight: 700)
        .modifier(
            LocationRefreshGuide(
                isActive: model.running && !model.stopping,
                isPresented: $showingLocationRefreshGuide,
                openSettings: model.openSettingsForRefresh,
                refreshChanged: model.setLocationRefreshInProgress,
                simulationMode: model.simulationMode
            )
        )
        .sheet(
            item: $connectionGuide,
            onDismiss: {
                Task { await model.refreshDevices() }
            }
        ) { guide in
            switch guide {
            case .usb: USBConnectionGuide()
            case .bluetooth: BluetoothPairingGuide()
            }
        }
        .onChange(of: model.authenticated) { _, authenticated in
            if authenticated, model.running, !model.stopping, !hasShownLocationRefreshGuide {
                hasShownLocationRefreshGuide = true
                showingLocationRefreshGuide = true
            }
        }
        .onChange(of: model.running) { _, running in
            if !running {
                showingLocationRefreshGuide = false
                hasShownLocationRefreshGuide = false
            }
        }
        .onAppear { model.openWindow() }
        .task { await model.monitorUSB() }
        .task(id: model.usbDeviceIDs) { await model.refreshUSBDeviceNames() }
        .task(id: model.mode) { await model.refreshBluetoothDevices() }
        .onChange(of: model.preflightRequest, initial: true) { model.schedulePreflight() }
        .onDisappear {
            credentialSelectionTask?.cancel()
            routeModel.detach()
            routeModel.cancelImport()
            location.cancelAltitudeLookup()
            model.closeWindow()
        }
        .alert(
            "Could Not Import Certificate",
            isPresented: Binding(
                get: { certificateSelectionError != nil },
                set: { if !$0 { certificateSelectionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(certificateSelectionError ?? "")
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                HStack(spacing: 13) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 37)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "FixBridge").font(.largeTitle.bold())
                        Text("Use your Mac as a GPS accessory to simulate a location on your iPhone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.95)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ConnectionControlsView(model: model, openGuide: openConnectionGuide)
                    .frame(width: 210)
            }
            .frame(minHeight: 96)

            GroupBox("MFi Credentials") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label {
                            Text(model.hasIdentity ? "Certificate and key imported" : "Certificate and key required")
                        } icon: {
                            Image(systemName: model.hasIdentity ? "checkmark.shield" : "key")
                                .foregroundStyle(model.hasIdentity ? Color.green : Color.red)
                        }
                        if model.hasIdentity {
                            Button {
                                showingCertificateDetails = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Certificate Details")
                            .popover(isPresented: $showingCertificateDetails) {
                                certificateDetails
                            }
                        }
                        Spacer()
                        Button(credentialButtonTitle) { importIdentity() }
                            .disabled(
                                model.running || model.stopping || choosingCredentials || model.importingCredentials)
                    }
                    if !model.hasIdentity {
                        Text(
                            "Select the certificate (`certificate.p7b`), then its matching private key (`identity.pk8`)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            TargetLocationView(
                model: location,
                simulationMode: Binding(get: { model.simulationMode }, set: model.selectSimulationMode),
                routeModel: routeModel,
                editingEnabled: !model.running && !model.stopping
            )

            GroupBox(model.running ? "Current Session" : "Session Status") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        indicator(
                            model.mode == .usb ? "USB" : "Bluetooth",
                            active: model.running ? model.transportConnected : model.preflight.linkVerified)
                        indicator("MFi Auth", active: model.running ? model.authenticated : model.preflight.passed)
                        indicator("Sending", active: model.running && !model.stopping && model.sending)
                        Spacer()
                        Text("Packets acknowledged \(model.delivered)")
                            .help("Acknowledgments confirm delivery, not the location used by iPhone.")
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    sessionStatus
                    if model.running || !model.sessionInterrupted || model.delivered > 0 {
                        Divider()
                        if controlsRoute { routeProgress }
                        if model.running {
                            sentLocationConsole
                        } else if !model.sessionInterrupted || model.delivered > 0 {
                            sessionTips
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private var routeProgress: some View {
        HStack(spacing: 12) {
            ProgressView(
                value: routeModel.playback.state == .finished
                    ? 1
                    : min(1, max(0, routeModel.playback.elapsed / (routeModel.route?.duration ?? 1)))
            )
            .progressViewStyle(.linear)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Route Progress")
            Text(routeModel.timeLabel)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var sentLocationConsole: some View {
        SentLocationConsole(entries: model.sentLocations)
            .frame(height: 112)
    }

    private func openConnectionGuide() {
        model.cancelPreflight()
        connectionGuide = model.mode == .usb ? .usb : .bluetooth
    }

    private var credentialButtonTitle: LocalizedStringKey {
        if model.importingCredentials { return "Importing Credentials…" }
        return model.hasIdentity ? "Replace Credentials…" : "Import Credentials…"
    }

    private var certificateDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            let validity = model.certificateValidity
            HStack(spacing: 8) {
                Text("Certificate Status").font(.headline)
                if let validity {
                    switch validity.status(at: .now) {
                    case .valid: Text("Within Validity Period").foregroundStyle(.green)
                    case .notYetValid: Text("Not Yet Valid").foregroundStyle(.orange)
                    case .expired: Text("Expired").foregroundStyle(.red)
                    }
                }
            }
            if let validity {
                LabeledContent("Valid From") {
                    Text(validity.startsAt, format: certificateDateFormat)
                }
                LabeledContent("Expires On") {
                    Text(validity.expiresAt, format: certificateDateFormat)
                }
            } else {
                Text("Certificate validity dates are unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(16)
    }

    private var certificateDateFormat: Date.FormatStyle {
        .dateTime.year().month().day().hour().minute().second().timeZone(.specificName(.short))
    }

    private func importIdentity() {
        guard !choosingCredentials, !model.running, !model.stopping, !model.importingCredentials else { return }
        credentialSelectionTask = Task {
            defer { credentialSelectionTask = nil }
            guard
                let certificateURL = chooseFile(
                    message: "Step 1 of 2. Select the MFi certificate (certificate.p7b).",
                    prompt: "Choose Certificate"
                )
            else { return }

            do {
                let certificate = try await model.readCertificate(certificateURL)
                try Task.checkCancellation()
                guard
                    let key = chooseFile(
                        message: "Step 2 of 2. Select the matching private key (identity.pk8).",
                        prompt: "Choose Private Key"
                    ), !Task.isCancelled
                else { return }
                model.importIdentity(certificate: certificate, key: key)
            } catch {
                if !Task.isCancelled { certificateSelectionError = error.localizedDescription }
            }
        }
    }

    private func chooseFile(message: String.LocalizationValue, prompt: String.LocalizationValue) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import MFi Credentials")
        panel.message = String(localized: message)
        panel.prompt = String(localized: prompt)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private var sessionStatus: some View {
        let display = model.statusDisplay(
            locationError: location.error, routePlayback: controlsRoute ? routeModel.playback : nil)
        let color: Color =
            switch display.kind {
            case .normal, .working: .primary
            case .success: .green
            case .error: .red
            }
        return HStack(alignment: .top, spacing: 6) {
            if display.kind == .working {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else if display.kind == .error {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityHidden(true)
            }
            Text(display.message)
                .lineLimit(display.kind == .error ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .truncationMode(.tail)
        }
        .font(.callout)
        .foregroundStyle(color)
        .help(display.message)
        .accessibilityElement(children: .combine)
    }

    private var sessionTips: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.sessionInterrupted || model.hasStartedSession {
                Text("After Stopping").bold()
                if model.delivered > 0 {
                    Text("If Maps still shows the test location, turn Location Services off and back on.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Quick Start").bold()
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Import the MFi-v3 certificate and matching private key.")
                    if model.mode == .usb {
                        Text("2. Connect your iPhone with a USB cable.")
                        Text("3. Select your iPhone in FixBridge. Unlock it and tap Trust if prompted.")
                    } else {
                        Text("2. Pair your iPhone in the Mac’s Bluetooth settings.")
                        Text("3. Select your iPhone in FixBridge and keep it unlocked nearby.")
                    }
                    Text("4. Enter coordinates and altitude, or choose a map point, saved location, or route.")
                    Text("5. After the checks pass, click Start and follow the refresh guide.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func indicator(_ text: LocalizedStringKey, active: Bool) -> some View {
        Label(text, systemImage: active ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(active ? Color.green : Color.secondary)
            .font(.callout)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// An independent native text viewport prevents tail-following from scrolling the outer SwiftUI page.
