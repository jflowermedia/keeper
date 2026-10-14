import SwiftUI
import AppKit

/// The grip dots at the left of a clip row, which drag that clip to Finder.
///
/// It exists because SwiftUI's own `.onDrag` carries a single file, and a clip is two — the
/// video and its sidecar — which have to arrive together.
struct MultiDragHandle: NSViewRepresentable {
    enum Style { case grip }

    let urls: [URL]
    var label: String = ""
    var style: Style = .grip

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
    var style: MultiDragHandle.Style = .grip

    override func draw(_ dirtyRect: NSRect) {
        drawGrip()
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
