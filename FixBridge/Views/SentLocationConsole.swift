import SwiftUI

struct SentLocationConsole: NSViewRepresentable {
    let entries: [FixBridgeViewModel.SentLocation]

    final class Coordinator {
        var initialized = false
        var lastID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 112))
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 0, height: 6)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        text.setAccessibilityLabel(String(localized: "Sent Location Updates"))
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView,
            !context.coordinator.initialized || context.coordinator.lastID != entries.last?.id
        else { return }
        let followsTail =
            !context.coordinator.initialized
            || scroll.documentVisibleRect.maxY >= text.bounds.height - 4
        let content =
            entries.isEmpty
            ? String(localized: "No location updates sent yet.") : entries.map(\.line).joined(separator: "\n")
        text.textStorage?.setAttributedString(
            NSAttributedString(
                string: content,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .foregroundColor: entries.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
                ]))
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            text.setFrameSize(
                NSSize(
                    width: max(scroll.contentSize.width, ceil(used.maxX)),
                    height: max(scroll.contentSize.height, ceil(used.maxY) + 12)))
        }
        if followsTail {
            let target = NSPoint(x: 0, y: max(0, text.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        context.coordinator.initialized = true
        context.coordinator.lastID = entries.last?.id
    }
}
