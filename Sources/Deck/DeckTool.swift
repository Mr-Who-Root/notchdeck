import AppKit
import SwiftUI

/// **The deck's own cells** — the tools NotchDeck carries beside the usage
/// rings: what is playing, the next meeting, what was copied, the files held
/// in the vault, a focus timer, and — only while something is downloading —
/// the downloads.
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
    case meeting
    case clipboard
    case vault
    case timer
    /// Shown only while a download or AirDrop is under way — see `TransferMonitor`.
    case transfers

    var id: String { rawValue }

    /// The tools switched on, in the order the notch draws them.
    static func enabled(nowPlaying: Bool, clipboard: Bool, timer: Bool,
                        vault: Bool = false, meeting: Bool = false, transfers: Bool = false) -> [DeckTool] {
        let switches: [DeckTool: Bool] = [.nowPlaying: nowPlaying, .meeting: meeting, .clipboard: clipboard,
                                          .vault: vault, .timer: timer, .transfers: transfers]
        return allCases.filter { switches[$0] == true }
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
        case .meeting:    return L10n.t("Next Meeting")
        case .clipboard:  return L10n.t("Clipboard")
        case .vault:      return L10n.t("Vault")
        case .timer:      return L10n.t("Focus Timer")
        case .transfers:  return L10n.t("Downloads")
        }
    }

    /// The SF Symbol inside the cell's ring when it has nothing better to show.
    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .meeting:    return "calendar"
        case .clipboard:  return "doc.on.clipboard"
        case .vault:      return "tray"
        case .timer:      return "timer"
        case .transfers:  return "arrow.down"
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
        case .meeting:    return DeckLayout.meetingHeight
        case .clipboard:  return DeckLayout.clipboardHeight
        case .vault:      return DeckLayout.vaultHeight
        case .timer:      return DeckLayout.timerHeight
        case .transfers:  return DeckLayout.transfersHeight
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

    /// How many clips the card lists; the rest are a right-click away, or a
    /// search away.
    static let clipboardRows = 6
    static let clipboardRowHeight = NotchLayout.cardBodyLineHeight + Design.px(18)
    /// The search field and the Recent/Snippets switch under the title.
    static let searchHeight = Design.px(50)
    static let searchToList = Design.px(12)

    /// The volume row under the transport controls.
    static let volumeRowHeight = Design.px(52)

    /// How many files the vault card lists before it scrolls.
    static let vaultRows = 5
    static let vaultRowHeight = NotchLayout.cardBodyLineHeight + Design.px(22)

    /// How many downloads the card lists at once.
    static let transferRows = 3
    static var transferRowHeight: CGFloat {
        NotchLayout.cardBodyLineHeight + NotchLayout.labelToBar + progressHeight + Design.px(14)
    }

    /// The seven days of focus under the timer: a line of text and a row of bars.
    static let focusBarsHeight = Design.px(40)

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
            + volumeRowHeight
    }

    /// Where the clipboard's rows start, under the title, the search field
    /// and the gap after it.
    static var clipboardListTop: CGFloat { header + searchHeight + searchToList }

    static var clipboardHeight: CGFloat {
        padding + clipboardListTop + CGFloat(clipboardRows) * clipboardRowHeight
    }

    static var timerHeight: CGFloat {
        padding + header
            + timerDigitsHeight
            + NotchLayout.labelToBar + progressHeight
            + NotchLayout.blockSpacing + chipHeight
            + NotchLayout.blockSpacing + controlHeight
            + NotchLayout.blockSpacing + NotchLayout.cardBodyLineHeight + Design.px(8) + focusBarsHeight
    }

    static var vaultHeight: CGFloat {
        padding + header + CGFloat(vaultRows) * vaultRowHeight
            + NotchLayout.blockSpacing + chipHeight
    }

    static var meetingHeight: CGFloat {
        padding + header
            + NotchLayout.cardTitleLineHeight + 2 * NotchLayout.cardBodyLineHeight
            + NotchLayout.blockSpacing + chipHeight
            + NotchLayout.blockSpacing + 3 * NotchLayout.cardBodyLineHeight
    }

    static var transfersHeight: CGFloat {
        padding + header + CGFloat(transferRows) * transferRowHeight
    }

    /// Minutes and seconds, or hours too once there are any: "3:07", "1:02:45".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
