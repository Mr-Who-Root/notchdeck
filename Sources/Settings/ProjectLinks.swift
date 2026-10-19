import Foundation

/// Where NotchDeck is published: the GitHub repository named by the
/// `NOTCHDECK_REPOSITORY` build setting, for the links in Settings → General.
/// A build without one shows no links rather than pointing somewhere else.
enum ProjectLinks {
    static var repository: String? {
        repository(from: Bundle.main.object(forInfoDictionaryKey: "NotchDeckRepository") as? String)
    }

    /// Pure, for the tests: `owner/name`, or nil for anything else — an
    /// unexpanded `$(…)` included.
    static func repository(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        return raw
    }

    static var repositoryURL: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// The release page for this version, where its notes and downloads are.
    static func releaseURL(version: String) -> URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases/tag/v\(version)") }
    }

    static var releasesURL: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases") }
    }
}
