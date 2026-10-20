import AppKit
import IOKit.ps
import SwiftUI
import XCTest
@testable import NotchDeck

// MARK: - Vault

@MainActor
final class VaultStoreTests: XCTestCase {
    private var root: URL!
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(storeURL: URL? = nil) -> VaultStore {
        VaultStore(folder: root.appendingPathComponent("Vault"), storeURL: storeURL,
                   clock: { [unowned self] in self.now })
    }

    /// A file outside every temporary location, as a user's own would be —
    /// the test's temporary directory is exactly the kind of place the vault
    /// copies from, so files meant to be pointed at live under ~/Library.
    private func userFile(_ name: String, contents: String = "hello") throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAFileOfYourOwnIsPointedAtNotCopied() throws {
        let vault = store()
        let file = try userFile("report.txt")
        XCTAssertEqual(vault.add(urls: [file]), 1)
        let item = try XCTUnwrap(vault.items.first)
        XCTAssertFalse(item.owned)
        XCTAssertNotNil(item.bookmark)
        XCTAssertEqual(item.path, file.resolvingSymlinksInPath().path)
        XCTAssertEqual(item.size, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Vault/report.txt").path))
    }

    func testATemporaryFileIsCopiedIn() throws {
        let vault = store()
        let temp = root.appendingPathComponent("attachment.pdf")
        try "pdf".write(to: temp, atomically: true, encoding: .utf8)
        vault.add(urls: [temp])
        let item = try XCTUnwrap(vault.items.first)
        XCTAssertTrue(item.owned)
        XCTAssertTrue(item.path.hasPrefix(root.appendingPathComponent("Vault").resolvingSymlinksInPath().path)
                      || item.path.hasPrefix(root.appendingPathComponent("Vault").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testKeepingCopiesCopiesEverything() throws {
        let vault = store()
        vault.keepsCopies = true
        vault.add(urls: [try userFile("notes.md")])
        XCTAssertEqual(vault.items.first?.owned, true)
    }

    func testTheSameFileTwiceIsHeldOnceAndMovesToTheTop() throws {
        let vault = store()
        let a = try userFile("a.txt"), b = try userFile("b.txt")
        vault.add(urls: [a])
        vault.add(urls: [b])
        XCTAssertEqual(vault.add(urls: [a]), 0)
        XCTAssertEqual(vault.items.map(\.name), ["a.txt", "b.txt"])
    }

    func testRemovingDeletesOnlyTheVaultsOwnCopy() throws {
        let vault = store()
        let mine = try userFile("mine.txt")
        vault.add(urls: [mine])
        vault.add(text: "a note")
        let owned = try XCTUnwrap(vault.items.first { $0.owned })
        let pointed = try XCTUnwrap(vault.items.first { !$0.owned })
        vault.remove(owned)
        vault.remove(pointed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path), "the original must never be deleted")
        XCTAssertTrue(vault.items.isEmpty)
    }

    func testForgettingAfterAMoveDeletesNothing() throws {
        let vault = store()
        vault.add(text: "moved away")
        let item = try XCTUnwrap(vault.items.first)
        vault.forget(ids: [item.id])
        XCTAssertTrue(vault.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testTextLinksAndImagesBecomeFiles() throws {
        let vault = store()
        XCTAssertTrue(vault.add(text: "First line\nsecond"))
        XCTAssertTrue(vault.add(link: URL(string: "https://example.com/page")!))
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        XCTAssertTrue(vault.add(imageData: try XCTUnwrap(image.pngData)))
        let names = vault.items.map(\.name)
        XCTAssertTrue(names.contains("First line.txt"))
        XCTAssertTrue(names.contains("example.com.webloc"))
        XCTAssertTrue(names.contains { $0.hasPrefix("Image ") && $0.hasSuffix(".png") })
        let webloc = try XCTUnwrap(vault.items.first { $0.name.hasSuffix(".webloc") })
        let plist = try XCTUnwrap(NSDictionary(contentsOfFile: webloc.path))
        XCTAssertEqual(plist["URL"] as? String, "https://example.com/page")
    }

    func testOldItemsAreClearedWhenAskedTo() throws {
        let vault = store()
        vault.add(text: "old")
        now += 7_200
        vault.add(text: "new")
        vault.clearAfter = 3_600
        XCTAssertEqual(vault.items.map(\.name), ["new.txt"])
    }

    func testAMissingFileIsMarkedAndLeftOutOfDrags() throws {
        let vault = store()
        let file = try userFile("gone.txt")
        vault.add(urls: [file])
        try FileManager.default.removeItem(at: file)
        vault.refresh()
        XCTAssertEqual(vault.missing.count, 1)
        XCTAssertTrue(vault.urls().isEmpty)
    }

    func testARenamedFileIsFoundAgain() throws {
        let vault = store()
        let file = try userFile("before.txt")
        vault.add(urls: [file])
        let renamed = file.deletingLastPathComponent().appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        vault.refresh()
        XCTAssertEqual(vault.items.first?.name, "after.txt")
        XCTAssertTrue(vault.missing.isEmpty)
    }

    func testTheShelfSurvivesARelaunch() throws {
        let storeURL = root.appendingPathComponent("vault.json")
        let first = store(storeURL: storeURL)
        first.add(text: "kept")
        // Saved off the main thread after a short pause.
        let saved = expectation(description: "saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { saved.fulfill() }
        wait(for: [saved], timeout: 3)
        let second = store(storeURL: storeURL)
        XCTAssertEqual(second.items.map(\.name), ["kept.txt"])
    }

    func testZipMakesOneArchiveOfSeveralFiles() throws {
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("Archive.zip")
        XCTAssertTrue(VaultStore.makeZip(of: [a, b], at: zip))
        let attributes = try FileManager.default.attributesOfItem(atPath: zip.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
    }

    func testTemporaryPlaces() {
        let home = "/Users/demo"
        let temp = "/private/var/folders/xy/abc/T/"
        func temporary(_ path: String) -> Bool {
            VaultStore.isTemporary(URL(fileURLWithPath: path), home: home, temporaryDirectory: temp)
        }
        XCTAssertTrue(temporary("/private/var/folders/xy/abc/T/screenshot.png"))
        XCTAssertTrue(temporary("/tmp/x.txt"))
        XCTAssertTrue(temporary("/Users/demo/Library/Caches/com.app/file.bin"))
        XCTAssertTrue(temporary("/Users/demo/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf"))
        XCTAssertTrue(temporary("/Users/demo/Library/Containers/com.other/Data/tmp/drag.png"))
        XCTAssertFalse(temporary("/Users/demo/Desktop/report.pdf"))
        XCTAssertFalse(temporary("/Users/demo/Documents/Library/Caches-notes.txt"))
    }

    func testNamesAreSafeAndUnique() throws {
        XCTAssertEqual(VaultStore.fileName(from: "a/b: c.", fallback: "x"), "a-b- c")
        XCTAssertEqual(VaultStore.fileName(from: "   ", fallback: "Text"), "Text")
        XCTAssertEqual(VaultStore.fileName(from: String(repeating: "x", count: 80), fallback: "t").count, 48)
        let first = VaultStore.uniqueURL(in: root, name: "n", ext: "txt")
        try "".write(to: first, atomically: true, encoding: .utf8)
        XCTAssertEqual(VaultStore.uniqueURL(in: root, name: "n", ext: "txt").lastPathComponent, "n 2.txt")
    }
}

@MainActor
final class VaultDropTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("VaultDropTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testFilesComeFirst() {
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        guard case .files(let urls) = VaultDrop.read(pasteboard) else { return XCTFail("expected files") }
        XCTAssertEqual(urls.map(\.path), ["/tmp/a.txt"])
        XCTAssertTrue(VaultDrop.canRead(pasteboard))
    }

    func testAWebLinkIsALink() {
        pasteboard.setString("https://example.com/x", forType: .string)
        guard case .link(let url) = VaultDrop.read(pasteboard) else { return XCTFail("expected a link") }
        XCTAssertEqual(url.host, "example.com")
    }

    func testOtherTextIsText() {
        pasteboard.setString("just some words", forType: .string)
        guard case .text(let text) = VaultDrop.read(pasteboard) else { return XCTFail("expected text") }
        XCTAssertEqual(text, "just some words")
    }

    func testAnImageIsAnImage() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        pasteboard.setData(try XCTUnwrap(image.pngData), forType: .png)
        guard case .image(_, let ext) = VaultDrop.read(pasteboard) else { return XCTFail("expected an image") }
        XCTAssertEqual(ext, "png")
    }

    func testNothingUsableIsNothing() {
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
        XCTAssertNil(VaultDrop.read(pasteboard))
        XCTAssertFalse(VaultDrop.canRead(pasteboard))
    }
}

// MARK: - Next meeting

@MainActor
final class MeetingMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: String, start: TimeInterval, length: TimeInterval = 1800,
                         link: String? = nil) -> MeetingMonitor.Meeting {
        MeetingMonitor.Meeting(id: id, title: id, start: now.addingTimeInterval(start),
                               end: now.addingTimeInterval(start + length), calendar: "Work", color: nil,
                               location: nil, joinURL: link.flatMap(URL.init(string:)), eventIdentifier: nil)
    }

    func testJoinLinksAreFoundWhereverTheInviteHidesThem() {
        XCTAssertEqual(MeetingMonitor.joinURL(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123456?pwd=x"])?.host,
                       "us02web.zoom.us")
        XCTAssertEqual(MeetingMonitor.joinURL(in: ["https://meet.google.com/abc-defg-hij"])?.path, "/abc-defg-hij")
        XCTAssertNotNil(MeetingMonitor.joinURL(in: [
            "Microsoft Teams meeting https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x"]))
        XCTAssertNotNil(MeetingMonitor.joinURL(in: ["https://acme.webex.com/meet/jo"]))
        XCTAssertNotNil(MeetingMonitor.joinURL(in: ["https://facetime.apple.com/join#v=1&p=abc"]))
        // A link that is not a call is not a Join button.
        XCTAssertNil(MeetingMonitor.joinURL(in: ["Agenda: https://docs.google.com/document/d/1"]))
        XCTAssertNil(MeetingMonitor.joinURL(in: ["https://zoom.us/pricing"]))
        XCTAssertNil(MeetingMonitor.joinURL(in: [nil, "", "no links here"]))
    }

    func testTheNextMeetingIsTheOneUnderWayOrSoonest() {
        let list = [meeting("later", start: 5000), meeting("now", start: -600), meeting("done", start: -7200),
                    meeting("soon", start: 900)]
        let (next, later) = MeetingMonitor.upcoming(list, now: now)
        XCTAssertEqual(next?.id, "now")
        XCTAssertEqual(later.map(\.id), ["soon", "later"])
    }

    func testLaterIsTodayOnlyAndAtMostTwo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        func at(_ hour: Double, _ id: String) -> MeetingMonitor.Meeting {
            MeetingMonitor.Meeting(id: id, title: id, start: base.addingTimeInterval(hour * 3600),
                                   end: base.addingTimeInterval(hour * 3600 + 1800), calendar: "", color: nil,
                                   location: nil, joinURL: nil, eventIdentifier: nil)
        }
        let list = [at(1, "a"), at(2, "b"), at(3, "c"), at(4, "d"), at(20, "tomorrow")]
        let (next, later) = MeetingMonitor.upcoming(list, now: base, calendar: calendar)
        XCTAssertEqual(next?.id, "a")
        XCTAssertEqual(later.map(\.id), ["b", "c"])
    }

    func testTheRingFillsOverTheLastHourAndThroughTheMeeting() {
        let soon = meeting("m", start: 1800)
        XCTAssertEqual(soon.fraction(at: now), 0.5, accuracy: 0.001)
        XCTAssertEqual(meeting("m", start: 7200).fraction(at: now), 0)
        let running = meeting("m", start: -900, length: 1800)
        XCTAssertEqual(running.fraction(at: now), 0.5, accuracy: 0.001)
    }

    func testReadings() {
        XCTAssertEqual(MeetingMonitor.reading(for: nil, now: now), "—")
        XCTAssertEqual(MeetingMonitor.reading(for: meeting("m", start: 12 * 60), now: now), "12m")
        XCTAssertEqual(MeetingMonitor.reading(for: meeting("m", start: 10), now: now), "1m")
        XCTAssertEqual(MeetingMonitor.reading(for: meeting("m", start: -60), now: now), "now")
        XCTAssertEqual(MeetingMonitor.reading(for: meeting("m", start: 3 * 3600), now: now),
                       MeetingMonitor.time(now.addingTimeInterval(3 * 3600)))
    }
}

// MARK: - Focus cycles

@MainActor
final class FocusCycleTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timer() -> FocusTimer {
        let timer = FocusTimer(clock: { [unowned self] in self.now }, statsStore: nil)
        timer.setMinutes(25, notify: false)
        timer.cycle = .init(shortBreakMinutes: 5, longBreakMinutes: 15, longBreakEvery: 2, autoStartsNext: true)
        timer.cyclesEnabled = true
        return timer
    }

    private func runOut(_ timer: FocusTimer) {
        now += timer.remaining(at: now) + 1
        timer.finishIfDue()
    }

    func testFocusThenBreaksWithALongOneEveryFewSessions() {
        let timer = timer()
        var ends: [(FocusTimer.Phase, FocusTimer.Phase)] = []
        timer.onFinish = { ends.append(($0, $1)) }
        timer.start()
        runOut(timer)
        XCTAssertEqual(timer.phase, .shortBreak)
        XCTAssertTrue(timer.isRunning, "the next phase starts by itself")
        XCTAssertEqual(timer.remaining(at: now), 300, accuracy: 0.01)
        runOut(timer)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.phaseLine, "Focus · 2 of 2")
        runOut(timer)
        XCTAssertEqual(timer.phase, .longBreak)
        runOut(timer)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.completedInCycle, 0)
        XCTAssertEqual(ends.map(\.0), [.focus, .shortBreak, .focus, .longBreak])
        XCTAssertEqual(ends.map(\.1), [.shortBreak, .focus, .longBreak, .focus])
    }

    func testOnlyFinishedFocusCountsTowardsToday() {
        let timer = timer()
        timer.start()
        runOut(timer)               // 25 minutes of focus
        runOut(timer)               // the break counts for nothing
        timer.skip()                // nor does focus skipped
        let today = timer.stats.day(now)
        XCTAssertEqual(today.minutes, 25)
        XCTAssertEqual(today.sessions, 1)
    }

    func testWithoutAutoStartTheNextPhaseWaits() {
        let timer = timer()
        timer.cycle.autoStartsNext = false
        timer.start()
        runOut(timer)
        XCTAssertEqual(timer.phase, .shortBreak)
        XCTAssertTrue(timer.isIdle)
        XCTAssertEqual(timer.remaining(at: now), 300)
    }

    func testFocusRunningIsReportedForDoNotDisturb() {
        let timer = timer()
        var changes: [Bool] = []
        timer.onFocusRunningChange = { changes.append($0) }
        timer.start()
        timer.pause()
        timer.start()
        runOut(timer)               // into a break: focus stops
        XCTAssertEqual(changes, [true, false, true, false])
    }

    func testTurningCyclesOffEndsABreak() {
        let timer = timer()
        timer.start()
        runOut(timer)
        XCTAssertEqual(timer.phase, .shortBreak)
        timer.cyclesEnabled = false
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertTrue(timer.isIdle)
        XCTAssertNil(timer.phaseLine)
    }

    func testStatsKeepAWeekAndAMonth() {
        var stats = FocusStats()
        let calendar = Calendar(identifier: .gregorian)
        stats.record(minutes: 25, on: now, calendar: calendar)
        stats.record(minutes: 50, on: now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        stats.record(minutes: 15, on: yesterday, calendar: calendar)
        let week = stats.week(endingOn: now, calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last, FocusStats.Day(minutes: 75, sessions: 2))
        XCTAssertEqual(week[5], FocusStats.Day(minutes: 15, sessions: 1))
        let later = calendar.date(byAdding: .day, value: 40, to: now)!
        stats.record(minutes: 5, on: later, calendar: calendar)
        XCTAssertEqual(stats.days.count, 1, "a month later, the old days are gone")
        XCTAssertEqual(FocusStats.total(75), "1 h 15 m")
        XCTAssertEqual(FocusStats.total(40), "40 m")
    }

    func testStatsRoundTrip() throws {
        let suite = "FocusCycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var stats = FocusStats()
        stats.record(minutes: 30, on: now)
        stats.save(to: defaults)
        XCTAssertEqual(FocusStats.load(from: defaults), stats)
    }
}

// MARK: - Clipboard extras

@MainActor
final class ClipboardExtrasTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipboardExtrasTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testSearchMatchesEveryWordInAnyOrderAndCase() {
        let now = Date()
        let items: [ClipboardMonitor.Item] = [
            .init(kind: .text, text: "git push origin main", copiedAt: now),
            .init(kind: .link, text: "https://github.com/Mr-Who-Root/notchdeck", copiedAt: now),
            .init(kind: .file, text: "/Users/demo/Desktop/Invoice March.pdf", copiedAt: now),
            .init(kind: .image, text: "", copiedAt: now, image: Data([1])),
        ]
        XCTAssertEqual(ClipboardMonitor.filter(items, query: "MAIN push").map(\.kind), [.text])
        XCTAssertEqual(ClipboardMonitor.filter(items, query: "notchdeck").map(\.kind), [.link])
        XCTAssertEqual(ClipboardMonitor.filter(items, query: "invoice").map(\.kind), [.file])
        XCTAssertEqual(ClipboardMonitor.filter(items, query: "desktop").count, 0, "files match on their names only")
        XCTAssertEqual(ClipboardMonitor.filter(items, query: "  ").count, 4)
    }

    func testStrippingKeepsTheTextAndDropsTheFormatting() throws {
        let rtf = try NSAttributedString(string: "Bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            .data(from: NSRange(location: 0, length: 10), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("Bold words", forType: .string)
        XCTAssertTrue(ClipboardMonitor.hasRichText(pasteboard))

        let monitor = ClipboardMonitor(pasteboard: pasteboard, storeURL: nil)
        XCTAssertTrue(monitor.stripFormatting())
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold words")
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertFalse(monitor.stripFormatting(), "already plain")
    }

    func testFilesAndPlainTextAreNotRichText() {
        pasteboard.setString("plain", forType: .string)
        XCTAssertFalse(ClipboardMonitor.hasRichText(pasteboard))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a") as NSURL])
        XCTAssertFalse(ClipboardMonitor.hasRichText(pasteboard))
    }

    func testCopyingASnippetPutsItOnTheClipboardAndInTheHistory() {
        let monitor = ClipboardMonitor(pasteboard: pasteboard, storeURL: nil)
        monitor.copyText("Thanks,\nAlex")
        XCTAssertEqual(pasteboard.string(forType: .string), "Thanks,\nAlex")
        XCTAssertEqual(monitor.items.first?.text, "Thanks,\nAlex")
        XCTAssertEqual(monitor.lastCopiedID, monitor.items.first?.id)
    }
}

@MainActor
final class SnippetStoreTests: XCTestCase {
    private func store() throws -> (SnippetStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (SnippetStore(storeURL: url), url)
    }

    func testAddEditRemoveAndKeep() throws {
        let (store, url) = try store()
        let first = try XCTUnwrap(store.add(text: "ssh demo@host"))
        XCTAssertEqual(store.add(text: "ssh demo@host")?.id, first.id, "the same text is kept once")
        XCTAssertNil(store.add(text: "   "))
        var edited = first
        edited.title = "Build box"
        store.update(edited)
        XCTAssertEqual(store.snippets.first?.label, "Build box")
        store.add(text: "Thanks,\nAlex")
        XCTAssertEqual(SnippetStore(storeURL: url).snippets.count, 2)
        store.remove(edited)
        XCTAssertEqual(SnippetStore(storeURL: url).snippets.map(\.label), ["Thanks,"])
    }

    func testFilterLooksAtTitleAndText() {
        let snippets: [SnippetStore.Snippet] = [.init(title: "Address", text: "1 Infinite Loop"),
                                                .init(title: "", text: "Kind regards")]
        XCTAssertEqual(SnippetStore.filter(snippets, query: "address").count, 1)
        XCTAssertEqual(SnippetStore.filter(snippets, query: "loop").count, 1)
        XCTAssertEqual(SnippetStore.filter(snippets, query: "regards kind").count, 1)
        XCTAssertEqual(SnippetStore.filter(snippets, query: "").count, 2)
    }
}

// MARK: - Live status

@MainActor
final class LiveStatusTests: XCTestCase {
    func testABatteryReading() {
        let charging: [String: Any] = [kIOPSCurrentCapacityKey: 76, kIOPSMaxCapacityKey: 100,
                                       kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: true,
                                       kIOPSTimeToFullChargeKey: 70]
        let reading = PowerMonitor.reading(from: charging)
        XCTAssertEqual(reading?.level, 76)
        XCTAssertEqual(reading?.onAC, true)
        XCTAssertEqual(reading?.remainingText, "Full in 1 h 10 min")

        let battery: [String: Any] = [kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 100,
                                      kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSTimeToEmptyKey: -1]
        let onBattery = PowerMonitor.reading(from: battery)
        XCTAssertEqual(onBattery?.title, "On battery")
        XCTAssertNil(onBattery?.remainingText, "still being worked out")
        XCTAssertNil(PowerMonitor.reading(from: [:]))
    }

    func testDurations() {
        XCTAssertEqual(PowerMonitor.duration(45), "45 min")
        XCTAssertEqual(PowerMonitor.duration(120), "2 h")
        XCTAssertEqual(PowerMonitor.duration(320), "5 h 20 min")
    }

    func testADownloadsFinalName() {
        func final(_ name: String) -> String {
            TransferMonitor.finalURL(for: URL(fileURLWithPath: "/Users/demo/Downloads/" + name)).lastPathComponent
        }
        XCTAssertEqual(final("report.pdf.download"), "report.pdf")
        XCTAssertEqual(final("movie.mp4.crdownload"), "movie.mp4")
        XCTAssertEqual(final("archive.zip.part"), "archive.zip")
        XCTAssertEqual(final("photo.jpg"), "photo.jpg")
    }

    func testShortcutNamesAreParsed() {
        XCTAssertEqual(ShortcutsRunner.parse("Focus On\n\nFocus Off\nFocus On\n  Morning  \n"),
                       ["Focus Off", "Focus On", "Morning"])
    }
}

/// The live card for each kind of event lays out and paints. Set
/// `DECK_RENDER_PATH` to look at them.
@MainActor
final class LiveCardRenderTests: XCTestCase {
    func testEveryLiveCardRenders() throws {
        let events: [(String, LiveEvent)] = [
            ("power", .power(.init(level: 76, isCharging: true, onAC: true, minutesRemaining: 70))),
            ("plugged", .power(.init(level: 80, isCharging: false, onAC: true, minutesRemaining: nil))),
            ("downloaded", .downloaded(name: "report.pdf", url: URL(fileURLWithPath: "/Users/demo/Downloads/report.pdf"))),
            ("focus", .focus(title: "Time for a break", detail: "Short break: 5 minutes.", onBreak: true)),
            ("meeting", .meeting(.init(id: "m", title: "Design review", start: Date().addingTimeInterval(300),
                                       end: Date().addingTimeInterval(2100), calendar: "Work", color: .systemBlue,
                                       location: nil, joinURL: URL(string: "https://meet.google.com/abc"),
                                       eventIdentifier: nil))),
        ]
        for (name, event) in events {
            let size = LiveCard.size(for: event)
            let renderer = ImageRenderer(content: LiveCard(event: event, direction: .down)
                .frame(width: size.width, height: size.height + NotchLayout.tailLength)
                .background(Color(white: 0.35))
                .environment(\.colorScheme, .dark)
                .environment(\.notchdeckHeadlessGlass, true))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(name) did not render")
            if let directory = ProcessInfo.processInfo.environment["DECK_RENDER_PATH"] {
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-\(name).png"))
            }
        }
    }
}

// MARK: - Settings

@MainActor
final class DeckPreferencesTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!

    override func setUp() {
        domain = "DeckPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
    }

    func testAFreshInstallHasEveryCellAndSensibleDefaults() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.deckTools, [.nowPlaying, .meeting, .clipboard, .vault, .timer])
        XCTAssertFalse(preferences.vaultKeepsCopies)
        XCTAssertEqual(preferences.vaultClearAfter, .never)
        XCTAssertEqual(preferences.meetingHeadsUpMinutes, 5)
        XCTAssertTrue(preferences.liveCharging)
        XCTAssertTrue(preferences.liveDownloads)
        XCTAssertFalse(preferences.focusCycles)
        XCTAssertEqual(preferences.focusShortBreakMinutes, 5)
        XCTAssertEqual(preferences.focusLongBreakMinutes, 15)
        XCTAssertEqual(preferences.focusLongBreakEvery, 4)
        XCTAssertTrue(preferences.focusAutoStartsNext)
        XCTAssertEqual(preferences.focusStartShortcut, "")
        XCTAssertEqual(preferences.focusEndShortcut, "")
        XCTAssertFalse(preferences.clipboardAlwaysPlainText)
    }

    func testEverySettingIsKeptAcrossALaunch() {
        let preferences = Preferences(defaults: defaults)
        preferences.showsVault = false
        preferences.showsMeeting = false
        preferences.vaultKeepsCopies = true
        preferences.vaultClearAfter = .day
        preferences.meetingHeadsUpMinutes = 10
        preferences.liveCharging = false
        preferences.liveDownloads = false
        preferences.focusCycles = true
        preferences.focusShortBreakMinutes = 7
        preferences.focusLongBreakMinutes = 20
        preferences.focusLongBreakEvery = 3
        preferences.focusAutoStartsNext = false
        preferences.focusStartShortcut = "Focus On"
        preferences.focusEndShortcut = "Focus Off"
        preferences.clipboardAlwaysPlainText = true

        let again = Preferences(defaults: defaults)
        XCTAssertEqual(again.deckTools, [.nowPlaying, .clipboard, .timer])
        XCTAssertTrue(again.vaultKeepsCopies)
        XCTAssertEqual(again.vaultClearAfter, .day)
        XCTAssertEqual(again.meetingHeadsUpMinutes, 10)
        XCTAssertFalse(again.liveCharging)
        XCTAssertFalse(again.liveDownloads)
        XCTAssertTrue(again.focusCycles)
        XCTAssertEqual(again.focusShortBreakMinutes, 7)
        XCTAssertEqual(again.focusLongBreakMinutes, 20)
        XCTAssertEqual(again.focusLongBreakEvery, 3)
        XCTAssertFalse(again.focusAutoStartsNext)
        XCTAssertEqual(again.focusStartShortcut, "Focus On")
        XCTAssertEqual(again.focusEndShortcut, "Focus Off")
        XCTAssertTrue(again.clipboardAlwaysPlainText)
    }

    func testOutOfRangeValuesAreBroughtBackIn() {
        defaults.set(99, forKey: "meetingHeadsUpMinutes")
        defaults.set(0, forKey: "focusShortBreakMinutes")
        defaults.set(500, forKey: "focusLongBreakMinutes")
        defaults.set(1, forKey: "focusLongBreakEvery")
        defaults.set("fortnight", forKey: "vaultClearAfter")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.meetingHeadsUpMinutes, 5)
        XCTAssertEqual(preferences.focusShortBreakMinutes, 1)
        XCTAssertEqual(preferences.focusLongBreakMinutes, 90)
        XCTAssertEqual(preferences.focusLongBreakEvery, 2)
        XCTAssertEqual(preferences.vaultClearAfter, .never)
    }

    func testClearAfterIntervals() {
        XCTAssertNil(VaultClearAfter.never.interval)
        XCTAssertEqual(VaultClearAfter.hour.interval, 3600)
        XCTAssertEqual(VaultClearAfter.day.interval, 86_400)
        XCTAssertEqual(VaultClearAfter.week.interval, 604_800)
    }

    func testTheStarTakesASnippetBackOut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = SnippetStore(storeURL: url)
        store.toggle(text: "ssh demo@host")
        XCTAssertTrue(store.contains(text: "ssh demo@host"))
        store.toggle(text: "ssh demo@host")
        XCTAssertFalse(store.contains(text: "ssh demo@host"))
        XCTAssertTrue(SnippetStore(storeURL: url).snippets.isEmpty)
    }
}

/// Settings → Deck drawn whole, in a real window so the native controls draw:
/// set `DECK_RENDER_PATH` to look at it.
@MainActor
final class DeckSettingsRenderTests: XCTestCase {
    func testEveryPaneRenders() async throws {
        for section in ["accounts", "appearance", "notifications", "costs", "general"] {
            try await render(section: section, height: 2_400)
        }
    }

    func testTheDeckPaneRendersEverySection() async throws {
        try await render(section: "deck", height: 2_900)
    }

    private func render(section: String, height: CGFloat) async throws {
        let domain = "DeckSettingsRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // The pane comes up on the section last looked at, kept in the app's
        // own defaults: shown Deck here, and put back as it was.
        let previous = UserDefaults.standard.string(forKey: SettingsView.sectionKey)
        UserDefaults.standard.set(section, forKey: SettingsView.sectionKey)
        defer { UserDefaults.standard.set(previous, forKey: SettingsView.sectionKey) }

        let preferences = Preferences(defaults: defaults)
        preferences.focusCycles = true
        let store = UsageStore(providers: [], archive: UsageArchive(defaults: defaults), disconnected: [])
        let content = SettingsView(preferences: preferences, providers: { [] },
            signOut: { store.signOut(providerID: $0) }, signIn: { store.signIn(providerID: $0) },
            switchAccount: { _ in false }, retry: { store.refresh(providerID: $0) },
            resetPosition: {}, quit: {}, updater: Updater(), usageStore: store)
            .frame(width: SettingsView.width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: SettingsView.width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 900_000_000)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        if let directory = ProcessInfo.processInfo.environment["DECK_RENDER_PATH"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(section).png"))
        }
    }
}
