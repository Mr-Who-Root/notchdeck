import AppKit
import Combine
import UniformTypeIdentifiers

/// **The vault**: a shelf in the notch for files on their way somewhere.
/// Drag files onto the notch to hold them, then drag them out of the notch
/// into Finder, Mail, a chat or a browser's upload box.
///
/// It holds a *pointer* to each file — a bookmark, so a file renamed or moved
/// while it waits is still found — rather than a second copy taking up disk.
/// The exceptions get a copy of their own in the vault's folder: anything that
/// came from somewhere temporary (a Mail attachment, a screenshot's floating
/// thumbnail, a file a browser hands over), anything dropped that is not a file
/// at all (text, a link, an image out of a web page), and everything when
/// "Keep a copy" is switched on.
@MainActor
final class VaultStore: ObservableObject {
    static let shared = VaultStore()

    struct Item: Identifiable, Equatable, Codable {
        var id = UUID()
        var name: String
        /// Where the file was last found.
        var path: String
        /// Finds the file again after a rename or a move. Nil for the vault's
        /// own copies, which never move.
        var bookmark: Data?
        /// True when the file is the vault's own copy, in its folder.
        var owned: Bool
        var addedAt: Date
        var isDirectory: Bool
        /// In bytes; nil for a folder.
        var size: Int64?

        var url: URL { URL(fileURLWithPath: path) }
    }

    @Published private(set) var items: [Item] = []
    /// Items whose file is not where it was and could not be found again.
    @Published private(set) var missing: Set<UUID> = []
    /// While a drag the vault can take is over a notch, so the cell and the
    /// card can say "drop here".
    @Published var isDropTargeted = false
    /// While a zip is being made.
    @Published private(set) var isZipping = false

    /// Copy everything dropped in, not only what came from somewhere temporary.
    var keepsCopies = false
    /// How long an item stays before it is cleared by itself; nil keeps it.
    var clearAfter: TimeInterval? {
        didSet { purgeExpired() }
    }

    /// Where the vault keeps its own copies.
    let folder: URL
    private let storeURL: URL?
    private var saveWork: DispatchWorkItem?
    private var purgeTimer: Timer?
    private let clock: () -> Date

    init(folder: URL? = VaultStore.defaultFolder, storeURL: URL? = VaultStore.defaultStoreURL,
         clock: @escaping () -> Date = Date.init) {
        self.folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("NotchDeck-Vault")
        self.storeURL = storeURL
        self.clock = clock
        load()
    }

    nonisolated static var supportFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NotchDeck", isDirectory: true)
    }

    nonisolated static var defaultFolder: URL? {
        supportFolder?.appendingPathComponent("Vault", isDirectory: true)
    }

    nonisolated static var defaultStoreURL: URL? {
        supportFolder?.appendingPathComponent("vault.json")
    }

    // MARK: - Watching the clock

    /// Clears expired items now and every few minutes from here on.
    func start() {
        purgeExpired()
        refresh()
        guard purgeTimer == nil else { return }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeExpired() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
    }

    func stop() {
        purgeTimer?.invalidate()
        purgeTimer = nil
    }

    // MARK: - Putting things in

    /// Files and folders dropped on the notch. Returns how many were added —
    /// one already held is moved to the top rather than added twice.
    @discardableResult
    func add(urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            let source = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = items.firstIndex(where: { $0.path == source.path }) {
                let item = items.remove(at: existing)
                items.insert(item, at: 0)
                continue
            }
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let insideVault = source.path.hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/")
            let copy = !insideVault && (keepsCopies || Self.isTemporary(source))
            let item: Item?
            if insideVault {
                item = makeItem(at: source, owned: true)
            } else if copy {
                item = copyIn(source)
            } else {
                item = makeItem(at: source, owned: false)
            }
            if let item {
                items.insert(item, at: 0)
                added += 1
            }
        }
        if added > 0 || !urls.isEmpty { save() }
        return added
    }

    /// Text dropped from somewhere that offers no file: kept as a text file.
    @discardableResult
    func add(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = text.data(using: .utf8) else { return false }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return write(data, named: Self.fileName(from: firstLine, fallback: L10n.t("Text")), ext: "txt")
    }

    /// A link dragged out of a browser's address bar: kept as a `.webloc`,
    /// which opens it again with a double-click.
    @discardableResult
    func add(link: URL) -> Bool {
        let plist: [String: Any] = ["URL": link.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return false }
        return write(data, named: Self.fileName(from: link.host ?? link.absoluteString, fallback: L10n.t("Link")),
                     ext: "webloc")
    }

    /// An image dragged out of a page or an app that offers no file.
    @discardableResult
    func add(imageData: Data, ext: String = "png") -> Bool {
        write(imageData, named: L10n.t("Image") + " " + Self.stamp(clock()), ext: ext)
    }

    /// Files offered as a promise — Photos, Mail, some browsers — written
    /// into the vault's folder as they arrive.
    func receive(_ promises: [NSFilePromiseReceiver]) {
        guard ensureFolder() else { return }
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:],
                                         operationQueue: Self.promiseQueue) { [weak self] url, error in
                guard error == nil else {
                    Log.usage.error("vault: promised file not received: \(error!.localizedDescription, privacy: .public)")
                    return
                }
                Task { @MainActor in
                    guard let self, let item = self.makeItem(at: url, owned: true) else { return }
                    self.items.removeAll { $0.path == item.path }
                    self.items.insert(item, at: 0)
                    self.save()
                }
            }
        }
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Everything a drop can carry, in the order a drop is read: files first,
    /// then promised files, then an image, a link, and plain text last.
    @discardableResult
    func accept(_ payload: VaultDrop.Payload) -> Bool {
        switch payload {
        case .files(let urls): return add(urls: urls) > 0 || !urls.isEmpty
        case .promises(let receivers): receive(receivers); return true
        case .image(let data, let ext): return add(imageData: data, ext: ext)
        case .link(let url): return add(link: url)
        case .text(let text): return add(text: text)
        }
    }

    // MARK: - Taking things out

    /// Forgets the item. The vault's own copy is deleted with it; a file it
    /// only pointed at is left exactly where it is.
    func remove(_ item: Item) {
        if item.owned { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll { $0.id == item.id }
        missing.remove(item.id)
        save()
    }

    /// After a drag out that *moved* the files: they are somewhere else now,
    /// so the vault lets go of them without deleting anything.
    func forget(ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
        missing.subtract(ids)
        save()
    }

    func clear() {
        for item in items where item.owned { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll()
        missing.removeAll()
        save()
    }

    /// The files as they are now, for dragging out and sharing. Missing ones
    /// are left out.
    func urls(for ids: [UUID]? = nil) -> [URL] {
        items.filter { (ids?.contains($0.id) ?? true) && !missing.contains($0.id) }.map(\.url)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    func openFolder() {
        guard ensureFolder() else { return }
        NSWorkspace.shared.open(folder)
    }

    /// Finds every pointed-at file again, following renames and moves.
    func refresh() {
        var changed = false
        var gone: Set<UUID> = []
        for index in items.indices {
            var item = items[index]
            if let bookmark = item.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if url.path != item.path {
                        item.path = url.path
                        item.name = url.lastPathComponent
                        changed = true
                    }
                    if stale, let fresh = try? url.bookmarkData() {
                        item.bookmark = fresh
                        changed = true
                    }
                }
            }
            if !FileManager.default.fileExists(atPath: item.path) { gone.insert(item.id) }
            items[index] = item
        }
        if missing != gone { missing = gone }
        if changed { save() }
    }

    func purgeExpired() {
        guard let clearAfter else { return }
        let cutoff = clock().addingTimeInterval(-clearAfter)
        let expired = items.filter { $0.addedAt < cutoff }
        guard !expired.isEmpty else { return }
        for item in expired where item.owned { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll { $0.addedAt < cutoff }
        save()
    }

    // MARK: - Zipping

    /// Zips the items into one archive in the vault — "Archive.zip", or the
    /// item's own name for one — and puts the archive at the top.
    func zip(ids: [UUID]? = nil) {
        let sources = urls(for: ids)
        guard !sources.isEmpty, !isZipping, ensureFolder() else { return }
        isZipping = true
        let base = sources.count == 1 ? sources[0].deletingPathExtension().lastPathComponent : L10n.t("Archive")
        let destination = Self.uniqueURL(in: folder, name: base, ext: "zip")
        let folder = self.folder
        Task.detached(priority: .userInitiated) {
            let ok = Self.makeZip(of: sources, at: destination)
            await MainActor.run {
                self.isZipping = false
                guard ok, let item = self.makeItem(at: destination, owned: true) else {
                    Log.usage.error("vault: zip failed in \(folder.path, privacy: .public)")
                    return
                }
                self.items.insert(item, at: 0)
                self.save()
            }
        }
    }

    /// `ditto` makes the same archive Finder's Compress does. Several items go
    /// into a staging folder first (APFS clones, so no real copying), because
    /// `ditto` archives one source at a time.
    nonisolated static func makeZip(of sources: [URL], at destination: URL) -> Bool {
        let fm = FileManager.default
        var source = sources[0]
        var staging: URL?
        if sources.count > 1 {
            let root = fm.temporaryDirectory.appendingPathComponent("NotchDeck-zip-\(UUID().uuidString)")
            let inner = root.appendingPathComponent(destination.deletingPathExtension().lastPathComponent)
            do {
                try fm.createDirectory(at: inner, withIntermediateDirectories: true)
                for url in sources {
                    let target = uniqueURL(in: inner, name: url.deletingPathExtension().lastPathComponent,
                                           ext: url.pathExtension)
                    try fm.copyItem(at: url, to: target)
                }
            } catch {
                try? fm.removeItem(at: root)
                return false
            }
            staging = root
            source = inner
        }
        defer { if let staging { try? fm.removeItem(at: staging) } }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0 && fm.fileExists(atPath: destination.path)
    }

    /// A fixed shelf, never saved: demo mode's, and the tests'.
    func showDemo(_ demo: [Item]) {
        stop()
        saveWork?.cancel()
        items = demo
        missing = []
    }

    // MARK: - Where things come from

    /// Whether a file sits somewhere that may not keep it: the system's
    /// temporary folders, a cache, an app's private scratch space, or Mail's
    /// attachment folder. Those are copied in rather than pointed at, or the
    /// vault would be holding a file about to vanish.
    nonisolated static func isTemporary(_ url: URL, home: String = NSHomeDirectory(),
                                        temporaryDirectory: String = NSTemporaryDirectory()) -> Bool {
        let path = url.standardizedFileURL.path
        let temp = URL(fileURLWithPath: temporaryDirectory).standardizedFileURL.resolvingSymlinksInPath().path
        let prefixes = [
            temp + "/",
            "/private/var/folders/", "/var/folders/",
            "/private/tmp/", "/tmp/",
            home + "/Library/Caches/",
            home + "/Library/Mail Downloads/",
            home + "/Library/Containers/com.apple.mail/",
            home + "/Library/Group Containers/",
        ]
        if prefixes.contains(where: { path.hasPrefix($0) }) { return true }
        // An app's own tmp, inside its container.
        if path.hasPrefix(home + "/Library/Containers/"), path.contains("/Data/tmp/") { return true }
        return false
    }

    // MARK: - Files

    private func makeItem(at url: URL, owned: Bool) -> Item? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let size = isDirectory ? nil : (values?.fileSize).map(Int64.init)
        return Item(name: url.lastPathComponent, path: url.path,
                    bookmark: owned ? nil : try? url.bookmarkData(),
                    owned: owned, addedAt: clock(), isDirectory: isDirectory, size: size)
    }

    private func copyIn(_ source: URL) -> Item? {
        guard ensureFolder() else { return nil }
        let target = Self.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent,
                                    ext: source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            Log.usage.error("vault: copy failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return makeItem(at: target, owned: true)
    }

    private func write(_ data: Data, named name: String, ext: String) -> Bool {
        guard ensureFolder() else { return false }
        let target = Self.uniqueURL(in: folder, name: name, ext: ext)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return false
        }
        guard let item = makeItem(at: target, owned: true) else { return false }
        items.insert(item, at: 0)
        save()
        return true
    }

    private func ensureFolder() -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            Log.usage.error("vault: folder not created: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// "name.ext", or "name 2.ext" and up when that is taken.
    nonisolated static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        let fm = FileManager.default
        func candidate(_ n: Int) -> URL {
            let stem = n == 1 ? name : "\(name) \(n)"
            let url = folder.appendingPathComponent(stem)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var n = 1
        while fm.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    /// A safe file name from a line of text: no slashes or colons, not too long.
    nonisolated static func fileName(from text: String, fallback: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let short = String(cleaned.prefix(48)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? fallback : short
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    // MARK: - Keeping it

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder.vault.decode([Item].self, from: data)
        else { return }
        items = saved
        missing = Set(saved.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
    }

    private func save() {
        saveWork?.cancel()
        guard let storeURL else { return }
        let kept = items
        let work = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder.vault.encode(kept).write(to: storeURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            } catch {
                Log.usage.error("vault not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// **What a drop onto the notch is carrying**, read off its pasteboard.
enum VaultDrop {
    enum Payload {
        case files([URL])
        case promises([NSFilePromiseReceiver])
        case image(Data, String)
        case link(URL)
        case text(String)
    }

    /// Every type the notch registers for, so the window server routes such
    /// a drag to it.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Whether the pasteboard holds something the vault can keep.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        return !types.isDisjoint(with: draggedTypes)
    }

    /// The best reading of the drop, or nil when it carries nothing the vault
    /// can keep.
    static func read(_ pasteboard: NSPasteboard) -> Payload? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            return .promises(promises)
        }
        if let png = pasteboard.data(forType: .png) {
            return .image(png, "png")
        }
        if pasteboard.types?.contains(.tiff) == true, let image = NSImage(pasteboard: pasteboard),
           let png = image.pngData {
            return .image(png, "png")
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let link = urls.first, let scheme = link.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return .link(link)
        }
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
                return .link(url)
            }
            return .text(string)
        }
        return nil
    }
}

/// **Whether a drag the vault could take is under way**, anywhere on screen.
///
/// The notch is a hole to the pointer until it is reached, so it cannot wait
/// to be told about a drag by AppKit — it would never be asked. Instead a new
/// drag shows up as the drag pasteboard changing between the button going
/// down and the pointer moving with it held, the same signal Finder's own
/// spring-loading reads.
@MainActor
final class FileDragWatcher {
    static let shared = FileDragWatcher()

    private(set) var isDragging = false
    /// Posted whenever `isDragging` changes — every notch listens, one per
    /// display.
    static let changed = Notification.Name("NotchDeckFileDragChanged")

    private var monitors: [Any] = []
    private var countAtMouseDown = NSPasteboard(name: .drag).changeCount

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        set(false)
    }

    /// Also asked by the notch's own cursor poll: a drag that ended somewhere
    /// the monitor never heard the button come up still ends here.
    func checkButton() {
        if isDragging, NSEvent.pressedMouseButtons & 1 == 0 { set(false) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            countAtMouseDown = NSPasteboard(name: .drag).changeCount
            set(false)
        case .leftMouseDragged:
            guard !isDragging else { return }
            let pasteboard = NSPasteboard(name: .drag)
            if pasteboard.changeCount != countAtMouseDown, VaultDrop.canRead(pasteboard) { set(true) }
        case .leftMouseUp:
            set(false)
        default:
            break
        }
    }

    private func set(_ dragging: Bool) {
        guard dragging != isDragging else { return }
        isDragging = dragging
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// **The other end of a drag out of the vault.** One object for every drag,
/// living for the app's lifetime, so a drag that outlives the card it started
/// on — the notch folds while the file is still in the air — still hears how
/// it ended.
@MainActor
final class VaultDragSource: NSObject, NSDraggingSource {
    static let shared = VaultDragSource()

    private var dragging: [UUID] = []

    /// Starts dragging these items out of `view`, from the press in `event`.
    func begin(ids: [UUID], from view: NSView, event: NSEvent) {
        let store = VaultStore.shared
        let chosen = store.items.filter { ids.contains($0.id) && !store.missing.contains($0.id) }
        guard !chosen.isEmpty else { return }
        dragging = chosen.map(\.id)
        let point = view.convert(event.locationInWindow, from: nil)
        let side: CGFloat = 32
        let items: [NSDraggingItem] = chosen.enumerated().map { index, item in
            let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: side, height: side)
            let offset = CGFloat(min(index, 4)) * 4
            dragItem.setDraggingFrame(CGRect(x: point.x - side / 2 + offset, y: point.y - side / 2 - offset,
                                             width: side, height: side),
                                      contents: icon)
            return dragItem
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Copies unless ⌘ is held, which moves — the vault is a shelf, and a
    /// shelf hands out copies unless told otherwise. Finder on its own would
    /// move a file dropped on the same disk, which here would take it away
    /// from wherever it lived.
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        return NSEvent.modifierFlags.contains(.command) ? [.move, .generic] : [.copy]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        MainActor.assumeIsolated {
            let ids = dragging
            dragging = []
            // Moved: the files live somewhere else now.
            if operation.contains(.move) || operation.contains(.generic) {
                VaultStore.shared.forget(ids: ids)
            }
        }
    }
}

private extension JSONEncoder {
    static var vault: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var vault: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
