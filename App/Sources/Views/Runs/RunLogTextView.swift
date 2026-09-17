import AppKit
import SwiftUI

/// Native selection across the entire log, with layout on demand rather
/// than one eagerly measured SwiftUI Text spanning every line.
struct RunLogTextView: NSViewRepresentable {
    let text: String
    let isPlaceholder: Bool
    let followTail: Bool

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView()
    }

    func makeScrollView() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("Run log")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(scroll, coordinator: context.coordinator)
    }

    func update(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let changed = view.string != text
        if changed {
            // Preserve selection and existing layout when live output appends.
            // A trim, placeholder transition, or different file replaces it.
            let old = view.string
            if !old.isEmpty, text.hasPrefix(old), let storage = view.textStorage {
                let suffix = String(text.dropFirst(old.count))
                storage.append(NSAttributedString(string: suffix, attributes: [
                    .font: view.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ]))
            } else {
                view.string = text
            }
        }
        view.textColor = isPlaceholder ? .secondaryLabelColor : .textColor
        if followTail && (changed || !coordinator.wasFollowing) {
            view.scrollRangeToVisible(NSRange(location: (view.string as NSString).length, length: 0))
        }
        coordinator.wasFollowing = followTail
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var wasFollowing = false
    }
}
