import Foundation

public struct ScriptInfo: Identifiable, Equatable, Sendable {
    /// The file name without ".md"; also the title shown in the list.
    public let id: String
    public var modified: Date
    public var title: String { id }
}

/// Scripts saved as Markdown files in one folder (by default
/// ~/Library/Application Support/MacTele/Scripts), so they can also be opened in any text editor.
public struct ScriptLibrary: Sendable {
    public let directory: URL
    /// Deleting moves files to the Trash (recoverable). Tests turn this off.
    public var useTrash = true

    public init(directory: URL) { self.directory = directory }

    /// Newest first.
    public func list() -> [ScriptInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "md" }.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ScriptInfo(id: url.deletingPathExtension().lastPathComponent, modified: date)
        }
        .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id }
    }

    public func contains(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    public func load(_ id: String) -> String? { try? String(contentsOf: url(id), encoding: .utf8) }

    public func save(_ id: String, text: String) throws {
        try ensureDirectory()
        try text.write(to: url(id), atomically: true, encoding: .utf8)
    }

    /// Creates a script with a unique title ("Untitled", "Untitled 2", …).
    @discardableResult
    public func create(title: String, text: String) throws -> ScriptInfo {
        try ensureDirectory()
        let id = uniqueID(for: title)
        try text.write(to: url(id), atomically: true, encoding: .utf8)
        return ScriptInfo(id: id, modified: Date())
    }

    /// Renames a script; returns its new id (unchanged if the title is the same or empty).
    public func rename(_ id: String, to title: String) throws -> String {
        let clean = Self.cleanTitle(title)
        guard clean != id, !clean.isEmpty, contains(id) else { return id }
        let newID = uniqueID(for: clean)
        try FileManager.default.moveItem(at: url(id), to: url(newID))
        return newID
    }

    public func delete(_ id: String) throws {
        guard contains(id) else { return }
        if useTrash {
            try FileManager.default.trashItem(at: url(id), resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url(id))
        }
    }

    /// File names can't contain "/" or ":", and shouldn't start with "." or be absurdly long.
    public static func cleanTitle(_ title: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    func uniqueID(for title: String) -> String {
        let base = Self.cleanTitle(title).isEmpty ? "Untitled" : Self.cleanTitle(title)
        var candidate = base
        var n = 2
        while contains(candidate) { candidate = "\(base) \(n)"; n += 1 }
        return candidate
    }

    func url(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("md") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

extension Store {
    public var library: ScriptLibrary { ScriptLibrary(directory: directory.appendingPathComponent("Scripts", isDirectory: true)) }

    /// One-time move from the single `script.md` of earlier versions into the library.
    /// The built-in welcome text (any version) is replaced by the current one; anything you wrote is kept
    /// as "My Script". Returns the id of the script to open.
    @discardableResult
    public func migrateToLibrary(welcomeText: String) throws -> String {
        let lib = library
        if let first = lib.list().first { return first.id }
        var current = try lib.create(title: "Welcome", text: welcomeText).id
        if let old = loadScript(), !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !old.hasPrefix("Welcome to Notch Prompter.") {
            current = try lib.create(title: "My Script", text: old).id
        }
        return current
    }
}
