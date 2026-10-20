import AppKit
import SwiftUI

/// **The next meeting's card**: when, where, and a Join button for the call.
struct MeetingCard: View {
    @ObservedObject private var meetings = MeetingMonitor.shared
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(text: DeckTool.meeting.title)
                Spacer().frame(height: NotchLayout.headerToBlock)
                switch meetings.access {
                case .unknown:
                    permission(L10n.t("See your next meeting and join its call from the notch. NotchDeck reads your calendars on this Mac only."),
                               button: L10n.t("Allow Calendar Access")) { meetings.requestAccess() }
                case .denied:
                    permission(L10n.t("NotchDeck can't read your calendars. Allow it in System Settings → Privacy & Security → Calendars."),
                               button: L10n.t("Open Privacy Settings")) { meetings.openPrivacySettings() }
                case .granted:
                    if let next = meetings.next {
                        details(next, now: context.date)
                    } else {
                        CardNote(text: L10n.t("Nothing on your calendars for the next 24 hours."))
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func permission(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: NotchLayout.blockSpacing) {
            CardNote(text: text)
            PillButton(title: button, prominent: true, action: action)
                .frame(height: DeckLayout.chipHeight)
        }
    }

    private func details(_ meeting: MeetingMonitor.Meeting, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meeting.title)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .frame(height: NotchLayout.cardTitleLineHeight, alignment: .leading)
            Text(MeetingMonitor.span(of: meeting, now: now))
                .font(Typography.cardBody)
                .monospacedDigit()
                .foregroundStyle(meeting.isInProgress(at: now) ? Palette.textPrimary : secondaryInk)
                .lineLimit(1)
                .frame(height: NotchLayout.cardBodyLineHeight, alignment: .leading)
            HStack(spacing: Design.px(8)) {
                Circle()
                    .fill(meeting.color.map(Color.init(nsColor:)) ?? Palette.textSecondary)
                    .frame(width: Design.px(14), height: Design.px(14))
                Text([meeting.calendar, meeting.location].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: NotchLayout.cardBodyLineHeight, alignment: .leading)

            Spacer().frame(height: NotchLayout.blockSpacing)
            HStack(spacing: Design.px(16)) {
                if meeting.joinURL != nil {
                    PillButton(title: L10n.t("Join"), prominent: true) { meetings.join(meeting) }
                        .help(meeting.joinURL?.host ?? "")
                }
                PillButton(title: L10n.t("Calendar")) { meetings.openCalendar(meeting) }
                    .help(L10n.t("Show it in Calendar"))
            }
            .frame(height: DeckLayout.chipHeight)

            Spacer().frame(height: NotchLayout.blockSpacing)
            if !meetings.later.isEmpty {
                Text(L10n.t("Later today"))
                    .font(Typography.cardBody.weight(.semibold))
                    .foregroundStyle(secondaryInk)
                    .frame(height: NotchLayout.cardBodyLineHeight, alignment: .leading)
                ForEach(meetings.later) { later in
                    HStack(spacing: Design.px(14)) {
                        Text(MeetingMonitor.time(later.start))
                            .monospacedDigit()
                            .foregroundStyle(secondaryInk)
                        Text(later.title)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if later.joinURL != nil {
                            Image(systemName: "video").foregroundStyle(secondaryInk)
                        }
                    }
                    .font(Typography.cardBody)
                    .frame(height: NotchLayout.cardBodyLineHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { meetings.openCalendar(later) }
                }
            }
        }
    }
}

/// **What is downloading**, each with its progress.
struct TransfersCard: View {
    @ObservedObject private var monitor = TransferMonitor.shared
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(text: DeckTool.transfers.title)
            Spacer().frame(height: NotchLayout.headerToBlock)
            if monitor.transfers.isEmpty {
                CardNote(text: L10n.t("All done. Finished downloads are in your Downloads folder."))
            } else {
                ForEach(monitor.transfers.prefix(DeckLayout.transferRows)) { transfer in
                    VStack(alignment: .leading, spacing: NotchLayout.labelToBar) {
                        HStack(spacing: Design.px(10)) {
                            Image(systemName: transfer.isAirDrop ? "airplayaudio" : "arrow.down.circle")
                                .foregroundStyle(secondaryInk)
                            Text(transfer.name)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Design.px(8))
                            Text(TransferMonitor.bytesText(transfer))
                                .monospacedDigit()
                                .foregroundStyle(secondaryInk)
                                .lineLimit(1)
                        }
                        .font(Typography.cardBody)
                        .frame(height: NotchLayout.cardBodyLineHeight)
                        if let fraction = transfer.fraction {
                            DeckBar(fraction: fraction)
                        } else {
                            IndeterminateBar()
                        }
                    }
                    .frame(height: DeckLayout.transferRowHeight, alignment: .top)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A bar for a download whose size is not known: a short fill sliding along.
private struct IndeterminateBar: View {
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { proxy in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let width = proxy.size.width * 0.3
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.barTrack)
                    Capsule().fill(accentColor)
                        .frame(width: width)
                        .offset(x: (proxy.size.width + width) * t - width)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: DeckLayout.progressHeight)
    }
}

/// **The card a live event opens the notch with** — see `LiveEvent`. One
/// row: what it is, a line or two about it, and its buttons as small round
/// icons at the end, sized to what it says rather than to the tallest event.
/// The charger's is a slim pill of its own.
struct LiveCard: View {
    let event: LiveEvent
    var direction: NotchEdge.TooltipDirection = .leading
    var tailOffset: CGFloat = 0

    /// The card's own size, without its tail — worked out here, not by
    /// SwiftUI, so the hover region is known before it is drawn.
    static func size(for event: LiveEvent) -> CGSize {
        let row = rowHeight(for: event)
        let width: CGFloat
        switch event {
        case .power: width = Design.px(500)
        default: width = NotchLayout.cardWidth
        }
        return CGSize(width: width, height: 2 * NotchLayout.cardPadding + row)
    }

    static let glyphSize = Design.px(64)

    static func rowHeight(for event: LiveEvent) -> CGFloat {
        let text = NotchLayout.cardTitleLineHeight
            + (detail(for: event) == nil ? 0 : Design.px(2) + NotchLayout.cardBodyLineHeight)
        return max(glyphSize, text)
    }

    static func title(for event: LiveEvent) -> String {
        switch event {
        case .power(let reading): return reading.title
        case .downloaded(let name, _): return name
        case .focus(let title, _, _): return title
        case .meeting(let meeting): return meeting.title
        }
    }

    static func detail(for event: LiveEvent) -> String? {
        switch event {
        case .power(let reading): return reading.remainingText
        case .downloaded:
            return L10n.t("Downloaded")
        case .focus(_, let detail, _): return detail
        case .meeting(let meeting):
            let minutes = Int(ceil(meeting.start.timeIntervalSinceNow / 60))
            return minutes > 0 ? L10n.t("In \(minutes) min · \(MeetingMonitor.time(meeting.start))")
                               : L10n.t("Starting now")
        }
    }

    var body: some View {
        let size = Self.size(for: event)
        TooltipShell(height: size.height, direction: direction, tailOffset: tailOffset, width: size.width) {
            LiveCardContent(event: event)
                .frame(height: Self.rowHeight(for: event))
        }
    }
}

private struct LiveCardContent: View {
    let event: LiveEvent
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        HStack(spacing: Design.px(16)) {
            glyph
            VStack(alignment: .leading, spacing: Design.px(2)) {
                Text(LiveCard.title(for: event))
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = LiveCard.detail(for: event) {
                    Text(detail)
                        .font(Typography.cardBody)
                        .monospacedDigit()
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Never cut short: the text gives way first.
            trailing
                .fixedSize()
                .layoutPriority(1)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch event {
        case .power(let reading):
            BatteryGlyph(level: reading.level, charging: reading.onAC)
        case .downloaded(_, let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: LiveCard.glyphSize, height: LiveCard.glyphSize)
        case .focus(_, _, let onBreak):
            symbolGlyph(onBreak ? "cup.and.saucer.fill" : "timer", color: accentColor)
        case .meeting(let meeting):
            symbolGlyph(meeting.joinURL != nil ? "video.fill" : "calendar",
                        color: meeting.color.map(Color.init(nsColor:)) ?? accentColor)
        }
    }

    private func symbolGlyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: Design.px(38), weight: .semibold))
            .foregroundStyle(color)
            .frame(width: LiveCard.glyphSize, height: LiveCard.glyphSize)
            .background(Circle().fill(color.opacity(0.16)))
    }

    /// The charge, or the event's buttons as round icons.
    @ViewBuilder private var trailing: some View {
        switch event {
        case .power(let reading):
            Text("\(reading.level)%")
                .font(Typography.cardTitle)
                .monospacedDigit()
                .foregroundStyle(reading.onAC ? Color.green : (reading.level <= 20 ? Color.red : Palette.textPrimary))
        case .downloaded(_, let url):
            HStack(spacing: Design.px(10)) {
                RoundAction(symbol: "arrow.up.forward.app", help: L10n.t("Open"), prominent: true) {
                    NSWorkspace.shared.open(url)
                }
                RoundAction(symbol: "magnifyingglass", help: L10n.t("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                AddToVaultButton(url: url)
            }
        case .focus:
            let timer = FocusTimer.shared
            HStack(spacing: Design.px(10)) {
                RoundAction(symbol: timer.isRunning ? "pause.fill" : "play.fill",
                            help: timer.isRunning ? L10n.t("Pause") : L10n.t("Start"), prominent: true) {
                    timer.toggle()
                }
                if timer.cyclesEnabled {
                    RoundAction(symbol: "forward.end.fill", help: L10n.t("Skip")) { timer.skip() }
                }
            }
        case .meeting(let meeting):
            HStack(spacing: Design.px(10)) {
                if meeting.joinURL != nil {
                    JoinPill { MeetingMonitor.shared.join(meeting) }
                }
                RoundAction(symbol: "calendar", help: L10n.t("Show in Calendar")) {
                    MeetingMonitor.shared.openCalendar(meeting)
                }
            }
        }
    }
}

/// A round icon button, the live cards' kind of action.
private struct RoundAction: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Design.px(24), weight: .semibold))
                .foregroundStyle(prominent ? accentColor : Palette.textPrimary)
                .frame(width: Design.px(56), height: Design.px(56))
                .background(Circle().fill(prominent ? accentColor.opacity(0.18) : Palette.barTrack))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Join", short and in the accent: the one thing a meeting card is for.
private struct JoinPill: View {
    let action: () -> Void
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            Text(L10n.t("Join"))
                .font(Typography.cardBody.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Design.px(26))
                .frame(height: Design.px(56))
                .background(Capsule().fill(accentColor))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A battery whose fill rises into place, with a bolt while it charges.
private struct BatteryGlyph: View {
    let level: Int
    let charging: Bool
    @State private var shown: CGFloat = 0
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        let fill: Color = level <= 20 && !charging ? .red : (charging ? .green : accentColor)
        HStack(spacing: Design.px(2)) {
            ZStack {
                RoundedRectangle(cornerRadius: Design.px(9), style: .continuous)
                    .strokeBorder(Palette.textPrimary.opacity(0.75), lineWidth: Design.px(3))
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: Design.px(5), style: .continuous)
                        .fill(fill)
                        .frame(width: max(0, (proxy.size.width - Design.px(12)) * shown))
                        .padding(Design.px(6))
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: Design.px(20), weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            .frame(width: Design.px(60), height: Design.px(30))
            RoundedRectangle(cornerRadius: Design.px(2))
                .fill(Palette.textPrimary.opacity(0.75))
                .frame(width: Design.px(4), height: Design.px(11))
        }
        .frame(height: LiveCard.glyphSize)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { shown = CGFloat(level) / 100 }
        }
    }
}

/// Puts a file in the vault: a round button beside the card's others.
private struct AddToVaultButton: View {
    let url: URL
    @State private var added = false
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        Button {
            VaultStore.shared.add(urls: [url])
            added = true
        } label: {
            Image(systemName: added ? "checkmark" : "tray.and.arrow.down")
                .font(.system(size: Design.px(24), weight: .semibold))
                .foregroundStyle(added ? accentColor : Palette.textPrimary)
                .frame(width: Design.px(56), height: Design.px(56))
                .background(Circle().fill(Palette.barTrack))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .help(added ? L10n.t("In the vault") : L10n.t("Add to Vault"))
    }
}
