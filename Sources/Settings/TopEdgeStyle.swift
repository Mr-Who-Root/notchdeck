/// **How the notch meets a Mac's own camera notch on the top edge.**
///
/// Only consulted on a display with a hardware notch, and only while the bar
/// sits at it; anywhere else along the top edge it is the ordinary bar.
enum TopEdgeStyle: String, CaseIterable, Identifiable {
    /// Grows down out of the hardware notch: the black shape spans the notch,
    /// and the rings and the deck's cells sit in a row beneath it. Folded, it
    /// is the hardware notch and nothing more.
    case dropDown
    /// Flows out to either side of the hardware notch at the menu bar's
    /// height, the readings in the strip beside it.
    case besideNotch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dropDown:    return L10n.t("Drop down from the notch")
        case .besideNotch: return L10n.t("Beside the notch")
        }
    }

    var explanation: String {
        switch self {
        case .dropDown:
            return L10n.t("Hover the Mac's notch and the deck grows down out of it, the rings in a row beneath it.")
        case .besideNotch:
            return L10n.t("The rings sit in the menu bar either side of the Mac's notch, shrunk to its height.")
        }
    }
}
