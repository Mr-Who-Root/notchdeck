import AppKit

/// **The deck on the notch's right-click menu**: the whole clipboard history
/// (the card has room for the latest few), the transport for what is playing,
/// and the timer.
@MainActor
enum DeckMenu {
    /// How many clips the submenu lists.
    static let clipLimit = 30

    static func items(for tools: [DeckTool]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if tools.contains(.nowPlaying), let track = NowPlayingMonitor.shared.track {
            items.append(nowPlayingItem(track))
        }
        if tools.contains(.clipboard) {
            items.append(clipboardItem())
        }
        if tools.contains(.timer) {
            let timer = FocusTimer.shared
            let title: String
            switch timer.state {
            case .idle: title = L10n.t("Start Focus Timer (\(timer.minutes) min)")
            case .running: title = L10n.t("Pause Focus Timer")
            case .paused: title = L10n.t("Resume Focus Timer")
            }
            items.append(item(title, #selector(DeckMenuTarget.toggleTimer(_:))))
        }
        return items
    }

    private static func nowPlayingItem(_ track: NowPlayingMonitor.Track) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("Now Playing"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: [track.title, track.artist].compactMap { $0 }.joined(separator: " — "),
                                 action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let toggle = item(track.isPlaying ? L10n.t("Pause") : L10n.t("Play"),
                          #selector(DeckMenuTarget.media(_:)))
        toggle.representedObject = NowPlayingMonitor.Command.toggle.rawValue
        let next = item(L10n.t("Next"), #selector(DeckMenuTarget.media(_:)))
        next.representedObject = NowPlayingMonitor.Command.next.rawValue
        let previous = item(L10n.t("Previous"), #selector(DeckMenuTarget.media(_:)))
        previous.representedObject = NowPlayingMonitor.Command.previous.rawValue
        for entry in [toggle, next, previous] {
            entry.isEnabled = NowPlayingMonitor.shared.canSendCommands
            menu.addItem(entry)
        }
        parent.submenu = menu
        parent.isEnabled = true
        return parent
    }

    private static func clipboardItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("Clipboard History"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let clips = ClipboardMonitor.shared.ordered.prefix(clipLimit)
        if clips.isEmpty {
            let empty = NSMenuItem(title: L10n.t("Nothing copied yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for clip in clips {
            let entry = item(title(for: clip), #selector(DeckMenuTarget.copyClip(_:)))
            entry.representedObject = clip.id
            entry.image = NSImage(systemSymbolName: clip.pinned ? "pin.fill" : clip.symbol,
                                  accessibilityDescription: nil)
            entry.toolTip = clip.kind == .image ? nil : String(clip.text.prefix(300))
            menu.addItem(entry)
        }
        if ClipboardMonitor.shared.items.contains(where: { !$0.pinned }) {
            menu.addItem(.separator())
            menu.addItem(item(L10n.t("Clear History"), #selector(DeckMenuTarget.clearClips(_:))))
        }
        parent.submenu = menu
        parent.isEnabled = true
        return parent
    }

    /// One line, at most 60 characters.
    static func title(for clip: ClipboardMonitor.Item) -> String {
        let line = clip.preview
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = DeckMenuTarget.shared
        item.isEnabled = true
        return item
    }
}

/// The Objective-C target the deck's menu items need.
@MainActor
final class DeckMenuTarget: NSObject {
    static let shared = DeckMenuTarget()

    @objc func copyClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let clip = ClipboardMonitor.shared.items.first(where: { $0.id == id }) else { return }
        ClipboardMonitor.shared.copy(clip)
    }

    @objc func clearClips(_ sender: NSMenuItem) {
        ClipboardMonitor.shared.clear()
    }

    @objc func media(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = NowPlayingMonitor.Command(rawValue: raw) else { return }
        NowPlayingMonitor.shared.send(command)
    }

    @objc func toggleTimer(_ sender: NSMenuItem) {
        FocusTimer.shared.toggle()
    }
}
