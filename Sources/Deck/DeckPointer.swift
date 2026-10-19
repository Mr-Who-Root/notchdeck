import Combine
import CoreGraphics

/// **Where the pointer is over a deck card**, in the panel's own coordinates.
///
/// The notch's hover is worked out by its window controller rather than by
/// SwiftUI — the panel ignores the mouse until the pointer reaches it, so
/// SwiftUI never sees the crossing — and a card that reacts to which of its
/// rows is under the pointer has to be told the same way. One per notch, and
/// published on its own rather than through the view model, so the pointer
/// moving re-renders that one card rather than the whole notch.
@MainActor
final class DeckPointer: ObservableObject {
    /// The coordinate space `location` is measured in: the panel, top-left origin.
    static let space = "notchPanel"

    @Published private(set) var location: CGPoint?

    func update(_ location: CGPoint?) {
        if location != self.location { self.location = location }
    }
}
