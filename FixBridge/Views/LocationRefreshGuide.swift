import AppKit
import SwiftUI

struct LocationRefreshGuide: ViewModifier {
    let isActive: Bool
    @Binding var isPresented: Bool
    let openSettings: () async -> Void
    let refreshChanged: (Bool) -> Void
    let simulationMode: SimulationMode

    func body(content: Content) -> some View {
        content
            .background {
                LocationRefreshAlertPresenter(
                    isActive: isActive, isPresented: $isPresented, openSettings: openSettings,
                    refreshChanged: refreshChanged, simulationMode: simulationMode
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }
}

private struct LocationRefreshAlertPresenter: NSViewRepresentable {
    let isActive: Bool
    @Binding var isPresented: Bool
    let openSettings: () async -> Void
    let refreshChanged: (Bool) -> Void
    let simulationMode: SimulationMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowAnchor {
        let view = WindowAnchor()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
            coordinator?.synchronize()
        }
        return view
    }

    func updateNSView(_ view: WindowAnchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.window = view.window
        coordinator.isActive = isActive
        coordinator.presentation = $isPresented
        coordinator.openSettings = openSettings
        coordinator.refreshChanged = refreshChanged
        coordinator.simulationMode = simulationMode
        coordinator.synchronize()
    }

    static func dismantleNSView(_ view: WindowAnchor, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.cancel()
    }

    final class WindowAnchor: NSView {
        var windowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var isActive = false
        var simulationMode = SimulationMode.normal
        var presentation: Binding<Bool>?
        var openSettings: (() async -> Void)?
        var refreshChanged: ((Bool) -> Void)?
        private var refreshInProgress = false

        private func setRefreshInProgress(_ value: Bool) {
            guard refreshInProgress != value else { return }
            refreshInProgress = value
            refreshChanged?(value)
        }
        private var generation = 0
        private var guideTask: Task<Void, Never>?
        private var settingsTask: Task<Void, Never>?
        private var alert: NSAlert?
        private var countdownTask: Task<Void, Never>?
        private var guideLabel: NSTextField?
        private var countdownComplete = false

        func synchronize() {
            guard isActive, presentation?.wrappedValue == true, window != nil else {
                cancel()
                return
            }
            guard guideTask == nil else { return }
            setRefreshInProgress(true)
            settingsTask = Task { [openSettings] in await openSettings?() }
            let current = generation
            guideTask = Task { [weak self] in await self?.runGuide(generation: current) }
        }

        func cancel() {
            setRefreshInProgress(false)
            generation += 1
            guideTask?.cancel()
            guideTask = nil
            settingsTask?.cancel()
            settingsTask = nil
            countdownTask?.cancel()
            countdownTask = nil
            guideLabel = nil
            countdownComplete = false
            dismissAlert(returnCode: .cancel)
        }

        private func runGuide(generation current: Int) async {
            guard current == generation, !Task.isCancelled else { return }
            defer {
                if current == generation {
                    settingsTask?.cancel()
                    settingsTask = nil
                    countdownTask?.cancel()
                    countdownTask = nil
                    guideLabel = nil
                    countdownComplete = false
                    guideTask = nil
                    setRefreshInProgress(false)
                    presentation?.wrappedValue = false
                }
            }

            let guide = NSAlert()
            // The current instruction is the sole heading, updated in place across phases.
            guide.messageText = ""
            guide.informativeText = ""
            let primary = guide.addButton(withTitle: String(localized: "I Turned It Off"))
            let cancel = guide.addButton(withTitle: String(localized: "Close Guide"))
            cancel.keyEquivalent = "\u{1b}"

            // Keep the wider content area for readable instructions in every phase.
            let width: CGFloat = 260
            // Align accessory text with the native title and informative text.
            let textInset: CGFloat = 4
            let textWidth = width - 2 * textInset
            let instructions = [
                String(localized: "Turn off Location Services to refresh your iPhone’s location."),
                String(localized: "Keep Location Services off until the countdown ends."),
                String(localized: "Turn Location Services back on, then recenter Maps."),
            ]
            let label = NSTextField(wrappingLabelWithString: instructions[0])
            label.alignment = .left
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let instructionHeight =
                instructions.map { text in
                    label.stringValue = text
                    return ceil(
                        label.cell?.cellSize(
                            forBounds:
                                NSRect(x: 0, y: 0, width: textWidth, height: 1_000)
                        ).height ?? 0)
                }.max() ?? 0
            label.stringValue = instructions[0]

            let path = NSTextField(
                wrappingLabelWithString: String(
                    localized:
                        "Open the Settings app and tap\nPrivacy & Security → Location Services."))
            path.alignment = .left
            path.font = .systemFont(ofSize: NSFont.systemFontSize)
            let pathHeight = ceil(
                path.cell?.cellSize(
                    forBounds:
                        NSRect(x: 0, y: 0, width: textWidth, height: 1_000)
                ).height ?? 0)

            let restartHint = String(
                localized:
                    "If the location is still incorrect, stop FixBridge, restart your iPhone, then reconnect and retry."
            )
            let continuationHint = String(localized: "Closing this guide keeps location updates running.")
            let hintText =
                simulationMode == .dynamic
                ? String(localized: "Keep the network rules active and Bluetooth on.") + "\n\n"
                    + restartHint + "\n\n" + continuationHint
                : restartHint + "\n\n" + continuationHint
            let hint = NSTextField(wrappingLabelWithString: hintText)
            hint.alignment = .left
            hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            hint.textColor = .secondaryLabelColor
            let hintHeight = ceil(
                hint.cell?.cellSize(
                    forBounds:
                        NSRect(x: 0, y: 0, width: textWidth, height: 1_000)
                ).height ?? 0)
            hint.frame = NSRect(x: textInset, y: 0, width: textWidth, height: hintHeight)
            path.frame = NSRect(x: textInset, y: hintHeight + 12, width: textWidth, height: pathHeight)
            label.frame = NSRect(
                x: textInset, y: hintHeight + 12 + pathHeight + 16,
                width: textWidth, height: instructionHeight
            )

            let accessory = NSView(
                frame: NSRect(
                    x: 0, y: 0, width: width, height: instructionHeight + 16 + pathHeight + 12 + hintHeight
                ))
            accessory.addSubview(label)
            accessory.addSubview(path)
            accessory.addSubview(hint)
            guide.accessoryView = accessory
            guideLabel = label
            guide.layout()
            guide.window.minSize = guide.window.frame.size
            guide.window.maxSize = guide.window.frame.size
            primary.target = self
            primary.action = #selector(primaryPressed(_:))
            _ = await present(guide)
        }

        @objc private func primaryPressed(_ sender: NSButton) {
            if countdownComplete {
                dismissAlert(returnCode: .alertFirstButtonReturn)
                return
            }
            guard countdownTask == nil, let label = guideLabel, isActive else { return }
            label.stringValue = String(localized: "Keep Location Services off until the countdown ends.")
            sender.title = String(localized: "Wait \(10) s")
            sender.isEnabled = false
            countdownTask = Task {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !Task.isCancelled {
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    let seconds = max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
                    guard seconds > 0 else { break }
                    sender.title = String(localized: "Wait \(seconds) s")
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                label.stringValue = String(localized: "Turn Location Services back on, then recenter Maps.")
                countdownComplete = true
                sender.title = String(localized: "I Turned It Back On")
                sender.isEnabled = true
            }
        }

        private func dismissAlert(returnCode: NSApplication.ModalResponse) {
            if let alert, let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: returnCode)
                alert.window.orderOut(nil)
            }
        }

        private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
            guard let window, !Task.isCancelled else { return .cancel }
            self.alert = alert
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
            if self.alert === alert { self.alert = nil }
            return response
        }
    }
}
