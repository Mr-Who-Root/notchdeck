import Combine
import Foundation

/// **A focus timer in the notch**: pick a length, start it, and the notch opens
/// with a chime when it is up.
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

    /// The lengths the card offers, in minutes.
    static let presets: [Int] = [5, 15, 25, 50]
    static let defaultMinutes = 25

    @Published private(set) var state: State = .idle
    /// The length a fresh start runs for.
    @Published private(set) var duration: TimeInterval = TimeInterval(FocusTimer.defaultMinutes * 60)

    /// Called once when a running timer reaches zero.
    var onFinish: (() -> Void)?
    /// Called when the chosen length changes, so Preferences can keep it.
    var onDurationChange: ((Int) -> Void)?

    private var finishWork: DispatchWorkItem?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    var minutes: Int { Int((duration / 60).rounded()) }

    /// A new length. A timer under way starts over at it; the same length
    /// again leaves it running.
    func setMinutes(_ minutes: Int, notify: Bool = true) {
        let clamped = min(max(minutes, 1), 180)
        let length = TimeInterval(clamped * 60)
        guard length != duration else { return }
        duration = length
        if !isIdle { reset() }
        if notify { onDurationChange?(clamped) }
    }

    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .idle: return duration
        case .running(let endsAt): return max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): return remaining
        }
    }

    /// How much of the length is left, 1 at the start and 0 at the end.
    func fractionRemaining(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(remaining(at: now) / duration, 0), 1)
    }

    var isRunning: Bool { if case .running = state { return true }; return false }
    var isIdle: Bool { state == .idle }

    func start() {
        let length: TimeInterval
        switch state {
        case .running: return
        case .paused(let remaining): length = remaining
        case .idle: length = duration
        }
        let endsAt = clock().addingTimeInterval(length)
        state = .running(endsAt: endsAt)
        scheduleFinish(at: endsAt)
    }

    func pause() {
        guard case .running(let endsAt) = state else { return }
        finishWork?.cancel()
        finishWork = nil
        state = .paused(remaining: max(0, endsAt.timeIntervalSince(clock())))
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func reset() {
        finishWork?.cancel()
        finishWork = nil
        state = .idle
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
        state = .idle
        onFinish?()
    }
}
