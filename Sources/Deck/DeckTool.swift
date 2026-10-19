import AppKit
import SwiftUI

/// **The deck's own cells** — the tools NotchDeck carries beside the usage
/// rings: what is playing, what was copied, and a focus timer.
///
/// Each one rides the notch as a cell of its own, after the providers, so it
/// is placed, hovered, carried and folded by exactly the machinery the rings
/// use. The cell is a `ProviderSnapshot` of kind `.tool` whose id names the
/// tool; what the tool is doing lives in its own shared monitor
/// (`NowPlayingMonitor`, `ClipboardMonitor`, `FocusTimer`), which the cell and
/// its card observe directly. The snapshot therefore only changes when the set
/// of tools does, and the panel is resized only then.
enum DeckTool: String, CaseIterable, Codable, Identifiable, Equatable {
    case nowPlaying
    case clipboard
    case timer

    var id: String { rawValue }

    /// The tools switched on, in the order the notch draws them.
    static func enabled(nowPlaying: Bool, clipboard: Bool, timer: Bool) -> [DeckTool] {
        [nowPlaying ? .nowPlaying : nil, clipboard ? .clipboard : nil, timer ? .timer : nil]
            .compactMap { $0 }
    }

    static let cellPrefix = "deck."

    /// The cell's id among the snapshots. Namespaced so it can never collide
    /// with a provider's.
    var cellID: String { Self.cellPrefix + rawValue }

    init?(cellID: String) {
        guard cellID.hasPrefix(Self.cellPrefix) else { return nil }
        self.init(rawValue: String(cellID.dropFirst(Self.cellPrefix.count)))
    }

    var title: String {
        switch self {
        case .nowPlaying: return L10n.t("Now Playing")
        case .clipboard:  return L10n.t("Clipboard")
        case .timer:      return L10n.t("Focus Timer")
        }
    }

    /// The SF Symbol inside the cell's ring when it has nothing better to show.
    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .clipboard:  return "doc.on.clipboard"
        case .timer:      return "timer"
        }
    }

    /// The cell, as the notch's snapshot list carries it.
    var snapshot: ProviderSnapshot {
        ProviderSnapshot(id: cellID, displayName: title, glyph: .third,
                         fidelity: .official, status: .ok, windows: [], kind: .tool)
    }

    /// Fixed per tool, and worked out here rather than left to SwiftUI, for the
    /// same reason `NotchLayout.cardHeight` is: the hover region has to be known
    /// before the card is ever laid out, and the two must never disagree.
    var cardHeight: CGFloat {
        switch self {
        case .nowPlaying: return DeckLayout.nowPlayingHeight
        case .clipboard:  return DeckLayout.clipboardHeight
        case .timer:      return DeckLayout.timerHeight
        }
    }
}

extension ProviderSnapshot {
    /// The deck tool this cell is, when it is one.
    var deckTool: DeckTool? {
        kind == .tool ? DeckTool(cellID: id) : nil
    }
}

/// Measurements for the deck's cards, in the same design-frame units as
/// `NotchLayout`, so they scale with everything else.
enum DeckLayout {
    /// Album art, the same size as a ring.
    static let artworkSize = NotchLayout.ringDiameter
    static let artworkCorner = Design.px(22)
    /// A transport button's hit target; the middle one is drawn larger.
    static let controlHeight = Design.px(72)
    static let progressHeight = NotchLayout.barHeight

    /// How many clips the card lists; the rest are a right-click away.
    static let clipboardRows = 6
    static let clipboardRowHeight = NotchLayout.cardBodyLineHeight + Design.px(18)

    static let timerDigitsFont = NSFont.monospacedDigitSystemFont(
        ofSize: Design.fontSize(capPixels: 62), weight: .semibold)
    static let timerDigitsHeight: CGFloat = {
        let font = timerDigitsFont
        return ceil(font.ascender - font.descender + font.leading)
    }()
    static let chipHeight = Design.px(52)

    private static var padding: CGFloat { 2 * NotchLayout.cardPadding }
    private static var header: CGFloat { NotchLayout.cardTitleLineHeight + NotchLayout.headerToBlock }

    static var nowPlayingHeight: CGFloat {
        padding + artworkSize
            + NotchLayout.blockSpacing
            + progressHeight + NotchLayout.labelToBar + NotchLayout.cardBodyLineHeight
            + NotchLayout.blockSpacing
            + controlHeight
    }

    static var clipboardHeight: CGFloat {
        padding + header + CGFloat(clipboardRows) * clipboardRowHeight
    }

    static var timerHeight: CGFloat {
        padding + header
            + timerDigitsHeight
            + NotchLayout.labelToBar + progressHeight
            + NotchLayout.blockSpacing + chipHeight
            + NotchLayout.blockSpacing + controlHeight
    }

    /// Minutes and seconds, or hours too once there are any: "3:07", "1:02:45".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
