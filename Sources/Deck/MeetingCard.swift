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
/// height for every kind, so the hover region is known before it is drawn.
struct LiveCard: View {
    let event: LiveEvent
    var direction: NotchEdge.TooltipDirection = .leading
    var tailOffset: CGFloat = 0

    static var cardHeight: CGFloat {
        2 * NotchLayout.cardPadding + Design.px(96) + NotchLayout.blockSpacing + DeckLayout.chipHeight
    }

    var body: some View {
        TooltipShell(height: Self.cardHeight, direction: direction, tailOffset: tailOffset) {
            LiveCardContent(event: event)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct LiveCardContent: View {
    let event: LiveEvent
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.px(24)) {
                glyph
                    .frame(width: Design.px(96), height: Design.px(96))
                VStack(alignment: .leading, spacing: Design.px(4)) {
                    Text(title)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Typography.cardBody)
                            .monospacedDigit()
                            .foregroundStyle(secondaryInk)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: Design.px(96))
            Spacer().frame(height: NotchLayout.blockSpacing)
            actions
                .frame(height: DeckLayout.chipHeight)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch event {
        case .power(let reading):
            BatteryGlyph(level: reading.level, charging: reading.onAC)
        case .downloaded(_, let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        case .focus(_, _, let onBreak):
            Image(systemName: onBreak ? "cup.and.saucer.fill" : "timer")
                .font(.system(size: Design.px(56), weight: .semibold))
                .foregroundStyle(accentColor)
        case .meeting(let meeting):
            Image(systemName: meeting.joinURL != nil ? "video.fill" : "calendar")
                .font(.system(size: Design.px(56), weight: .semibold))
                .foregroundStyle(meeting.color.map(Color.init(nsColor:)) ?? accentColor)
        }
    }

    private var title: String {
        switch event {
        case .power(let reading): return "\(reading.title) · \(reading.level)%"
        case .downloaded(let name, _): return name
        case .focus(let title, _, _): return title
        case .meeting(let meeting): return meeting.title
        }
    }

    private var detail: String? {
        switch event {
        case .power(let reading): return reading.remainingText
        case .downloaded(_, let url):
            return L10n.t("Downloaded to \(url.deletingLastPathComponent().lastPathComponent)")
        case .focus(_, let detail, _): return detail
        case .meeting(let meeting):
            let minutes = Int(ceil(meeting.start.timeIntervalSinceNow / 60))
            return minutes > 0 ? L10n.t("Starts in \(minutes) min · \(MeetingMonitor.time(meeting.start))")
                               : L10n.t("Starting now")
        }
    }

    @ViewBuilder private var actions: some View {
        switch event {
        case .power:
            EmptyView()
        case .downloaded(_, let url):
            HStack(spacing: Design.px(16)) {
                PillButton(title: L10n.t("Open"), prominent: true) { NSWorkspace.shared.open(url) }
                PillButton(title: L10n.t("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .fixedSize(horizontal: true, vertical: false)
                AddToVaultButton(url: url)
            }
        case .focus:
            HStack(spacing: Design.px(16)) {
                let timer = FocusTimer.shared
                PillButton(title: timer.isRunning ? L10n.t("Pause") : L10n.t("Start"), prominent: true) {
                    timer.toggle()
                }
                if timer.cyclesEnabled {
                    PillButton(title: L10n.t("Skip")) { timer.skip() }
                }
            }
        case .meeting(let meeting):
            HStack(spacing: Design.px(16)) {
                if meeting.joinURL != nil {
                    PillButton(title: L10n.t("Join"), prominent: true) { MeetingMonitor.shared.join(meeting) }
                }
                PillButton(title: L10n.t("Calendar")) { MeetingMonitor.shared.openCalendar(meeting) }
            }
        }
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
        ZStack {
            HStack(spacing: Design.px(3)) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Design.px(12), style: .continuous)
                        .strokeBorder(Palette.textPrimary.opacity(0.8), lineWidth: Design.px(4))
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: Design.px(7), style: .continuous)
                            .fill(fill)
                            .frame(width: max(0, (proxy.size.width - Design.px(16)) * shown))
                            .padding(Design.px(8))
                    }
                }
                .frame(width: Design.px(84), height: Design.px(44))
                RoundedRectangle(cornerRadius: Design.px(3))
                    .fill(Palette.textPrimary.opacity(0.8))
                    .frame(width: Design.px(6), height: Design.px(16))
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: Design.px(30), weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { shown = CGFloat(level) / 100 }
        }
    }
}

/// Puts a file in the vault: a small round button, since it rides beside
/// two pills.
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
                .font(.system(size: Design.px(26), weight: .semibold))
                .foregroundStyle(added ? accentColor : Palette.textPrimary)
                .frame(width: DeckLayout.chipHeight * 1.3, height: DeckLayout.chipHeight)
                .background(Capsule().fill(Palette.barTrack))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .help(added ? L10n.t("In the vault") : L10n.t("Add to Vault"))
    }
}
