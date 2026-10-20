import AppKit
import SwiftUI
import XCTest
@testable import NotchDeck

/// The deck's cells ride the notch after the providers, are sized by their
/// own cards, and never pass themselves off as providers.
@MainActor
final class DeckToolCellTests: XCTestCase {
    private struct Screen: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var visibleFrameValue: CGRect { frameValue }
        var hardwareNotch: HardwareNotch?
        var displayIdentifier: String? { "deck-display" }
    }

    private func provider(_ id: String) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id, glyph: .claude, fidelity: .official, status: .ok, windows: [])
    }

    func testCellIDsRoundTripAndNeverLookLikeAProvider() {
        for tool in DeckTool.allCases {
            XCTAssertEqual(DeckTool(cellID: tool.cellID), tool)
            XCTAssertEqual(tool.snapshot.deckTool, tool)
            XCTAssertEqual(tool.snapshot.kind, .tool)
        }
        XCTAssertNil(DeckTool(cellID: "claude"))
        XCTAssertNil(DeckTool(cellID: "deck.unknown"))
        // A provider whose id happens to start the same way is still a provider.
        XCTAssertNil(provider("deck.clipboard").deckTool)
    }

    func testEnabledToolsKeepTheirOrder() {
        XCTAssertEqual(DeckTool.enabled(nowPlaying: true, clipboard: true, timer: true),
                       [.nowPlaying, .clipboard, .timer])
        XCTAssertEqual(DeckTool.enabled(nowPlaying: true, clipboard: true, timer: true,
                                        vault: true, meeting: true, transfers: true),
                       [.nowPlaying, .meeting, .clipboard, .vault, .timer, .transfers])
        XCTAssertEqual(DeckTool.enabled(nowPlaying: false, clipboard: false, timer: false, vault: true),
                       [.vault])
        XCTAssertEqual(DeckTool.enabled(nowPlaying: false, clipboard: true, timer: true), [.clipboard, .timer])
        XCTAssertEqual(DeckTool.enabled(nowPlaying: false, clipboard: false, timer: false), [])
    }

    func testToolsFollowTheProvidersAndSurviveNewReadings() {
        let model = NotchViewModel()
        model.updateSnapshots([provider("a"), provider("b")])
        model.deckTools = [.nowPlaying, .clipboard]
        XCTAssertEqual(model.snapshots.map(\.id), ["a", "b", "deck.nowPlaying", "deck.clipboard"])

        model.updateSnapshots([provider("a"), provider("b"), provider("c")])
        XCTAssertEqual(model.snapshots.map(\.id), ["a", "b", "c", "deck.nowPlaying", "deck.clipboard"])

        model.deckTools = [.clipboard]
        XCTAssertEqual(model.snapshots.map(\.id), ["a", "b", "c", "deck.clipboard"])
        model.deckTools = []
        XCTAssertEqual(model.snapshots.map(\.id), ["a", "b", "c"])
    }

    func testHoverStaysOnTheSameToolWhenTheProvidersChange() {
        let model = NotchViewModel()
        model.updateSnapshots([provider("a")])
        model.deckTools = [.timer]
        model.hoveredIndex = 1
        model.updateSnapshots([provider("a"), provider("b")])
        XCTAssertEqual(model.hoveredSnapshot?.deckTool, .timer)
    }

    func testThePanelHasRoomForTheTallestToolCard() {
        let model = NotchViewModel()
        model.adopt(screen: Screen())
        model.edge = .top
        model.deckTools = DeckTool.allCases
        let tallest = DeckTool.allCases.map(\.cardHeight).max() ?? 0
        XCTAssertGreaterThanOrEqual(model.maxCardHeight(cellCount: model.snapshots.count), tallest)
    }

    func testTheHoverRegionIsTheToolCardsOwnHeight() {
        let model = NotchViewModel()
        model.adopt(screen: Screen())
        model.edge = .top
        model.deckTools = [.clipboard]
        model.isExpanded = true
        let geometry = CursorGeometry(model: model, placement: model.placement)
        let rect = geometry.tooltipRect(index: 0)
        XCTAssertNotNil(rect)
        let depth = NotchLayout.tailGap + NotchLayout.tailLength + DeckTool.clipboard.cardHeight
        XCTAssertEqual(rect?.height ?? 0, depth, accuracy: 0.5)
    }

    func testASingleToolNeverReadsAcrossTheHardwareNotch() {
        let model = NotchViewModel()
        model.deckTools = [.timer]
        XCTAssertFalse(model.readsAcrossTheCutout)
    }

    func testClockCopy() {
        XCTAssertEqual(DeckLayout.clock(0), "0:00")
        XCTAssertEqual(DeckLayout.clock(65.9), "1:05")
        XCTAssertEqual(DeckLayout.clock(3 * 3600 + 62), "3:01:02")
        XCTAssertEqual(DeckLayout.clock(-4), "0:00")
    }
}

@MainActor
final class NowPlayingParsingTests: XCTestCase {
    func testAHelperReportBecomesATrack() throws {
        let report: [String: Any] = [
            "type": "state", "present": true, "title": "Song", "artist": "Band", "album": "Record",
            "duration": 200.0, "elapsed": 10.0, "rate": 1.0, "timestamp": 1_000.0, "playing": true,
            "bundleID": "com.apple.Music", "appName": "Music",
        ]
        let track = try XCTUnwrap(NowPlayingMonitor.track(from: report))
        XCTAssertEqual(track.title, "Song")
        XCTAssertEqual(track.subtitle, "Band — Record")
        XCTAssertTrue(track.isPlaying)
        // Carried forward from the report rather than asked for again.
        XCTAssertEqual(track.position(at: Date(timeIntervalSince1970: 1_030)), 40, accuracy: 0.001)
        XCTAssertEqual(track.progress(at: Date(timeIntervalSince1970: 1_030)) ?? 0, 0.2, accuracy: 0.001)
        // Never past the end.
        XCTAssertEqual(track.position(at: Date(timeIntervalSince1970: 9_999)), 200, accuracy: 0.001)
    }

    func testAPausedTrackStandsStill() throws {
        let report: [String: Any] = ["present": true, "title": "Episode", "elapsed": 61.0,
                                     "rate": 0.0, "timestamp": 1_000.0, "playing": false]
        let track = try XCTUnwrap(NowPlayingMonitor.track(from: report))
        XCTAssertEqual(track.position(at: Date(timeIntervalSince1970: 5_000)), 61, accuracy: 0.001)
        XCTAssertNil(track.progress(at: Date()), "no duration, no fraction")
    }

    func testNothingPlayingIsNoTrack() {
        XCTAssertNil(NowPlayingMonitor.track(from: ["present": false]))
        XCTAssertNil(NowPlayingMonitor.track(from: ["present": true, "title": ""]))
    }

    func testAnArtistWithoutATitleIsShownAsTheTitle() throws {
        let track = try XCTUnwrap(NowPlayingMonitor.track(from: ["present": true, "artist": "Radio"]))
        XCTAssertEqual(track.title, "Radio")
        XCTAssertNil(track.subtitle)
    }

    func testTheHelperScriptShips() {
        XCTAssertNotNil(Bundle(for: NotchViewModel.self).url(forResource: "notchdeck-nowplaying", withExtension: "js")
                        ?? Bundle.main.url(forResource: "notchdeck-nowplaying", withExtension: "js"))
    }
}

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("notchdeck-test-\(UUID().uuidString)"))
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchdeck-clipboard-\(UUID().uuidString).json")
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    private func monitor() -> ClipboardMonitor {
        ClipboardMonitor(pasteboard: pasteboard, storeURL: storeURL)
    }

    func testTextAndLinksAreTellApart() {
        pasteboard.clearContents()
        pasteboard.setString("  hello world \n", forType: .string)
        XCTAssertEqual(ClipboardMonitor.read(pasteboard)?.kind, .text)

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/a?b=c", forType: .string)
        XCTAssertEqual(ClipboardMonitor.read(pasteboard)?.kind, .link)

        pasteboard.clearContents()
        pasteboard.setString("see https://example.com", forType: .string)
        XCTAssertEqual(ClipboardMonitor.read(pasteboard)?.kind, .text)
    }

    func testBlankTextIsNotAClip() {
        pasteboard.clearContents()
        pasteboard.setString("   \n\t", forType: .string)
        XCTAssertNil(ClipboardMonitor.read(pasteboard))
    }

    func testConcealedContentIsNeverRecorded() {
        pasteboard.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: concealed)
        XCTAssertNil(ClipboardMonitor.read(pasteboard))
    }

    func testFilesAreRecordedAsFiles() throws {
        pasteboard.clearContents()
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        pasteboard.writeObjects(urls as [NSURL])
        let item = try XCTUnwrap(ClipboardMonitor.read(pasteboard))
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.fileURLs.map(\.path), ["/tmp/a.txt", "/tmp/b.png"])
        XCTAssertEqual(item.preview, "a.txt +1")
    }

    func testCopyingTheSameThingAgainMovesItUp() {
        let monitor = monitor()
        monitor.record(.init(kind: .text, text: "one", copiedAt: Date()))
        monitor.record(.init(kind: .text, text: "two", copiedAt: Date()))
        monitor.record(.init(kind: .text, text: "one", copiedAt: Date()))
        XCTAssertEqual(monitor.items.map(\.text), ["one", "two"])
    }

    func testPinnedClipsOutliveClearingAndTheLimit() {
        let monitor = monitor()
        monitor.record(.init(kind: .text, text: "keep", copiedAt: Date()))
        monitor.togglePin(monitor.items[0])
        monitor.limit = 2
        for n in 0..<5 { monitor.record(.init(kind: .text, text: "clip \(n)", copiedAt: Date())) }
        XCTAssertEqual(monitor.items.filter { !$0.pinned }.count, 2)
        XCTAssertEqual(monitor.ordered.first?.text, "keep", "pinned clips are listed first")
        monitor.clear()
        XCTAssertEqual(monitor.items.map(\.text), ["keep"])
    }

    func testPuttingAClipBackIsNotRecordedAsANewOne() {
        let monitor = monitor()
        monitor.record(.init(kind: .text, text: "old", copiedAt: Date()))
        monitor.record(.init(kind: .text, text: "new", copiedAt: Date()))
        monitor.copy(monitor.items[1])
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
        monitor.poll()
        XCTAssertEqual(monitor.items.map(\.text), ["old", "new"])
    }

    func testHistoryIsKeptAcrossLaunchesWithoutImages() throws {
        let first = monitor()
        first.record(.init(kind: .text, text: "remember me", copiedAt: Date()))
        first.record(.init(kind: .image, text: "", copiedAt: Date(), image: Data([1, 2, 3])))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: storeURL.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let second = monitor()
        XCTAssertEqual(second.items.map(\.text), ["remember me"])
        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testForgettingHistoryDeletesTheFile() {
        let monitor = monitor()
        monitor.record(.init(kind: .text, text: "x", copiedAt: Date()))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        monitor.remembersHistory = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }
}

/// A clip the row cannot show whole is shown in full while the pointer is on
/// it, on whichever side of the row has more room.
@MainActor
final class ClipPeekTests: XCTestCase {
    private func clip(_ text: String, kind: ClipboardMonitor.Item.Kind = .text) -> ClipboardMonitor.Item {
        .init(kind: kind, text: text, copiedAt: Date())
    }

    private func pointer(row: Int) -> CGPoint {
        CGPoint(x: 20, y: ClipPeekLayout.listTop + (CGFloat(row) + 0.5) * DeckLayout.clipboardRowHeight)
    }

    func testOnlyClipsTheRowCutsShortArePreviewed() {
        XCTAssertFalse(ClipPeekLayout.needsPeek(clip("short")))
        XCTAssertTrue(ClipPeekLayout.needsPeek(clip(String(repeating: "a long line of text ", count: 6))))
        XCTAssertTrue(ClipPeekLayout.needsPeek(clip("one\ntwo")))
        XCTAssertTrue(ClipPeekLayout.needsPeek(clip("/tmp/a\n/tmp/b", kind: .file)))
        XCTAssertFalse(ClipPeekLayout.needsPeek(clip("/tmp/a", kind: .file)))
        XCTAssertTrue(ClipPeekLayout.needsPeek(.init(kind: .image, text: "", copiedAt: Date(), image: Data())))
    }

    func testThePreviewOpensOnTheRoomierSideInsideTheCard() throws {
        let long = clip(String(repeating: "words that will not fit ", count: 8))
        let items = [long] + (1..<6).map { clip("clip \($0)") } + [long]
        let first = try XCTUnwrap(ClipPeekLayout(items: Array(items.prefix(6)), pointer: pointer(row: 0), copiedID: nil))
        XCTAssertGreaterThan(first.frame.minY, ClipPeekLayout.listTop + DeckLayout.clipboardRowHeight - 0.5,
                             "a top row's preview opens below it")
        XCTAssertLessThanOrEqual(first.frame.maxY, ClipPeekLayout.contentHeight + 0.5, "and stays inside the card")

        var bottom = Array(items.prefix(5))
        bottom.append(long)
        let last = try XCTUnwrap(ClipPeekLayout(items: bottom, pointer: pointer(row: 5), copiedID: nil))
        XCTAssertEqual(last.frame.minY, 0, "a bottom row's preview opens above it")
        XCTAssertLessThan(last.frame.maxY, ClipPeekLayout.listTop + 5 * DeckLayout.clipboardRowHeight)
    }

    func testNoPreviewForAShortClipTheTitleOrPastTheRows() {
        let items = [clip("short"), clip(String(repeating: "long ", count: 40))]
        XCTAssertNil(ClipPeekLayout(items: items, pointer: pointer(row: 0), copiedID: nil))
        XCTAssertNil(ClipPeekLayout(items: items, pointer: CGPoint(x: 20, y: 4), copiedID: nil))
        XCTAssertNil(ClipPeekLayout(items: items, pointer: pointer(row: 3), copiedID: nil))
        XCTAssertNil(ClipPeekLayout(items: items, pointer: CGPoint(x: -5, y: pointer(row: 1).y), copiedID: nil))
        XCTAssertNotNil(ClipPeekLayout(items: items, pointer: pointer(row: 1), copiedID: nil))
    }
}

@MainActor
final class FocusTimerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 10_000)

    private func timer() -> FocusTimer {
        // No stats store: the tests run inside the app, whose own defaults
        // hold the person's real focus history.
        FocusTimer(clock: { [unowned self] in self.now }, statsStore: nil)
    }

    func testRunsPausesAndResumes() {
        let timer = timer()
        timer.setMinutes(10, notify: false)
        XCTAssertEqual(timer.remaining(at: now), 600)
        timer.start()
        now += 120
        XCTAssertEqual(timer.remaining(at: now), 480, accuracy: 0.001)
        timer.pause()
        now += 1_000
        XCTAssertEqual(timer.remaining(at: now), 480, accuracy: 0.001)
        timer.start()
        now += 80
        XCTAssertEqual(timer.remaining(at: now), 400, accuracy: 0.001)
        XCTAssertEqual(timer.fractionRemaining(at: now), 400.0 / 600.0, accuracy: 0.001)
    }

    func testFinishingCallsBackOnceAndReturnsToIdle() {
        let timer = timer()
        timer.setMinutes(1, notify: false)
        var finished = 0
        timer.onFinish = { _, _ in finished += 1 }
        timer.start()
        now += 61
        timer.finishIfDue()
        timer.finishIfDue()
        XCTAssertEqual(finished, 1)
        XCTAssertTrue(timer.isIdle)
    }

    func testANewLengthStartsOverButTheSameOneDoesNot() {
        let timer = timer()
        timer.setMinutes(25, notify: false)
        timer.start()
        timer.setMinutes(25, notify: false)
        XCTAssertTrue(timer.isRunning)
        var reported: Int?
        timer.onDurationChange = { reported = $0 }
        timer.setMinutes(5)
        XCTAssertTrue(timer.isIdle)
        XCTAssertEqual(reported, 5)
        XCTAssertEqual(timer.remaining(at: now), 300)
    }

    func testLengthsAreClamped() {
        let timer = timer()
        timer.setMinutes(0, notify: false)
        XCTAssertEqual(timer.minutes, 1)
        timer.setMinutes(999, notify: false)
        XCTAssertEqual(timer.minutes, 180)
    }
}

/// The deck's cards drawn in the notch, beside their cells: a smoke test that
/// each one lays out and paints, and a way to look at them — set
/// `DECK_RENDER_PATH` to a directory and the frames are written there.
@MainActor
final class DeckRenderTests: XCTestCase {
    private struct Screen: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        var visibleFrameValue: CGRect { frameValue }
        var hardwareNotch: HardwareNotch?
        var displayIdentifier: String? { "deck-render" }
    }

    override func setUp() {
        super.setUp()
        DeckFixtures.apply()
    }

    override func tearDown() {
        NowPlayingMonitor.shared.showDemo(nil)
        ClipboardMonitor.shared.showDemo([])
        VaultStore.shared.showDemo([])
        SnippetStore.shared.showDemo([])
        MeetingMonitor.shared.showDemo(next: nil, later: [])
        TransferMonitor.shared.showDemo([])
        FocusTimer.shared.reset()
        super.tearDown()
    }

    func testEveryToolCardRendersBesideItsCell() throws {
        FocusTimer.shared.start()
        for edge in [NotchEdge.top, .right] {
            for (offset, tool) in DeckTool.allCases.enumerated() {
                let model = NotchViewModel()
                model.adopt(screen: Screen())
                model.edge = edge
                model.accentColor = .blue
                model.surfaceStyle = .solid
                model.updateSnapshots([ProviderSnapshot(
                    id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
                    windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.42)], headlineID: "w")])
                model.deckTools = DeckTool.allCases
                model.isExpanded = true
                model.hoveredIndex = 1 + offset
                XCTAssertEqual(model.hoveredSnapshot?.deckTool, tool)

                let renderer = ImageRenderer(content: NotchRootView(model: model)
                    .frame(width: model.panelSize.width, height: model.panelSize.height)
                    .background(Color(white: 0.35))
                    .environment(\.colorScheme, .dark)
                    .environment(\.notchdeckHeadlessGlass, true))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, "\(tool) on \(edge) did not render")
                let pixels = NSBitmapImageRep(cgImage: image)
                XCTAssertGreaterThan(pixels.pixelsWide, 0)

                if let directory = ProcessInfo.processInfo.environment["DECK_RENDER_PATH"] {
                    let png = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("deck-\(edge.rawValue)-\(tool.rawValue).png"))
                }
            }
        }
    }

    /// The website's picture: the notch open on the top edge with a card,
    /// on a transparent background to be laid over a wallpaper. Only with
    /// `DECK_HERO_PATH` set.
    func testHeroFrame() throws {
        guard let directory = ProcessInfo.processInfo.environment["DECK_HERO_PATH"] else {
            throw XCTSkip("DECK_HERO_PATH not set")
        }
        for tool in [DeckTool.vault, .meeting, .nowPlaying] {
            let model = NotchViewModel()
            model.adopt(screen: Screen())
            model.edge = .top
            model.accentColor = .blue
            model.surfaceStyle = .solid
            model.showsNotchReadings = true
            model.updateSnapshots([
                ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
                                 windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.42)], headlineID: "w"),
                ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
                                 windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.18)], headlineID: "w"),
            ])
            model.deckTools = [.nowPlaying, .meeting, .clipboard, .vault, .timer]
            model.isExpanded = true
            model.hoveredIndex = model.snapshots.firstIndex { $0.deckTool == tool }
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: model.panelSize.width, height: model.panelSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.notchdeckHeadlessGlass, true))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hero-\(tool.rawValue).png"))
        }
    }

    /// The pointer on the first clip — a link too long for its row — opens
    /// its preview: more of the card is painted than without it.
    func testAPointerOnALongClipDrawsItsPreview() throws {
        let model = NotchViewModel()
        model.adopt(screen: Screen())
        model.edge = .top
        model.surfaceStyle = .solid
        model.updateSnapshots([])
        model.deckTools = [.clipboard]
        model.isExpanded = true
        model.hoveredIndex = 0

        func render() throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: model.panelSize.width, height: model.panelSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.notchdeckHeadlessGlass, true))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        func lit(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
            var count = 0
            for x in stride(from: Int(rect.minX * 2), to: Int(rect.maxX * 2), by: 3) {
                for y in stride(from: Int(rect.minY * 2), to: Int(rect.maxY * 2), by: 3) {
                    if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5,
                       (c.redComponent + c.greenComponent + c.blueComponent) > 0.12 { count += 1 }
                }
            }
            return count
        }

        let card = try XCTUnwrap(CursorGeometry(model: model, placement: model.placement).tooltipRect(index: 0))
        let content = CGPoint(x: card.minX + NotchLayout.cardPadding,
                              y: card.minY + NotchLayout.tailGap + NotchLayout.tailLength + NotchLayout.cardPadding)
        let peek = try XCTUnwrap(ClipPeekLayout(
            items: Array(ClipboardMonitor.shared.ordered.prefix(DeckLayout.clipboardRows)),
            pointer: CGPoint(x: 30, y: ClipPeekLayout.listTop + DeckLayout.clipboardRowHeight / 2),
            copiedID: nil))
        let peekRect = peek.frame.offsetBy(dx: content.x, dy: content.y)

        let before = lit(try render(), in: peekRect)
        model.deckPointer.update(CGPoint(x: content.x + 30,
                                         y: content.y + ClipPeekLayout.listTop + DeckLayout.clipboardRowHeight / 2))
        let shown = try render()
        XCTAssertGreaterThan(lit(shown, in: peekRect), before, "the preview did not appear over the rows")

        if let directory = ProcessInfo.processInfo.environment["DECK_RENDER_PATH"] {
            let png = try XCTUnwrap(shown.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("deck-top-clipboard-peek.png"))
        }
    }
}

/// The real helper, run from the app's own process — opt-in, since it reads
/// whatever this Mac is playing: `NOTCHDECK_LIVE_NOW_PLAYING=1`.
@MainActor
final class NowPlayingLiveTests: XCTestCase {
    func testTheHelperReportsFromInsideTheApp() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOTCHDECK_LIVE_NOW_PLAYING"] == "1",
                          "reads the Mac's real now-playing state")
        let monitor = NowPlayingMonitor.shared
        monitor.start()
        defer { monitor.stop() }
        let deadline = Date().addingTimeInterval(8)
        while monitor.track == nil, monitor.isAvailable, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(monitor.isAvailable, "MediaRemote could not be reached through osascript")
        print("LIVE now playing:", monitor.track.map { "\($0.title) — \($0.appName ?? "?") playing=\($0.isPlaying)" } ?? "nothing")
    }
}
