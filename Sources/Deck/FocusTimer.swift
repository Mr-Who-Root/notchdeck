import Combine
import Foundation

/// **A focus timer in the notch**: pick a length, start it, and the notch opens
/// with a chime when it is up. With cycles on it runs the classic rhythm —
/// focus, a short break, focus again, and a long break every few sessions.
///
/// Kept as an end date rather than a counter, so it stays right across sleep
/// and never drifts; the cell and the card redraw themselves from it.
@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    enum State: Equatable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    enum Phase: String, Codable, Equatable {
        case focus, shortBreak, longBreak

        var isBreak: Bool { self != .focus }

        var title: String {
            switch self {
            case .focus: return L10n.t("Focus")
            case .shortBreak: return L10n.t("Short break")
            case .longBreak: return L10n.t("Long break")
            }
        }
    }

    /// The rhythm, when cycles are on.
    struct Cycle: Equatable {
        var shortBreakMinutes = 5
        var longBreakMinutes = 15
        /// A long break after this many focus sessions.
        var longBreakEvery = 4
        /// Starts the next phase by itself when one ends.
        var autoStartsNext = true
    }

    /// The lengths the card offers, in minutes.
    static let presets: [Int] = [5, 15, 25, 50]
    static let defaultMinutes = 25

    @Published private(set) var state: State = .idle
    /// The length a focus session runs for.
    @Published private(set) var duration: TimeInterval = TimeInterval(FocusTimer.defaultMinutes * 60)
    @Published private(set) var phase: Phase = .focus
    /// Focus sessions finished since the last long break.
    @Published private(set) var completedInCycle = 0
    /// Whether the rhythm of breaks is on. Off, the timer is a plain countdown.
    @Published var cyclesEnabled = false {
        didSet {
            guard cyclesEnabled != oldValue, !cyclesEnabled else { return }
            if phase.isBreak { reset() }
            completedInCycle = 0
        }
    }
    var cycle = Cycle()
    @Published private(set) var stats: FocusStats

    /// Called once when a phase reaches zero, with the phase that ended and
    /// the one that comes next.
    var onFinish: ((Phase, Phase) -> Void)?
    /// Called when the chosen length changes, so Preferences can keep it.
    var onDurationChange: ((Int) -> Void)?
    /// Called when focus starts running (true) or stops — paused, reset, ended
    /// or skipped (false). For turning Do Not Disturb on and off.
    var onFocusRunningChange: ((Bool) -> Void)?

    private var finishWork: DispatchWorkItem?
    private let clock: () -> Date
    private let statsStore: UserDefaults?
    private var focusWasRunning = false

    init(clock: @escaping () -> Date = Date.init, statsStore: UserDefaults? = .standard) {
        self.clock = clock
        self.statsStore = statsStore
        self.stats = statsStore.flatMap(FocusStats.load(from:)) ?? FocusStats()
    }

    var minutes: Int { Int((duration / 60).rounded()) }

    /// How long the current phase runs.
    var phaseLength: TimeInterval {
        switch phase {
        case .focus: return duration
        case .shortBreak: return TimeInterval(max(cycle.shortBreakMinutes, 1) * 60)
        case .longBreak: return TimeInterval(max(cycle.longBreakMinutes, 1) * 60)
        }
    }

    /// A new length. A focus session under way starts over at it; the same
    /// length again leaves it running.
    func setMinutes(_ minutes: Int, notify: Bool = true) {
        let clamped = min(max(minutes, 1), 180)
        let length = TimeInterval(clamped * 60)
        guard length != duration else { return }
        duration = length
        if !isIdle, phase == .focus { reset() }
        if notify { onDurationChange?(clamped) }
    }

    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .idle: return phaseLength
        case .running(let endsAt): return max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): return remaining
        }
    }

    /// How much of the phase is left, 1 at the start and 0 at the end.
    func fractionRemaining(at now: Date) -> Double {
        let length = phaseLength
        guard length > 0 else { return 0 }
        return min(max(remaining(at: now) / length, 0), 1)
    }

    var isRunning: Bool { if case .running = state { return true }; return false }
    var isIdle: Bool { state == .idle }

    /// "Focus · 2 of 4", "Short break", or nothing with cycles off.
    var phaseLine: String? {
        guard cyclesEnabled else { return nil }
        switch phase {
        case .focus:
            let every = max(cycle.longBreakEvery, 1)
            return L10n.t("Focus · \(completedInCycle % every + 1) of \(every)")
        case .shortBreak, .longBreak:
            return phase.title
        }
    }

    func start() {
        let length: TimeInterval
        switch state {
        case .running: return
        case .paused(let remaining): length = remaining
        case .idle: length = phaseLength
        }
        let endsAt = clock().addingTimeInterval(length)
        state = .running(endsAt: endsAt)
        scheduleFinish(at: endsAt)
        reportFocusRunning()
    }

    func pause() {
        guard case .running(let endsAt) = state else { return }
        finishWork?.cancel()
        finishWork = nil
        state = .paused(remaining: max(0, endsAt.timeIntervalSince(clock())))
        reportFocusRunning()
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    /// Back to the start of a fresh cycle.
    func reset() {
        finishWork?.cancel()
        finishWork = nil
        state = .idle
        phase = .focus
        completedInCycle = 0
        reportFocusRunning()
    }

    /// Ends the phase now and moves to the next — a focus session skipped
    /// counts for nothing.
    func skip() {
        guard cyclesEnabled else { return reset() }
        finishWork?.cancel()
        finishWork = nil
        let next = nextPhase(afterCompleting: phase, counted: false)
        advance(to: next, autoStart: isRunning)
    }

    /// A made-up week, never saved: demo mode's, and the render tests'.
    func showDemoStats(_ demo: FocusStats) {
        stats = demo
    }

    private func scheduleFinish(at endsAt: Date) {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishIfDue() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, endsAt.timeIntervalSince(clock())),
                                      execute: work)
    }

    /// Also called when the Mac wakes: a timer that ran out asleep finishes
    /// as it wakes rather than waiting for a dispatch that slept with it.
    func finishIfDue() {
        guard case .running(let endsAt) = state else { return }
        let left = endsAt.timeIntervalSince(clock())
        guard left <= 0.5 else {
            scheduleFinish(at: endsAt)
            return
        }
        finishWork = nil
        let ended = phase
        if ended == .focus {
            stats.record(minutes: minutes, on: endsAt)
            stats.save(to: statsStore)
        }
        let next = nextPhase(afterCompleting: ended, counted: true)
        if cyclesEnabled {
            advance(to: next, autoStart: cycle.autoStartsNext)
        } else {
            state = .idle
            reportFocusRunning()
        }
        onFinish?(ended, cyclesEnabled ? next : .focus)
    }

    /// What follows a phase. Pure apart from the count it keeps.
    private func nextPhase(afterCompleting ended: Phase, counted: Bool) -> Phase {
        guard cyclesEnabled else { return .focus }
        switch ended {
        case .focus:
            completedInCycle += 1
            return completedInCycle % max(cycle.longBreakEvery, 1) == 0 ? .longBreak : .shortBreak
        case .longBreak:
            completedInCycle = 0
            return .focus
        case .shortBreak:
            return .focus
        }
    }

    private func advance(to next: Phase, autoStart: Bool) {
        phase = next
        state = .idle
        if autoStart { start() } else { reportFocusRunning() }
    }

    private func reportFocusRunning() {
        let running = isRunning && phase == .focus
        guard running != focusWasRunning else { return }
        focusWasRunning = running
        onFocusRunningChange?(running)
    }
}

/// **How much focus, day by day**: the minutes of every focus session that ran
/// to the end, and how many there were. Kept for a month.
struct FocusStats: Codable, Equatable {
    struct Day: Codable, Equatable {
        var minutes = 0
        var sessions = 0
    }

    /// Keyed "yyyy-MM-dd" in the Mac's own time zone.
    var days: [String: Day] = [:]

    static let storeKey = "focusStats"
    static let keptDays = 31

    mutating func record(minutes: Int, on date: Date, calendar: Calendar = .current) {
        let key = Self.key(for: date, calendar: calendar)
        days[key, default: Day()].minutes += minutes
        days[key, default: Day()].sessions += 1
        let cutoff = calendar.date(byAdding: .day, value: -Self.keptDays, to: date) ?? date
        let oldest = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    func day(_ date: Date, calendar: Calendar = .current) -> Day {
        days[Self.key(for: date, calendar: calendar)] ?? Day()
    }

    /// The last seven days, oldest first, today last.
    func week(endingOn date: Date, calendar: Calendar = .current) -> [Day] {
        (0..<7).reversed().map { back in
            day(calendar.date(byAdding: .day, value: -back, to: date) ?? date, calendar: calendar)
        }
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "1 h 15 m", "40 m".
    static func total(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return L10n.t("\(m) m") }
        return m == 0 ? L10n.t("\(h) h") : L10n.t("\(h) h \(m) m")
    }

    static func load(from defaults: UserDefaults) -> FocusStats? {
        guard let data = defaults.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(FocusStats.self, from: data)
    }

    func save(to defaults: UserDefaults?) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }
}
