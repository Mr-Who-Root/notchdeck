import AppKit

/// NotchDeck's own mark, for the places the app draws itself — the Settings
/// sidebar and About header, the update card, What's New.
///
/// Read from the asset catalog rather than `NSApp.applicationIconImage`: that
/// one comes through the system's icon cache, which can go on serving a
/// bundle's previous icon at the same path long after it changed.
enum AppMark {
    static var image: NSImage {
        NSImage(named: "AppMark") ?? NSApp.applicationIconImage
    }
}
