import AppKit
import SwiftUI

/// **The vault's card**: the files it holds, each one dragged out of the card
/// to copy it anywhere, and a drop zone for more.
struct VaultCard: View {
    @ObservedObject private var vault = VaultStore.shared
    @Environment(\.notchdeckHeadlessGlass) private var headless
    @Environment(\.deckAction) private var deckAction
    @Environment(\.notchdeckAccentColor) private var accentColor
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @State private var shareFrame: CGRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: NotchLayout.cardTitleLineHeight)
            Spacer().frame(height: NotchLayout.headerToBlock)
            if vault.items.isEmpty || vault.isDropTargeted {
                DropZone(targeted: vault.isDropTargeted, holding: vault.items.count)
                    .frame(height: CGFloat(DeckLayout.vaultRows) * DeckLayout.vaultRowHeight
                           + NotchLayout.blockSpacing + DeckLayout.chipHeight)
            } else {
                list
                Spacer(minLength: 0)
                footer
                    .frame(height: DeckLayout.chipHeight)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { if !headless { vault.refresh() } }
    }

    private var header: some View {
        HStack(spacing: Design.px(14)) {
            CardTitle(text: DeckTool.vault.title)
            if !vault.items.isEmpty {
                Text("\(vault.items.count)")
                    .font(Typography.cardBody.weight(.semibold))
                    .foregroundStyle(secondaryInk)
            }
            Spacer(minLength: 0)
            if !vault.items.isEmpty {
                headerButton("square.and.arrow.up", help: L10n.t("Share all — AirDrop, Messages, Mail…")) {
                    deckAction(.share(vault.urls()), shareFrame)
                }
                .panelFrame($shareFrame)
                headerButton(vault.isZipping ? "hourglass" : "doc.zipper", help: L10n.t("Zip everything into one archive")) {
                    vault.zip()
                }
                .disabled(vault.isZipping)
                Button(L10n.t("Clear")) { vault.clear() }
                    .buttonStyle(.plain)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .help(L10n.t("Empty the vault. Files it only points to stay where they are."))
            }
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Design.px(26), weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: Design.px(40), height: NotchLayout.cardTitleLineHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The rows; past what the card has room for, they scroll.
    @ViewBuilder private var list: some View {
        let rows = VStack(spacing: 0) {
            ForEach(vault.items) { item in
                VaultRow(item: item, missing: vault.missing.contains(item.id))
                    .frame(height: DeckLayout.vaultRowHeight)
            }
        }
        Group {
            if vault.items.count > DeckLayout.vaultRows {
                ScrollView(.vertical, showsIndicators: true) { rows }
            } else {
                rows
            }
        }
        .frame(height: CGFloat(DeckLayout.vaultRows) * DeckLayout.vaultRowHeight, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: Design.px(12)) {
            if vault.urls().count > 1 {
                // The whole shelf at once, picked up by this pill.
                HStack(spacing: Design.px(8)) {
                    Image(systemName: "square.stack.3d.down.right")
                    Text(L10n.t("Drag all \(vault.urls().count)"))
                        .lineLimit(1)
                }
                .font(Typography.cardBody.weight(.semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, Design.px(22))
                .frame(maxHeight: .infinity)
                .background(Capsule().strokeBorder(accentColor, lineWidth: 1))
                .overlay { if !headless { FileDragArea(ids: { vault.items.map(\.id) }) } }
                .help(L10n.t("Drag every file out at once"))
            }
            Text(L10n.t("Drag a file out to copy it. Hold ⌘ to move it."))
                .font(Typography.cardBody)
                .foregroundStyle(secondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One file: drag it out, double-click to open it.
private struct VaultRow: View {
    let item: VaultStore.Item
    let missing: Bool
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    /// `ImageRenderer` draws an AppKit view as a placeholder, so the render
    /// tests leave the drag handle out — it has no pixels of its own.
    @Environment(\.notchdeckHeadlessGlass) private var headless

    var body: some View {
        HStack(spacing: Design.px(14)) {
            // Icon, name and size are the handle: the drag view sits over
            // them, so a press anywhere there picks the file up.
            HStack(spacing: Design.px(14)) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: missing ? "/" : item.path))
                    .resizable()
                    .frame(width: Design.px(40), height: Design.px(40))
                    .opacity(missing ? 0.35 : 1)
                Text(item.name)
                    .font(Typography.cardBody)
                    .foregroundStyle(missing ? secondaryInk : Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Design.px(8))
                Text(detail)
                    .font(Typography.cardBody)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
            }
            .overlay {
                if !headless {
                    FileDragArea(ids: { [item.id] }, onDoubleClick: { VaultStore.shared.open(item) },
                                 toolTip: missing ? L10n.t("This file isn't where it was.")
                                                  : item.path + "\n" + L10n.t("Drag out to copy · ⌘-drag to move · double-click to open"))
                }
            }
            rowButton("magnifyingglass", help: L10n.t("Show in Finder")) { VaultStore.shared.reveal(item) }
                .disabled(missing)
            rowButton("xmark", help: item.owned ? L10n.t("Remove (deletes the vault's copy)")
                                                : L10n.t("Remove (the file stays where it is)")) {
                VaultStore.shared.remove(item)
            }
        }
    }

    private var detail: String {
        if missing { return L10n.t("Missing") }
        if item.isDirectory { return L10n.t("Folder") }
        guard let size = item.size else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(secondaryInk)
                .frame(width: Design.px(32), height: DeckLayout.vaultRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Where to let go — dashed, and in the accent while a drag is over it.
private struct DropZone: View {
    let targeted: Bool
    let holding: Int
    @Environment(\.notchdeckAccentColor) private var accentColor
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        VStack(spacing: Design.px(14)) {
            Image(systemName: targeted ? "arrow.down.to.line" : "tray.and.arrow.down")
                .font(.system(size: Design.px(52), weight: .semibold))
                .foregroundStyle(targeted ? accentColor : secondaryInk)
                .symbolEffect(.bounce, value: targeted)
            Text(targeted ? L10n.t("Drop to keep it here") : L10n.t("Drop files here to hold them"))
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(targeted && holding > 0
                 ? L10n.t("The vault holds \(holding) already.")
                 : L10n.t("Then drag them out to copy them anywhere — hold ⌘ to move. Text, links and images work too."))
                .font(Typography.cardBody)
                .foregroundStyle(secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Design.px(20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Design.px(26), style: .continuous)
                .fill(targeted ? accentColor.opacity(0.12) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Design.px(26), style: .continuous)
                .strokeBorder(targeted ? accentColor : Palette.ringTrack,
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [Design.px(14), Design.px(10)]))
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}
