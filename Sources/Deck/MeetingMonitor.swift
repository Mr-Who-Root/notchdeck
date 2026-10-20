import AppKit
import Combine
import EventKit

/// **The next meeting**, from every calendar the Mac's Calendar app has —
/// iCloud, Google, Exchange, subscriptions — with a Join button when the
/// invitation carries a video-call link.
///
/// Read through EventKit, which asks once for access to calendars. All-day
/// events, cancelled ones and ones you declined are left out: they are not
/// meetings you are about to be late for.
@MainActor
final class MeetingMonitor: ObservableObject {
    static let shared = MeetingMonitor()

    struct Meeting: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var calendar: String
        var color: NSColor?
        var location: String?
        var joinURL: URL?
        /// For opening the event in Calendar.
        var eventIdentifier: String?

        func isInProgress(at now: Date) -> Bool { start <= now && now < end }

        /// What the ring shows: how far into the last hour before it starts,
        /// or how far through it once it has.
        func fraction(at now: Date) -> Double {
            if isInProgress(at: now) {
                let length = end.timeIntervalSince(start)
                return length > 0 ? min(max(now.timeIntervalSince(start) / length, 0), 1) : 1
            }
            let until = start.timeIntervalSince(now)
            return min(max(1 - until / 3600, 0), 1)
        }
    }

    enum Access: Equatable {
        case unknown, granted, denied
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var next: Meeting?
    /// The ones after `next` that still start today.
    @Published private(set) var later: [Meeting] = []

    /// Minutes before a meeting the notch opens to say so; nil never.
    var headsUpMinutes: Int? = 5
    /// Called when a meeting is `headsUpMinutes` away.
    var onHeadsUp: ((Meeting) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: Any?
    private var announced: Set<String> = []
    private var running = false

    private init() {
        refreshAccess()
    }

    // MARK: - Watching

    func start() {
        guard !running else { return }
        running = true
        refreshAccess()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reload()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        next = nil
        later = []
    }

    /// Asks macOS for access to calendars — the one question this asks, and
    /// only when the card's button is clicked.
    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { Log.usage.error("calendar access: \(error.localizedDescription, privacy: .public)") }
                self.access = granted ? .granted : .denied
                if granted { self.reload() }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Acting on a meeting

    /// Joins when there is a link and the meeting is close or under way;
    /// otherwise shows it in Calendar.
    func joinOrOpen(_ meeting: Meeting? = nil, now: Date = Date()) {
        guard let meeting = meeting ?? next else {
            openCalendar(nil)
            return
        }
        if let link = meeting.joinURL,
           meeting.isInProgress(at: now) || meeting.start.timeIntervalSince(now) <= 10 * 60 {
            NSWorkspace.shared.open(link)
        } else {
            openCalendar(meeting)
        }
    }

    func join(_ meeting: Meeting) {
        if let link = meeting.joinURL { NSWorkspace.shared.open(link) }
    }

    func openCalendar(_ meeting: Meeting?) {
        if let id = meeting?.eventIdentifier,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendar, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Fixed meetings, never read from a calendar: demo mode's, and the tests'.
    func showDemo(next: Meeting?, later: [Meeting]) {
        stop()
        access = .granted
        self.next = next
        self.later = later
    }

    // MARK: - Reading the calendars

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        case .notDetermined: access = .unknown
        @unknown default: access = .unknown
        }
    }

    private func tick() {
        // A meeting ending, or the next one starting, changes what is shown
        // even when no calendar changed.
        if let next, next.end <= Date() { reload() } else { checkHeadsUp() }
    }

    func reload(now: Date = Date()) {
        refreshAccess()
        guard running, access == .granted else {
            next = nil
            later = []
            return
        }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let meetings = store.events(matching: predicate)
            .filter(Self.counts)
            .map(Self.meeting(from:))
        let (first, rest) = Self.upcoming(meetings, now: now)
        if first != next { next = first }
        if rest != later { later = rest }
        checkHeadsUp(now: now)
    }

    private func checkHeadsUp(now: Date = Date()) {
        guard let minutes = headsUpMinutes, let next, !next.isInProgress(at: now) else { return }
        let key = next.id + "@" + String(next.start.timeIntervalSince1970)
        let until = next.start.timeIntervalSince(now)
        guard until <= TimeInterval(minutes * 60), until > 0, !announced.contains(key) else { return }
        announced.insert(key)
        onHeadsUp?(next)
    }

    /// Whether an event is a meeting worth showing.
    private static func counts(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled else { return false }
        if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined {
            return false
        }
        return true
    }

    private static func meeting(from event: EKEvent) -> Meeting {
        Meeting(id: event.calendarItemIdentifier,
                title: (event.title?.isEmpty == false ? event.title! : L10n.t("Untitled event")),
                start: event.startDate, end: event.endDate,
                calendar: event.calendar?.title ?? "",
                color: event.calendar?.color,
                location: event.location?.isEmpty == false ? event.location : nil,
                joinURL: joinURL(in: [event.url?.absoluteString, event.location, event.notes]),
                eventIdentifier: event.eventIdentifier)
    }

    /// The meeting under way or next to start, and the rest of today's after
    /// it — at most two. Pure, for the tests.
    static func upcoming(_ meetings: [Meeting], now: Date,
                         calendar: Calendar = .current) -> (Meeting?, [Meeting]) {
        let current = meetings
            .filter { $0.end > now }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard let first = current.first else { return (nil, []) }
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let rest = current.dropFirst().filter { $0.start > now && $0.start <= endOfDay }
        return (first, Array(rest.prefix(2)))
    }

    // MARK: - Join links

    /// The first video-call link in the event's URL, location or notes:
    /// Zoom, Google Meet, Microsoft Teams, Webex, GoToMeeting, Whereby,
    /// Amazon Chime, FaceTime, Slack huddles and Around.
    static func joinURL(in fields: [String?]) -> URL? {
        for field in fields.compactMap({ $0 }) where !field.isEmpty {
            let range = NSRange(field.startIndex..., in: field)
            for match in linkDetector.matches(in: field, range: range) {
                guard let url = match.url, isMeetingLink(url) else { continue }
                return url
            }
        }
        return nil
    }

    static func isMeetingLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("zoom.us") || on("zoomgov.com") {
            return path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/s/") || path.hasPrefix("/wc/")
        }
        if on("meet.google.com") { return path.count > 1 }
        if on("teams.microsoft.com") { return path.contains("meetup-join") || path.hasPrefix("/meet/") }
        if on("teams.live.com") { return path.hasPrefix("/meet") }
        if on("webex.com") { return true }
        if on("gotomeeting.com") || on("gotomeet.me") || on("goto.com") { return path.count > 1 }
        if on("whereby.com") || on("chime.aws") || on("around.co") { return path.count > 1 }
        if on("facetime.apple.com") { return path.hasPrefix("/join") }
        if on("app.slack.com") { return path.contains("huddle") }
        return false
    }

    private static let linkDetector: NSDataDetector = {
        // swiftlint:disable:next force_try
        try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// "12m", "1h 5m", the start time once it is further off, or "now".
    static func reading(for meeting: Meeting?, now: Date) -> String {
        guard let meeting else { return "—" }
        if meeting.isInProgress(at: now) { return L10n.t("now") }
        let minutes = Int(ceil(meeting.start.timeIntervalSince(now) / 60))
        if minutes < 60 { return L10n.t("\(max(minutes, 1))m") }
        return time(meeting.start)
    }

    /// "10:30 – 11:00 AM · in 12 min", or "· now" while it runs.
    static func span(of meeting: Meeting, now: Date) -> String {
        let interval = DateIntervalFormatter()
        interval.dateStyle = .none
        interval.timeStyle = .short
        let range = interval.string(from: meeting.start, to: meeting.end)
        if meeting.isInProgress(at: now) {
            let left = Int(ceil(meeting.end.timeIntervalSince(now) / 60))
            return range + " · " + L10n.t("\(left) min left")
        }
        let minutes = Int(ceil(meeting.start.timeIntervalSince(now) / 60))
        if minutes < 60 { return range + " · " + L10n.t("in \(max(minutes, 1)) min") }
        if !Calendar.current.isDate(meeting.start, inSameDayAs: now) { return L10n.t("Tomorrow") + " " + range }
        return range
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
