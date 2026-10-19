import AppKit
import Combine

/// **What the Mac is playing**, from whichever app is the system's now-playing
/// source — Music, Spotify, a browser tab, a podcast app — and the transport
/// controls for it.
///
/// Read through `notchdeck-nowplaying.js`, a small helper run under Apple's own
/// `osascript`: since macOS 15.4, MediaRemote only answers that question for
/// Apple-signed processes, so asking in-process returns nothing. The helper is
/// one long-lived child process that prints a line when anything changes and
/// takes commands on stdin; it exits by itself when the pipe closes, so it can
/// never outlive the app.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    struct Track: Equatable {
        var title: String
        var artist: String?
        var album: String?
        var duration: TimeInterval?
        /// Where playback was at `timestamp`.
        var elapsed: TimeInterval
        var timestamp: Date
        /// 1 while playing at normal speed, 0 while paused.
        var rate: Double
        var isPlaying: Bool
        var bundleID: String?
        var appName: String?

        /// Where playback is now, carried forward from the last report rather
        /// than asked for every second.
        func position(at now: Date) -> TimeInterval {
            let speed = isPlaying ? (rate > 0 ? rate : 1) : 0
            let position = elapsed + now.timeIntervalSince(timestamp) * speed
            guard let duration, duration > 0 else { return max(0, position) }
            return min(max(0, position), duration)
        }

        func progress(at now: Date) -> Double? {
            guard let duration, duration > 0 else { return nil }
            return position(at: now) / duration
        }

        /// "Artist — Album", whichever of the two there is.
        var subtitle: String? {
            let parts = [artist, album].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        }
    }

    enum Command: String {
        case play, pause, toggle, next, previous
    }

    @Published private(set) var track: Track?
    /// The item's own artwork, or the playing app's icon when it sends none.
    @Published private(set) var artwork: NSImage?
    /// False when MediaRemote could not be reached at all, so the card can say
    /// so rather than "Nothing playing".
    @Published private(set) var isAvailable = true
    @Published private(set) var canSendCommands = true

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var wanted = false
    private var restartDelay: TimeInterval = 1
    private var itemArtwork: NSImage?

    private init() {}

    func start() {
        guard !wanted else { return }
        wanted = true
        restartDelay = 1
        launch()
    }

    func stop() {
        wanted = false
        input?.closeFile()
        input = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        track = nil
        artwork = nil
        itemArtwork = nil
    }

    func send(_ command: Command) {
        // Answer the button at once; the helper's next report confirms or
        // corrects it.
        if var track {
            switch command {
            case .toggle: track.isPlaying.toggle()
            case .play: track.isPlaying = true
            case .pause: track.isPlaying = false
            case .next, .previous: break
            }
            if track.isPlaying != self.track?.isPlaying {
                track.elapsed = self.track?.position(at: Date()) ?? track.elapsed
                track.timestamp = Date()
                track.rate = track.isPlaying ? 1 : 0
                self.track = track
            }
        }
        write(command.rawValue)
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if var track {
            track.elapsed = seconds
            track.timestamp = Date()
            self.track = track
        }
        write("seek \(seconds)")
    }

    /// Brings the playing app forward — what clicking the title does.
    func openPlayer() {
        guard let bundleID = track?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A fixed track, with no helper behind it: demo mode's, and the tests'.
    func showDemo(_ track: Track?, artwork: NSImage? = nil) {
        stop()
        isAvailable = true
        canSendCommands = true
        self.track = track
        self.artwork = artwork
    }

    // MARK: - The helper process

    private func launch() {
        guard wanted, process == nil else { return }
        guard let script = Bundle.main.url(forResource: "notchdeck-nowplaying", withExtension: "js") else {
            Log.usage.error("now playing: helper script missing from the bundle")
            isAvailable = false
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.ended(ended) }
        }
        do {
            try process.run()
        } catch {
            Log.usage.error("now playing: helper failed to start: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer.removeAll()
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        (ended.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wanted else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            // The helper died between reports; its termination restarts it.
        }
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "state":
            restartDelay = 1
            isAvailable = true
            canSendCommands = object["canSend"] as? Bool ?? true
            let next = Self.track(from: object)
            if next?.bundleID != track?.bundleID { refreshArtwork(bundleID: next?.bundleID) }
            if next != track { track = next }
        case "artwork":
            itemArtwork = (object["data"] as? String)
                .flatMap { Data(base64Encoded: $0) }
                .flatMap(NSImage.init(data:))
            refreshArtwork(bundleID: track?.bundleID)
        case "unavailable":
            isAvailable = false
            track = nil
        default:
            break
        }
    }

    private func refreshArtwork(bundleID: String?) {
        if let itemArtwork {
            artwork = itemArtwork
        } else if let bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            artwork = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            artwork = nil
        }
    }

    /// Pure, for the tests: one helper report as a track, or nil when nothing
    /// is playing.
    static func track(from object: [String: Any]) -> Track? {
        guard object["present"] as? Bool == true else { return nil }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let artist = object["artist"] as? String
        guard let name = title ?? artist else { return nil }
        let rate = object["rate"] as? Double ?? 0
        let playing = object["playing"] as? Bool ?? (rate > 0)
        let stamp = (object["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let duration = (object["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        return Track(title: name,
                     artist: title == nil ? nil : artist,
                     album: object["album"] as? String,
                     duration: duration,
                     elapsed: object["elapsed"] as? Double ?? 0,
                     timestamp: stamp,
                     rate: rate,
                     isPlaying: playing,
                     bundleID: object["bundleID"] as? String,
                     appName: object["appName"] as? String)
    }
}
