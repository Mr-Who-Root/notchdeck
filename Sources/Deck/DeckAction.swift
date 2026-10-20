import AppKit
import SwiftUI

/// **What a deck card asks of the notch** that a SwiftUI view cannot do by
/// itself: a share sheet or a menu anchored to a button, or the keyboard for a
/// search field. The notch's window controller owns the panel those need.
enum DeckAction {
    /// The share sheet — AirDrop, Messages, Mail — for these files.
    case share([URL])
    /// The list of sound outputs to switch to.
    case outputDevices
    /// A search field was clicked: the panel takes the keyboard.
    case beginTyping
    /// Done typing: the keyboard goes back to the app that had it.
    case endTyping
}

private struct DeckActionKey: EnvironmentKey {
    static let defaultValue: (DeckAction, CGRect) -> Void = { _, _ in }
}

extension EnvironmentValues {
    /// Asks the notch for something — see `DeckAction`. The rect is the
    /// control's frame in the panel, top-left origin, to anchor a sheet or
    /// menu to.
    var deckAction: (DeckAction, CGRect) -> Void {
        get { self[DeckActionKey.self] }
        set { self[DeckActionKey.self] = newValue }
    }
}

/// Keeps a view's frame in the panel's coordinates, for anchoring.
struct PanelFrameReader: ViewModifier {
    @Binding var frame: CGRect

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .named(DeckPointer.space)) }
                    .onChange(of: proxy.frame(in: .named(DeckPointer.space))) { _, new in frame = new }
            }
        }
    }
}

extension View {
    func panelFrame(_ frame: Binding<CGRect>) -> some View {
        modifier(PanelFrameReader(frame: frame))
    }
}

/// **A drag handle for files**: press and drag to carry them out of the notch,
/// click for `onClick`, double-click for `onDoubleClick`. AppKit underneath,
/// because a SwiftUI drag carries one item and cannot be told to copy rather
/// than move.
struct FileDragArea: NSViewRepresentable {
    let ids: () -> [UUID]
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var toolTip: String?

    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.ids = ids
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.toolTip = toolTip
    }
}

final class FileDragView: NSView {
    var ids: () -> [UUID] = { [] }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pressed: NSEvent?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !dragged else { return }
        let start = pressed.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        dragged = true
        MainActor.assumeIsolated {
            VaultDragSource.shared.begin(ids: ids(), from: self, event: pressed)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard !dragged else { return }
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
