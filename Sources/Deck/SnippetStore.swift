import Combine
import Foundation
import SwiftUI

/// **Snippets**: text you paste again and again — an address, a sign-off, a
/// command — saved for good, apart from the clipboard history that ages out.
/// The clipboard card lists them under Snippets; a click copies one.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    struct Snippet: Identifiable, Equatable, Codable {
        var id = UUID()
        /// Optional; the card shows the text's first line without one.
        var title: String
        var text: String

        var label: String {
            let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !named.isEmpty { return named }
            return text.split(whereSeparator: \.isNewline).first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? text
        }
    }

    @Published private(set) var snippets: [Snippet] = []

    private let storeURL: URL?

    init(storeURL: URL? = SnippetStore.defaultStoreURL) {
        self.storeURL = storeURL
        load()
    }

    nonisolated static var defaultStoreURL: URL? {
        VaultStore.supportFolder?.appendingPathComponent("snippets.json")
    }

    /// Saves text as a snippet; the same text twice is kept once.
    @discardableResult
    func add(text: String, title: String = "") -> Snippet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = snippets.first(where: { $0.text == text }) { return existing }
        let snippet = Snippet(title: title, text: text)
        snippets.insert(snippet, at: 0)
        save()
        return snippet
    }

    func contains(text: String) -> Bool {
        snippets.contains { $0.text == text }
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Snippets matching every word of the query, in the title or the text.
    static func filter(_ snippets: [Snippet], query: String) -> [Snippet] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return snippets }
        return snippets.filter { snippet in
            let haystack = (snippet.title + " " + snippet.text).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Fixed snippets, never saved: demo mode's, and the tests'.
    func showDemo(_ demo: [Snippet]) {
        snippets = demo
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        snippets = saved
    }

    private func save() {
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(snippets).write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            Log.usage.error("snippets not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
