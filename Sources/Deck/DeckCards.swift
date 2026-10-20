import SwiftUI

/// **A tool's card**, in the same shell as a provider's tooltip — same width,
/// same glass, same tail pointing back at the cell — at the tool's fixed height.
struct DeckCard: View {
    let tool: DeckTool
    var direction: NotchEdge.TooltipDirection = .leading
    var tailOffset: CGFloat = 0
    /// Where the pointer is, for the clipboard's preview of a long clip.
    var pointer: DeckPointer = DeckPointer()

    var body: some View {
        TooltipShell(height: tool.cardHeight, direction: direction, tailOffset: tailOffset) {
            ZStack(alignment: .topLeading) {
                Group {
                    switch tool {
                    case .nowPlaying: NowPlayingCard()
                    case .clipboard:  ClipboardCard(pointer: pointer)
                    case .timer:      FocusTimerCard()
                    }
                }
                .id(tool)
                .transition(.opacity.animation(NotchMotion.crossfade))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Pieces the cards share

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.cardTitle)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .frame(height: NotchLayout.cardTitleLineHeight)
    }
}

private struct CardNote: View {
    let text: String
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    var body: some View {
        Text(text)
            .font(Typography.cardBody)
            .foregroundStyle(secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain button drawn as a symbol, with a target bigger than its glyph.
private struct SymbolButton: View {
    let symbol: String
    var size: CGFloat = Design.px(34)
    var prominent = false
    var help: String = ""
    let action: () -> Void
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(prominent ? accentColor : Palette.textPrimary)
                .frame(width: size * 1.9, height: DeckLayout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A thin bar: a track and a fill, the fill in the accent colour.
private struct DeckBar: View {
    let fraction: Double
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                Capsule().fill(accentColor)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: DeckLayout.progressHeight)
    }
}

/// A capsule button with a label, the timer's and the clipboard's.
private struct PillButton: View {
    let title: String
    var selected = false
    var prominent = false
    let action: () -> Void
    @Environment(\.notchdeckAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.cardBody.weight(.semibold))
                .foregroundStyle(prominent ? accentColor : Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Design.px(22))
                .frame(maxWidth: .infinity, minHeight: DeckLayout.chipHeight)
                .background(
                    Capsule().fill(selected ? Palette.textPrimary.opacity(0.22) : Palette.barTrack)
                )
                .overlay {
                    // Legible in every accent: the colour carries the text and
                    // the rim, never a fill that white or black type sits on.
                    if prominent || selected {
                        Capsule().strokeBorder(prominent ? accentColor : Palette.textPrimary.opacity(0.35),
                                               lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Now Playing

private struct NowPlayingCard: View {
    @ObservedObject private var monitor = NowPlayingMonitor.shared
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        if let track = monitor.track {
            playing(track)
        } else {
            VStack(alignment: .leading, spacing: NotchLayout.headerToBlock) {
                CardTitle(text: DeckTool.nowPlaying.title)
                CardNote(text: monitor.isAvailable
                         ? L10n.t("Nothing is playing. Start something in Music, Spotify, a podcast app or a browser and it shows up here.")
                         : L10n.t("This Mac isn't sharing what's playing right now."))
            }
        }
    }

    private func playing(_ track: NowPlayingMonitor.Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.px(26)) {
                artwork
                VStack(alignment: .leading, spacing: Design.px(4)) {
                    Text(track.title)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let subtitle = track.subtitle {
                        Text(subtitle)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                    if let app = track.appName {
                        Text(app)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: DeckLayout.artworkSize)
            .contentShape(Rectangle())
            .onTapGesture { monitor.openPlayer() }
            .help(L10n.t("Open the app that's playing"))

            Spacer().frame(height: NotchLayout.blockSpacing)

            TimelineView(.animation(minimumInterval: 0.5, paused: !track.isPlaying)) { context in
                let position = track.position(at: context.date)
                VStack(spacing: NotchLayout.labelToBar) {
                    Scrubber(fraction: track.progress(at: context.date) ?? 0,
                             enabled: track.duration != nil && monitor.canSendCommands) { fraction in
                        if let duration = track.duration { monitor.seek(to: fraction * duration) }
                    }
                    HStack {
                        Text(DeckLayout.clock(position))
                        Spacer()
                        if let duration = track.duration {
                            Text("-" + DeckLayout.clock(duration - position))
                        }
                    }
                    .font(Typography.cardBody)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
                    .frame(height: NotchLayout.cardBodyLineHeight)
                }
            }

            Spacer().frame(height: NotchLayout.blockSpacing)

            HStack(spacing: Design.px(30)) {
                Spacer(minLength: 0)
                SymbolButton(symbol: "backward.fill", help: L10n.t("Previous")) { monitor.send(.previous) }
                SymbolButton(symbol: track.isPlaying ? "pause.fill" : "play.fill",
                             size: Design.px(46), prominent: true,
                             help: track.isPlaying ? L10n.t("Pause") : L10n.t("Play")) { monitor.send(.toggle) }
                SymbolButton(symbol: "forward.fill", help: L10n.t("Next")) { monitor.send(.next) }
                Spacer(minLength: 0)
            }
            .frame(height: DeckLayout.controlHeight)
            .disabled(!monitor.canSendCommands)
        }
    }

    @ViewBuilder private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: DeckLayout.artworkCorner, style: .continuous)
        if let image = monitor.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: DeckLayout.artworkSize, height: DeckLayout.artworkSize)
                .clipShape(shape)
        } else {
            shape.fill(Palette.barTrack)
                .frame(width: DeckLayout.artworkSize, height: DeckLayout.artworkSize)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: NotchLayout.glyphSize, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
        }
    }
}

/// The progress bar, which takes a click or a drag to move playback.
private struct Scrubber: View {
    let fraction: Double
    var enabled = true
    let onSeek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { proxy in
            DeckBar(fraction: dragging ?? fraction)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard enabled, proxy.size.width > 0 else { return }
                            dragging = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { value in
                            guard enabled, proxy.size.width > 0 else { return }
                            onSeek(min(max(value.location.x / proxy.size.width, 0), 1))
                            dragging = nil
                        }
                )
        }
        .frame(height: DeckLayout.progressHeight)
    }
}

// MARK: - Clipboard

private struct ClipboardCard: View {
    @ObservedObject private var monitor = ClipboardMonitor.shared
    @ObservedObject var pointer: DeckPointer

    var body: some View {
        let items = Array(monitor.ordered.prefix(DeckLayout.clipboardRows))
        list(items)
            // Laid out in the same pass as the rows, so the preview is never a
            // frame behind the pointer: the rows are at fixed heights, and the
            // card's place in the panel is read here rather than reported back.
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let origin = proxy.frame(in: .named(DeckPointer.space)).origin
                    if let location = pointer.location,
                       let peek = ClipPeekLayout(items: items,
                                                 pointer: CGPoint(x: location.x - origin.x,
                                                                  y: location.y - origin.y),
                                                 copiedID: monitor.lastCopiedID) {
                        ClipPeek(item: peek.item, size: peek.frame.size)
                            .offset(x: peek.frame.minX, y: peek.frame.minY)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: pointer.location == nil)
            }
    }

    private func list(_ items: [ClipboardMonitor.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CardTitle(text: DeckTool.clipboard.title)
                Spacer(minLength: 0)
                if monitor.items.contains(where: { !$0.pinned }) {
                    Button(L10n.t("Clear")) { monitor.clear() }
                        .buttonStyle(.plain)
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textSecondary)
                        .help(L10n.t("Forget every clip that isn't pinned"))
                }
            }
            Spacer().frame(height: NotchLayout.headerToBlock)
            if items.isEmpty {
                CardNote(text: monitor.isRunning
                         ? L10n.t("Copy something and it shows up here. Click a clip to copy it again.")
                         : L10n.t("Clipboard history is off. Turn it on in Settings → Deck."))
            } else {
                ForEach(items) { item in
                    ClipRow(item: item, copied: monitor.lastCopiedID == item.id,
                            onCopy: { monitor.copy(item) },
                            onPin: { monitor.togglePin(item) },
                            onRemove: { monitor.remove(item) })
                        .frame(height: DeckLayout.clipboardRowHeight)
                }
                // The rows a short history leaves empty say how to use it,
                // rather than standing there blank.
                if items.count < DeckLayout.clipboardRows - 1 {
                    Spacer().frame(height: NotchLayout.blockSpacing)
                    CardNote(text: L10n.t("Click a clip to copy it again. Hover a long one to read all of it."))
                }
            }
        }
    }
}

/// **Which clip the pointer is on, and where its preview goes**: the side of
/// the row with more room, over the rows there, inside the card. Only for a
/// clip the row cannot show whole — cut off, more than one line, several
/// files, or an image.
struct ClipPeekLayout {
    let item: ClipboardMonitor.Item
    let frame: CGRect

    /// Rows start under the title and are a fixed height, so the one under
    /// the pointer is arithmetic rather than measured.
    static var listTop: CGFloat { NotchLayout.cardTitleLineHeight + NotchLayout.headerToBlock }
    static var contentHeight: CGFloat { DeckLayout.clipboardHeight - 2 * NotchLayout.cardPadding }
    static let gap = Design.px(8)

    init?(items: [ClipboardMonitor.Item], pointer: CGPoint, copiedID: UUID?) {
        let width = NotchLayout.cardTextWidth
        guard pointer.x >= 0, pointer.x <= width, pointer.y >= Self.listTop else { return nil }
        let index = Int((pointer.y - Self.listTop) / DeckLayout.clipboardRowHeight)
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        guard Self.needsPeek(item, copied: copiedID == item.id) else { return nil }
        let rowTop = Self.listTop + CGFloat(index) * DeckLayout.clipboardRowHeight
        let rowBottom = rowTop + DeckLayout.clipboardRowHeight
        let above = rowTop - Self.gap
        let below = Self.contentHeight - rowBottom - Self.gap
        self.item = item
        self.frame = below >= above
            ? CGRect(x: 0, y: rowBottom + Self.gap, width: width, height: below)
            : CGRect(x: 0, y: 0, width: width, height: above)
    }

    /// Whether the row leaves part of the clip out.
    static func needsPeek(_ item: ClipboardMonitor.Item, copied: Bool = false) -> Bool {
        switch item.kind {
        case .image:
            return true
        case .file where item.fileURLs.count > 1:
            return true
        case .text where item.text.split(whereSeparator: \.isNewline).count > 1:
            return true
        default:
            let font = NotchLayout.cardBodyFont
            let natural = (item.preview as NSString).size(withAttributes: [.font: font]).width
            let age = copied ? L10n.t("Copied") : ClipRow.age(of: item.copiedAt, now: Date())
            let ageWidth = (age as NSString).size(withAttributes: [.font: font]).width
            return natural > ClipRow.textWidth(ageWidth: ageWidth) - 1
        }
    }
}

/// The whole clip, over the rows it does not belong to.
private struct ClipPeek: View {
    let item: ClipboardMonitor.Item
    let size: CGSize
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private static let base = Color(dark: .black, light: .white)
    private var padding: CGFloat { Design.px(18) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.px(6)) {
            content
            Spacer(minLength: 0)
            Text(summary)
                .font(Typography.cardBody)
                .foregroundStyle(secondaryInk)
                .lineLimit(1)
        }
        .padding(padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Opaque underneath, so the rows it covers never read through it on
        // a glass card, with a shade lifted off the card so it reads as on top.
        .background {
            let shape = RoundedRectangle(cornerRadius: Design.px(26), style: .continuous)
            ZStack {
                shape.fill(Self.base)
                shape.fill(Palette.barTrack)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Design.px(26), style: .continuous)
            .strokeBorder(Palette.ringTrack, lineWidth: 1))
    }

    /// As many lines as the space holds, the summary line kept.
    private var lines: Int {
        let room = size.height - 2 * padding - NotchLayout.cardBodyLineHeight - Design.px(6)
        return max(1, Int(room / NotchLayout.cardBodyLineHeight))
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image, let data = item.image, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Design.px(10), style: .continuous))
        } else {
            Text(item.kind == .file ? item.fileURLs.map(\.path).joined(separator: "\n") : item.text)
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        switch item.kind {
        case .image:
            if let data = item.image, let rep = NSBitmapImageRep(data: data) {
                return L10n.t("Image, \(rep.pixelsWide) × \(rep.pixelsHigh) — click to copy")
            }
            return L10n.t("Image — click to copy")
        case .file:
            return L10n.t("\(item.fileURLs.count) files — click to copy")
        case .text, .link:
            let lines = item.text.split(whereSeparator: \.isNewline).count
            return lines > 1
                ? L10n.t("\(item.text.count) characters, \(lines) lines — click to copy")
                : L10n.t("\(item.text.count) characters — click to copy")
        }
    }
}

private struct ClipRow: View {
    let item: ClipboardMonitor.Item
    let copied: Bool
    let onCopy: () -> Void
    let onPin: () -> Void
    let onRemove: () -> Void
    @Environment(\.notchdeckAccentColor) private var accentColor
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        HStack(spacing: Self.spacing) {
            icon
                .frame(width: Self.iconWidth)
            Text(item.preview)
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Self.spacerMinimum)
            if copied {
                Text(L10n.t("Copied"))
                    .font(Typography.cardBody.weight(.semibold))
                    .foregroundStyle(accentColor)
            } else {
                Text(Self.age(of: item.copiedAt, now: Date()))
                    .font(Typography.cardBody)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
            }
            Button(action: onPin) {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(item.pinned ? accentColor : secondaryInk)
                    .frame(width: Self.pinWidth, height: DeckLayout.clipboardRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.pinned ? L10n.t("Unpin") : L10n.t("Pin"))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .foregroundStyle(secondaryInk)
                    .frame(width: Self.removeWidth, height: DeckLayout.clipboardRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("Remove"))
        }
        .font(Typography.cardBody)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
    }

    @ViewBuilder private var icon: some View {
        if item.kind == .image, let data = item.image, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Design.px(34), height: Design.px(34))
                .clipShape(RoundedRectangle(cornerRadius: Design.px(6), style: .continuous))
        } else {
            Image(systemName: item.symbol)
                .foregroundStyle(secondaryInk)
        }
    }

    static let iconWidth = Design.px(34)
    static let pinWidth = Design.px(34)
    static let removeWidth = Design.px(30)
    static let spacing = Design.px(14)
    static let spacerMinimum = Design.px(8)

    /// What the row leaves its text, beside the icon, the age and two buttons:
    /// six pieces in the row, so five gaps, and the spacer's own minimum.
    static func textWidth(ageWidth: CGFloat) -> CGFloat {
        NotchLayout.cardTextWidth - iconWidth - pinWidth - removeWidth - ageWidth
            - 5 * spacing - spacerMinimum
    }

    /// "now", "4m", "2h", "3d".
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L10n.t("now")
        case ..<3600: return L10n.t("\(Int(seconds / 60))m")
        case ..<86_400: return L10n.t("\(Int(seconds / 3600))h")
        default: return L10n.t("\(Int(seconds / 86_400))d")
        }
    }
}

// MARK: - Focus timer

private struct FocusTimerCard: View {
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(text: DeckTool.timer.title)
            Spacer().frame(height: NotchLayout.headerToBlock)

            TimelineView(.animation(minimumInterval: 0.25, paused: !timer.isRunning)) { context in
                VStack(alignment: .leading, spacing: NotchLayout.labelToBar) {
                    Text(DeckLayout.clock(timer.remaining(at: context.date)))
                        .font(Font(DeckLayout.timerDigitsFont as CTFont))
                        .foregroundStyle(timer.isRunning ? Palette.textPrimary : Palette.textSecondary)
                        .frame(height: DeckLayout.timerDigitsHeight)
                        .contentTransition(.numericText())
                    DeckBar(fraction: timer.fractionRemaining(at: context.date))
                }
            }

            Spacer().frame(height: NotchLayout.blockSpacing)

            HStack(spacing: Design.px(12)) {
                ForEach(FocusTimer.presets, id: \.self) { minutes in
                    PillButton(title: L10n.t("\(minutes)m"), selected: timer.minutes == minutes) {
                        timer.setMinutes(minutes)
                    }
                }
            }
            .frame(height: DeckLayout.chipHeight)

            Spacer().frame(height: NotchLayout.blockSpacing)

            HStack(spacing: Design.px(16)) {
                PillButton(title: startTitle, prominent: true) { timer.toggle() }
                PillButton(title: L10n.t("Reset")) { timer.reset() }
                    .disabled(timer.isIdle)
                    .opacity(timer.isIdle ? 0.5 : 1)
            }
            .frame(height: DeckLayout.controlHeight)
        }
    }

    private var startTitle: String {
        switch timer.state {
        case .idle: return L10n.t("Start")
        case .running: return L10n.t("Pause")
        case .paused: return L10n.t("Resume")
        }
    }
}
