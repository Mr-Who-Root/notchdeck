import AppKit
import SwiftUI

/// Whether NotchDeck may read the calendars, and the button that asks.
struct MeetingAccessRow: View {
    @ObservedObject private var meetings = MeetingMonitor.shared

    var body: some View {
        HStack {
            switch meetings.access {
            case .granted:
                Label(L10n.t("Calendar access allowed"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .denied:
                Label(L10n.t("Calendar access is off"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("Open Privacy Settings")) { meetings.openPrivacySettings() }
            case .unknown:
                Text(L10n.t("NotchDeck needs to read your calendars."))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("Allow Calendar Access")) { meetings.requestAccess() }
            }
        }
    }
}

/// Snippets: add, edit, delete. The clipboard card lists them; the ☆ on a
/// clip adds one too.
struct SnippetsEditor: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var editing: SnippetStore.Snippet.ID?
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        if store.snippets.isEmpty {
            Text(L10n.t("No snippets yet. Add text you paste often — an address, a sign-off, a command — or click ☆ on a clip in the notch."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(store.snippets) { snippet in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.label).lineLimit(1)
                    if !snippet.title.isEmpty {
                        Text(snippet.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(L10n.t("Edit")) {
                    editing = snippet.id
                    title = snippet.title
                    text = snippet.text
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    store.remove(snippet)
                    if editing == snippet.id { cancel() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("Delete snippet"))
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.t("Title (optional)"), text: $title)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 110)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L10n.t("Snippet text"))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            HStack {
                Spacer()
                if editing != nil {
                    Button(L10n.t("Cancel"), action: cancel)
                }
                Button(editing == nil ? L10n.t("Add Snippet") : L10n.t("Save Snippet"), action: commit)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func commit() {
        if let id = editing, var snippet = store.snippets.first(where: { $0.id == id }) {
            snippet.title = title
            snippet.text = text
            store.update(snippet)
        } else {
            store.add(text: text, title: title)
        }
        cancel()
    }

    private func cancel() {
        editing = nil
        title = ""
        text = ""
    }
}

/// The Shortcuts run as focus starts and stops — the way to Do Not Disturb.
struct FocusShortcutsRows: View {
    @ObservedObject var preferences: Preferences
    @State private var shortcuts: [String] = []
    @State private var loaded = false

    var body: some View {
        Group {
            picker(L10n.t("When focus starts, run"), selection: $preferences.focusStartShortcut)
            picker(L10n.t("When focus stops, run"), selection: $preferences.focusEndShortcut)
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("macOS doesn't let apps switch Do Not Disturb, but a Shortcut can: make one with the Set Focus action (Do Not Disturb, Turn On) and another to turn it off, then pick them here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.t("Open Shortcuts")) {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            shortcuts = await ShortcutsRunner.list()
            loaded = true
        }
    }

    private func picker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(L10n.t("Nothing")).tag("")
            // The one chosen, even if it has since been renamed or deleted.
            if !selection.wrappedValue.isEmpty, !shortcuts.contains(selection.wrappedValue) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
        }
    }
}
