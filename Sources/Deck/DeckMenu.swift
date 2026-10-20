import AppKit
import CoreAudio

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
        if tools.contains(.meeting), let next = MeetingMonitor.shared.next {
            let title = next.joinURL != nil ? L10n.t("Join “\(next.title)”") : L10n.t("Show “\(next.title)” in Calendar")
            items.append(item(title, #selector(DeckMenuTarget.joinMeeting(_:))))
        }
        if tools.contains(.clipboard) {
            items.append(clipboardItem())
        }
        if tools.contains(.vault) {
            items.append(vaultItem())
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

    private static func vaultItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("Vault"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let vault = VaultStore.shared
        if vault.items.isEmpty {
            let empty = NSMenuItem(title: L10n.t("Drag files onto the notch to hold them"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for file in vault.items.prefix(clipLimit) {
            let entry = item(file.name, #selector(DeckMenuTarget.revealVaultItem(_:)))
            entry.representedObject = file.id
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            entry.isEnabled = !vault.missing.contains(file.id)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("Open Vault Folder"), #selector(DeckMenuTarget.openVaultFolder(_:))))
        if !vault.items.isEmpty {
            menu.addItem(item(L10n.t("Empty Vault"), #selector(DeckMenuTarget.emptyVault(_:))))
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

    @objc func joinMeeting(_ sender: NSMenuItem) {
        guard let next = MeetingMonitor.shared.next else { return }
        if next.joinURL != nil { MeetingMonitor.shared.join(next) } else { MeetingMonitor.shared.openCalendar(next) }
    }

    @objc func revealVaultItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let file = VaultStore.shared.items.first(where: { $0.id == id }) else { return }
        VaultStore.shared.reveal(file)
    }

    @objc func openVaultFolder(_ sender: NSMenuItem) {
        VaultStore.shared.openFolder()
    }

    @objc func emptyVault(_ sender: NSMenuItem) {
        VaultStore.shared.clear()
    }

    @objc func selectOutput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID,
              let device = AudioOutput.shared.devices.first(where: { $0.id == id }) else { return }
        AudioOutput.shared.select(device)
    }

    @objc func openSoundSettings(_ sender: NSMenuItem) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
