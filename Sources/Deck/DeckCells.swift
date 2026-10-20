import SwiftUI

/// **One cell of the notch**: a provider's ring, or one of the deck's tools.
/// Same parameters as `ProviderCell`, so every place that draws the stack —
/// the notch itself and the copy carried round a corner — draws the tools too.
struct NotchCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false
    var weeklyRing: WeeklyRing = .off
    var showsWeeklyReading: Bool = false
    var showsReading: Bool = true
    var showsRemaining: Bool = false
    var shutRingsWhenSpent: Bool = true

    var body: some View {
        if let tool = snapshot.deckTool {
            DeckToolCell(tool: tool, showsReading: showsReading)
        } else {
            ProviderCell(snapshot: snapshot, activity: activity, isRefreshing: isRefreshing,
                         weeklyRing: weeklyRing, showsWeeklyReading: showsWeeklyReading,
                         showsReading: showsReading, showsRemaining: showsRemaining,
                         shutRingsWhenSpent: shutRingsWhenSpent)
        }
    }
}

/// A tool's cell: a ring the size of a provider's, with the tool inside it and
/// a short reading under it where the notch has room for one.
struct DeckToolCell: View {
    let tool: DeckTool
    var showsReading: Bool = true

    var body: some View {
        Group {
            switch tool {
            case .nowPlaying: NowPlayingCell(showsReading: showsReading)
            case .meeting:    MeetingCell(showsReading: showsReading)
            case .clipboard:  ClipboardCell(showsReading: showsReading)
            case .vault:      VaultCell(showsReading: showsReading)
            case .timer:      TimerCell(showsReading: showsReading)
            case .transfers:  TransfersCell(showsReading: showsReading)
            }
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tool.title)
    }
}

/// The ring every tool cell wears: the provider rings' track, and an arc in the
/// accent colour when the tool has a fraction to show.
struct DeckRing<Content: View>: View {
    var fraction: Double?
    @ViewBuilder var content: Content
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)
            if let fraction {
                Circle()
                    .inset(by: NotchLayout.trackStroke / 2)
                    .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                    .stroke(accentColor, style: StrokeStyle(lineWidth: NotchLayout.progressStroke,
                                                           lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(NotchMotion.reading, value: fraction)
            }
            content
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }
}

/// The reading under a tool's ring, in the provider readings' face.
struct DeckReading: View {
    let text: String
    var dimmed = false

    var body: some View {
        Text(text)
            .font(Typography.percent)
            .monospacedDigit()
            .foregroundStyle(dimmed ? Palette.textSecondary : Palette.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: NotchLayout.percentLineHeight)
    }
}

private struct DeckSymbol: View {
    let name: String
    var dimmed = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: NotchLayout.glyphSize * 0.82, weight: .semibold))
            .foregroundStyle(dimmed ? Palette.textSecondary : Palette.textPrimary)
    }
}

private struct NowPlayingCell: View {
    let showsReading: Bool
    @ObservedObject private var monitor = NowPlayingMonitor.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: monitor.track?.isPlaying != true)) { context in
            let track = monitor.track
            VStack(spacing: NotchLayout.ringLabelGap) {
                DeckRing(fraction: track?.progress(at: context.date)) {
                    if let artwork = monitor.artwork, track != nil {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: NotchLayout.activityDiameter, height: NotchLayout.activityDiameter)
                            .clipShape(Circle())
                            .opacity(track?.isPlaying == true ? 1 : 0.55)
                    } else {
                        DeckSymbol(name: track?.isPlaying == true ? "waveform" : DeckTool.nowPlaying.symbol,
                                   dimmed: track == nil)
                    }
                }
                if showsReading {
                    DeckReading(text: track.map { DeckLayout.clock($0.position(at: context.date)) } ?? "—",
                                dimmed: track?.isPlaying != true)
                }
            }
        }
    }
}

private struct ClipboardCell: View {
    let showsReading: Bool
    @ObservedObject private var monitor = ClipboardMonitor.shared

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            DeckRing(fraction: nil) {
                DeckSymbol(name: monitor.lastCopiedID == nil ? DeckTool.clipboard.symbol : "checkmark",
                           dimmed: monitor.items.isEmpty)
            }
            if showsReading {
                DeckReading(text: monitor.items.isEmpty ? "—" : "\(monitor.items.count)",
                            dimmed: monitor.items.isEmpty)
            }
        }
    }
}

private struct VaultCell: View {
    let showsReading: Bool
    @ObservedObject private var vault = VaultStore.shared

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            // Full and in the accent while a drag is over the notch: the
            // place to let go.
            DeckRing(fraction: vault.isDropTargeted ? 1 : nil) {
                DeckSymbol(name: vault.isDropTargeted ? "arrow.down.to.line"
                                 : (vault.items.isEmpty ? "tray" : "tray.full"),
                           dimmed: vault.items.isEmpty && !vault.isDropTargeted)
            }
            if showsReading {
                DeckReading(text: vault.items.isEmpty ? "—" : "\(vault.items.count)",
                            dimmed: vault.items.isEmpty)
            }
        }
    }
}

private struct MeetingCell: View {
    let showsReading: Bool
    @ObservedObject private var meetings = MeetingMonitor.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let next = meetings.next
            VStack(spacing: NotchLayout.ringLabelGap) {
                DeckRing(fraction: next?.fraction(at: context.date)) {
                    DeckSymbol(name: next?.joinURL != nil ? "video" : DeckTool.meeting.symbol,
                               dimmed: next == nil)
                }
                if showsReading {
                    DeckReading(text: MeetingMonitor.reading(for: next, now: context.date),
                                dimmed: next == nil)
                }
            }
        }
    }
}

private struct TransfersCell: View {
    let showsReading: Bool
    @ObservedObject private var transfers = TransferMonitor.shared

    var body: some View {
        let fraction = transfers.overallFraction
        VStack(spacing: NotchLayout.ringLabelGap) {
            DeckRing(fraction: fraction ?? (transfers.transfers.isEmpty ? 1 : nil)) {
                DeckSymbol(name: transfers.transfers.isEmpty ? "checkmark"
                                 : (transfers.transfers.contains(where: \.isAirDrop) ? "airplayaudio" : "arrow.down"),
                           dimmed: false)
            }
            if showsReading {
                DeckReading(text: reading(fraction))
            }
        }
    }

    private func reading(_ fraction: Double?) -> String {
        if transfers.transfers.isEmpty { return L10n.t("Done") }
        if let fraction { return "\(Int((fraction * 100).rounded(.down)))%" }
        let bytes = transfers.transfers.reduce(Int64(0)) { $0 + $1.completedBytes }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct TimerCell: View {
    let showsReading: Bool
    @ObservedObject private var timer = FocusTimer.shared

    /// A cup through a break, a pause sign while paused.
    private var symbol: String {
        if case .paused = timer.state { return "pause.fill" }
        return timer.phase.isBreak ? "cup.and.saucer.fill" : "timer"
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !timer.isRunning)) { context in
            VStack(spacing: NotchLayout.ringLabelGap) {
                DeckRing(fraction: timer.isIdle ? nil : timer.fractionRemaining(at: context.date)) {
                    DeckSymbol(name: symbol, dimmed: timer.isIdle)
                }
                if showsReading {
                    DeckReading(text: timer.isIdle ? L10n.t("\(Int(timer.phaseLength / 60))m")
                                                   : DeckLayout.clock(timer.remaining(at: context.date)),
                                dimmed: !timer.isRunning)
                }
            }
        }
    }
}
