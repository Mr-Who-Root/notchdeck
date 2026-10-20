import Foundation

/// **Apple Shortcuts, from the focus timer.** macOS gives apps no way to turn
/// Do Not Disturb on or off, but a Shortcut with the Set Focus action can, and
/// `/usr/bin/shortcuts` runs one by name. So the timer runs one as focus
/// starts and another as it stops — whichever the person picked in Settings.
enum ShortcutsRunner {
    static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Runs the Shortcut in the background; an empty name runs nothing.
    static func run(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never from a test run, which is hosted by the app and shares its
        // settings: it would switch the person's Do Not Disturb.
        guard !name.isEmpty, !Runtime.isUnderTest, FileManager.default.isExecutableFile(atPath: tool.path)
        else { return }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.usage.error("shortcut \(name, privacy: .public) did not run: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every Shortcut on this Mac, by name, for the Settings picker.
    static func list() async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { return [] }
            let process = Process()
            let output = Pipe()
            process.executableURL = tool
            process.arguments = ["list"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// One name per line, sorted, without blanks or duplicates.
    static func parse(_ text: String) -> [String] {
        Array(Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
