import Foundation

/// Saves settings and the current script as plain files in one folder
/// (by default ~/Library/Application Support/MacTele).
public struct Store: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Store(directory: base.appendingPathComponent("MacTele", isDirectory: true))
    }

    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    var scriptURL: URL { directory.appendingPathComponent("script.md") }

    public func loadSettings() -> PrompterSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(PrompterSettings.self, from: data) else { return PrompterSettings() }
        return s
    }

    public func save(_ settings: PrompterSettings) throws {
        try ensureDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// nil when no script has been saved yet (first launch).
    public func loadScript() -> String? { try? String(contentsOf: scriptURL, encoding: .utf8) }

    public func saveScript(_ text: String) throws {
        try ensureDirectory()
        try text.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
