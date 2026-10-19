import AppKit

/// What `NOTCHDECK_DEMO=1` shows in the deck's cells, beside `Fixtures`' rings —
/// and what the render tests draw. Nothing here is saved or sent anywhere.
@MainActor
enum DeckFixtures {
    static func apply(now: Date = Date()) {
        NowPlayingMonitor.shared.showDemo(NowPlayingMonitor.Track(
            title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
            duration: 243, elapsed: 83, timestamp: now, rate: 1, isPlaying: true,
            bundleID: "com.apple.Music", appName: "Music"))
        ClipboardMonitor.shared.showDemo([
            .init(kind: .link, text: "https://github.com/sparkle-project/Sparkle",
                  copiedAt: now.addingTimeInterval(-3_600), pinned: true),
            .init(kind: .text, text: "xcodebuild -scheme NotchDeck test", copiedAt: now.addingTimeInterval(-20)),
            .init(kind: .text, text: "func greet(_ name: String) {\n    print(\"Hello, \\(name)!\")\n}\n\ngreet(\"NotchDeck\")",
                  copiedAt: now.addingTimeInterval(-240)),
            .init(kind: .file, text: "/Users/demo/Desktop/report.pdf\n/Users/demo/Desktop/chart.png",
                  copiedAt: now.addingTimeInterval(-7_200)),
            .init(kind: .text, text: "SELECT * FROM sessions WHERE state = 'busy';",
                  copiedAt: now.addingTimeInterval(-86_400 * 2)),
        ])
    }
}
