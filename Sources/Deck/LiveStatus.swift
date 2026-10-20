import AppKit
import Combine
import IOKit.ps

/// **Something happening right now** that the notch opens for a moment to
/// show: the charger going in or out, a download finishing, a focus phase
/// ending, a meeting about to start.
enum LiveEvent: Equatable {
    case power(PowerMonitor.Reading)
    case downloaded(name: String, url: URL)
    case focus(title: String, detail: String, onBreak: Bool)
    case meeting(MeetingMonitor.Meeting)

    /// How long the notch stays open for it.
    var duration: TimeInterval {
        switch self {
        case .power: return 4
        case .downloaded: return 5
        case .focus: return 6
        case .meeting: return 8
        }
    }
}

/// **The battery**, and the moment the charger goes in or comes out.
///
/// IOKit's power-source notification fires on every change in charge as well
/// as on the plug, so the plug is told apart by comparing the source with the
/// last one seen. Nothing at all on a Mac with no battery.
@MainActor
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    struct Reading: Equatable {
        /// 0–100.
        var level: Int
        var isCharging: Bool
        var onAC: Bool
        /// Minutes to full while charging, or left on battery; nil while macOS
        /// is still working it out.
        var minutesRemaining: Int?

        /// "Full in 1 h 10 min", "5 h 20 min left", or nothing while unknown.
        var remainingText: String? {
            guard let minutes = minutesRemaining, minutes > 0 else {
                return onAC && level >= 100 ? L10n.t("Fully charged") : nil
            }
            let duration = PowerMonitor.duration(minutes)
            return onAC ? L10n.t("Full in \(duration)") : L10n.t("\(duration) left")
        }

        var title: String {
            if onAC { return isCharging ? L10n.t("Charging") : (level >= 100 ? L10n.t("Charged") : L10n.t("Plugged in")) }
            return L10n.t("On battery")
        }
    }

    @Published private(set) var reading: Reading?
    /// Called when the charger goes in or comes out — not on every percent.
    var onPlugChange: ((Reading) -> Void)?

    private var source: CFRunLoopSource?
    private var lastOnAC: Bool?

    private init() {}

    var hasBattery: Bool { reading != nil }

    func start() {
        guard source == nil else { return }
        reading = Self.read()
        lastOnAC = reading?.onAC
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.changed() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }

    private func changed() {
        guard let now = Self.read() else { return }
        reading = now
        defer { lastOnAC = now.onAC }
        guard let lastOnAC, lastOnAC != now.onAC else { return }
        onPlugChange?(now)
    }

    /// The internal battery, or nil when there is none.
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return reading(from: description)
        }
        return nil
    }

    /// Pure, for the tests: one power-source description as a reading.
    static func reading(from description: [String: Any]) -> Reading? {
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let key = onAC ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let level = Int((Double(current) / Double(maximum) * 100).rounded())
        return Reading(level: min(max(level, 0), 100), isCharging: charging, onAC: onAC,
                       minutesRemaining: minutes)
    }

    /// "45 min", "1 h 10 min", "5 h".
    nonisolated static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return L10n.t("\(m) min") }
        if m == 0 { return L10n.t("\(h) h") }
        return L10n.t("\(h) h \(m) min")
    }
}

/// **Downloads and AirDrop under way**, from the progress that Safari,
/// Chrome, AirDrop and Finder publish on files in the Downloads folder —
/// the same progress Finder draws on a file's icon.
@MainActor
final class TransferMonitor: ObservableObject {
    static let shared = TransferMonitor()

    struct Transfer: Identifiable, Equatable {
        var id: ObjectIdentifier
        var name: String
        /// Where the finished file will be, with ".download"/".crdownload" and
        /// the like taken off.
        var finalURL: URL
        var fraction: Double?
        var completedBytes: Int64
        var totalBytes: Int64?
        var bytesPerSecond: Int?
        var isAirDrop: Bool
    }

    @Published private(set) var transfers: [Transfer] = []
    /// True while anything is downloading, and for a few seconds after the
    /// last one finishes, so the cell does not blink out the moment it lands.
    @Published private(set) var isActive = false

    /// Called when a transfer finishes and its file is there.
    var onFinish: ((String, URL) -> Void)?

    private var subscriber: Any?
    private var watched: [ObjectIdentifier: (progress: Progress, observations: [NSKeyValueObservation])] = [:]
    private var lingerWork: DispatchWorkItem?

    private init() {}

    func start() {
        guard subscriber == nil,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        subscriber = Progress.addSubscriber(forFileURL: downloads) { [weak self] progress in
            let id = ObjectIdentifier(progress)
            let monitor = self
            Task { @MainActor in monitor?.began(progress) }
            return {
                Task { @MainActor in monitor?.ended(id) }
            }
        }
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        watched.removeAll()
        transfers = []
        isActive = false
    }

    /// Fixed transfers, never read: demo mode's, and the tests'.
    func showDemo(_ demo: [Transfer]) {
        stop()
        transfers = demo
        isActive = !demo.isEmpty
    }

    private func began(_ progress: Progress) {
        let id = ObjectIdentifier(progress)
        guard watched[id] == nil, let url = progress.fileURL ?? (progress.userInfo[.fileURLKey] as? URL) else { return }
        let observations = [
            progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.update(id) }
            },
            progress.observe(\.completedUnitCount, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.update(id) }
            },
        ]
        watched[id] = (progress, observations)
        let airDrop = progress.fileOperationKind == .receiving
        transfers.append(Transfer(id: id, name: Self.finalURL(for: url).lastPathComponent,
                                  finalURL: Self.finalURL(for: url), fraction: nil,
                                  completedBytes: 0, totalBytes: nil, bytesPerSecond: nil, isAirDrop: airDrop))
        update(id)
        lingerWork?.cancel()
        isActive = true
    }

    private func update(_ id: ObjectIdentifier) {
        guard let progress = watched[id]?.progress, let index = transfers.firstIndex(where: { $0.id == id })
        else { return }
        var transfer = transfers[index]
        let total = progress.totalUnitCount
        transfer.totalBytes = total > 0 ? total : nil
        transfer.completedBytes = max(0, progress.completedUnitCount)
        transfer.fraction = progress.isIndeterminate ? nil : min(max(progress.fractionCompleted, 0), 1)
        transfer.bytesPerSecond = progress.throughput
        if transfer != transfers[index] { transfers[index] = transfer }
    }

    private func ended(_ id: ObjectIdentifier) {
        guard let entry = watched.removeValue(forKey: id) else { return }
        let finished = transfers.first { $0.id == id }
        transfers.removeAll { $0.id == id }
        if let finished, !entry.progress.isCancelled {
            // The file appears under its final name a moment after the
            // progress goes; only a file that is there is announced.
            let url = finished.finalURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    if FileManager.default.fileExists(atPath: url.path) {
                        self?.onFinish?(url.lastPathComponent, url)
                    }
                }
            }
        }
        guard transfers.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transfers.isEmpty else { return }
                self.isActive = false
            }
        }
        lingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Overall progress across every transfer with a known size.
    var overallFraction: Double? {
        let known = transfers.filter { $0.totalBytes != nil }
        guard !known.isEmpty else { return nil }
        let total = known.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let done = known.reduce(Int64(0)) { $0 + $1.completedBytes }
        return total > 0 ? Double(done) / Double(total) : nil
    }

    /// The name a download will have once it lands: browsers write to a
    /// temporary name beside it and rename at the end.
    nonisolated static func finalURL(for url: URL) -> URL {
        let temporary = ["download", "crdownload", "part", "partial", "opdownload"]
        var result = url
        while temporary.contains(result.pathExtension.lowercased()) {
            result = result.deletingPathExtension()
        }
        return result
    }

    /// "12.4 MB of 80 MB", or just "12.4 MB" while the size is unknown.
    static func bytesText(_ transfer: Transfer) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: transfer.completedBytes)
        guard let total = transfer.totalBytes else { return done }
        return L10n.t("\(done) of \(formatter.string(fromByteCount: total))")
    }
}
