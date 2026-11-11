import AppKit
import SwiftUI

struct SegmentedModeControl<Mode: Equatable>: NSViewRepresentable {
    let title: String
    let options: [(mode: Mode, label: String)]
    @Binding var selection: Mode
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> SegmentedModeAction {
        SegmentedModeAction()
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(SegmentedModeAction.selectMode(_:))
        )
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(title)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let selection = $selection
        let options = options
        context.coordinator.select = { index in
            guard options.indices.contains(index) else { return }
            selection.wrappedValue = options[index].mode
        }
        control.selectedSegment = options.firstIndex { $0.mode == selection.wrappedValue } ?? -1
        control.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let fittingSize = nsView.fittingSize
        return CGSize(width: proposal.width ?? fittingSize.width, height: fittingSize.height)
    }

}

@MainActor
final class SegmentedModeAction: NSObject {
    var select: ((Int) -> Void)?

    @objc func selectMode(_ sender: NSSegmentedControl) {
        select?(sender.selectedSegment)
    }
}
