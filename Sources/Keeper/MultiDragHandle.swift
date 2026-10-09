import SwiftUI
import AppKit

/// A drag handle that starts a real multi-file drag session, so many files can be dropped on Finder at once.
/// SwiftUI's own `.onDrag` carries a single file, which is why the row handle lives here too: a row drag
/// has to be able to take the clip's XML along with its video.
struct MultiDragHandle: NSViewRepresentable {
    enum Style { case bar, grip }

    let urls: [URL]
    var label: String = ""
    var style: Style = .bar

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.urls = urls
        view.label = label
        view.style = style
        view.setAccessibilityLabel(label.isEmpty ? "Drag files to Finder" : label)
        view.needsDisplay = true
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var label = ""
    var style: MultiDragHandle.Style = .bar

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .bar: drawBar()
        case .grip: drawGrip()
        }
    }

    private func drawBar() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(urls.isEmpty ? 0.08 : 0.2).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: max(4, (bounds.width - size.width) / 2),
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    /// Two columns of dots, the usual "grab me" affordance.
    private func drawGrip() {
        NSColor.tertiaryLabelColor.setFill()
        let dot: CGFloat = 2.5
        let gapX: CGFloat = 5
        let gapY: CGFloat = 5
        let cols = 2, rows = 3
        let blockW = CGFloat(cols - 1) * gapX + dot
        let blockH = CGFloat(rows - 1) * gapY + dot
        let originX = (bounds.width - blockW) / 2
        let originY = (bounds.height - blockH) / 2
        for c in 0..<cols {
            for r in 0..<rows {
                let rect = NSRect(x: originX + CGFloat(c) * gapX,
                                  y: originY + CGFloat(r) * gapY,
                                  width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    override func resetCursorRects() {
        if !urls.isEmpty { addCursorRect(bounds, cursor: .openHand) }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // Claimed so that mouseDragged reaches this view; the drag itself starts on the first drag event.
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 5)) * 4
            item.setDraggingFrame(NSRect(x: 8 + offset, y: 2 + offset, width: 28, height: 28), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
}
