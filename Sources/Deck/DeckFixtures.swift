import AppKit
import CoreAudio

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
        SnippetStore.shared.showDemo([
            .init(title: "Sign-off", text: "Thanks,\nAlex"),
            .init(title: "", text: "ssh demo@build.local"),
        ])
        VaultStore.shared.showDemo([
            .init(name: "Quarterly report.pdf", path: "/Users/demo/Desktop/Quarterly report.pdf", bookmark: nil,
                  owned: false, addedAt: now.addingTimeInterval(-600), isDirectory: false, size: 2_480_000),
            .init(name: "Screenshot 2026-10-20 at 10.41.png", path: "/Users/demo/Vault/Screenshot.png", bookmark: nil,
                  owned: true, addedAt: now.addingTimeInterval(-300), isDirectory: false, size: 812_000),
            .init(name: "Design assets", path: "/Users/demo/Projects/Design assets", bookmark: nil,
                  owned: false, addedAt: now.addingTimeInterval(-60), isDirectory: true, size: nil),
        ])
        MeetingMonitor.shared.showDemo(
            next: .init(id: "demo-1", title: "Design review", start: now.addingTimeInterval(12 * 60),
                        end: now.addingTimeInterval(42 * 60), calendar: "Work", color: .systemBlue,
                        location: "Room 4", joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
                        eventIdentifier: nil),
            later: [
                .init(id: "demo-2", title: "Lunch with Sam", start: now.addingTimeInterval(3 * 3600),
                      end: now.addingTimeInterval(4 * 3600), calendar: "Personal", color: .systemGreen,
                      location: nil, joinURL: nil, eventIdentifier: nil),
            ])
        var week = FocusStats()
        for (back, sessions) in [(6, 2), (5, 4), (4, 1), (3, 0), (2, 3), (1, 5), (0, 3)] {
            let day = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
            for _ in 0..<sessions { week.record(minutes: 25, on: day) }
        }
        FocusTimer.shared.showDemoStats(week)
        TransferMonitor.shared.showDemo([
            .init(id: ObjectIdentifier(DemoTransfer.first), name: "Xcode_26.1.xip",
                  finalURL: URL(fileURLWithPath: "/Users/demo/Downloads/Xcode_26.1.xip"), fraction: 0.62,
                  completedBytes: 2_100_000_000, totalBytes: 3_400_000_000, bytesPerSecond: 18_000_000, isAirDrop: false),
            .init(id: ObjectIdentifier(DemoTransfer.second), name: "IMG_2041.HEIC",
                  finalURL: URL(fileURLWithPath: "/Users/demo/Downloads/IMG_2041.HEIC"), fraction: nil,
                  completedBytes: 1_200_000, totalBytes: nil, bytesPerSecond: nil, isAirDrop: true),
        ])
        AudioOutput.shared.showDemo(devices: [
            .init(id: 1, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
            .init(id: 2, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        ], current: 2, volume: 0.6)
    }
}

/// Something for the demo transfers' identities to be the identity of.
private final class DemoTransfer {
    static let first = DemoTransfer()
    static let second = DemoTransfer()
}
