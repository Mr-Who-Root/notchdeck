import AppKit
import SwiftUI

/// The panel's content view: it holds the hosting view and nothing else.
///
/// It exists so that SwiftUI is *not* the content view. As the content view an
/// `NSHostingView` reports the SwiftUI content's ideal size to the window, and
/// this notch's root is a `GeometryReader` whose ideal size is 10x10 — which on
/// a wide, shallow panel had AppKit walking the window down to zero height and
/// then throwing in the constraint pass. The panel's size is `NotchGeometry`'s
/// to decide, and a container is what makes that true.
///
/// It answers `hitTest` with whatever its subview says and never with itself.
/// A plain `NSView` would claim every point inside its bounds — and most of
/// this panel is empty space reserved for the tooltip, so that would turn the
/// hole the notch depends on into a wall.
final class NotchContainerView: NSView {
    /// Where a drag over the panel is reported — the vault's drop.
    weak var dropTarget: NotchDropTarget?

    /// Panel coordinates, top-left origin, the same as `interactiveRects`.
    private func panelPoint(_ info: NSDraggingInfo) -> CGPoint {
        let local = convert(info.draggingLocation, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragUpdated(sender, at: panelPoint(sender)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragUpdated(sender, at: panelPoint(sender)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.performDrop(sender, at: panelPoint(sender)) ?? false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinates, and a subview's own
        // `hitTest` expects it in ours.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

/// The panel is much larger than the notch — it reserves room for the tooltip —
/// so everything outside the currently visible chrome has to pass clicks
/// through to whatever is underneath.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Regions that should receive events, in view coordinates. NSHostingView
    /// is flipped, so these use a top-left origin.
    var interactiveRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    /// The same drop as the container's, for when AppKit asks this view — the
    /// deepest one under the drag that registered for it.
    weak var dropTarget: NotchDropTarget?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragUpdated(sender, at: convert(sender.draggingLocation, from: nil)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragUpdated(sender, at: convert(sender.draggingLocation, from: nil)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.performDrop(sender, at: convert(sender.draggingLocation, from: nil)) ?? false
    }

    /// `NSView.menu` is not inherited by subviews, and the hit test lands on one
    /// of SwiftUI's, so AppKit would otherwise ask a view that has no menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return menu
    }
}

/// **What the panel does with something dragged over it**: the vault takes
/// files, text, links and images. Points are in the panel, top-left origin.
@MainActor
protocol NotchDropTarget: AnyObject {
    func dragUpdated(_ info: NSDraggingInfo, at point: CGPoint) -> NSDragOperation
    func dragExited()
    func performDrop(_ info: NSDraggingInfo, at point: CGPoint) -> Bool
}
