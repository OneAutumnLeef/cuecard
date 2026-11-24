import Foundation

/// Commands other apps (Shortcuts, scripts, Claude via the `prompter` tool) can send with a
/// `notchprompter://` link:
///
///     notchprompter://add?title=Pitch&text=Hello%20there[&start=1]
///     notchprompter://add?title=Pitch&inbox=4F2A.md[&start=1]      (file placed in the app's Inbox folder)
///     notchprompter://open?title=Pitch[&start=1]
///     notchprompter://start | pause | toggle | show | hide | restart
///     notchprompter://mode?voice=1   (or voice=0 for fixed speed)
public enum URLCommand: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case text(String), inbox(String) }

    case add(title: String, source: Source, start: Bool)
    case open(title: String, start: Bool)
    case play, pause, toggle, show, hide, restart
    case mode(voice: Bool)

    public static let scheme = "notchprompter"

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (comps.host ?? comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }
        let start = ["1", "true", "yes"].contains(q["start"]?.lowercased() ?? "")
        switch action {
        case "add":
            let title = q["title"].map(ScriptLibrary.cleanTitle) ?? ""
            if let text = q["text"], !text.isEmpty {
                return .add(title: title.isEmpty ? "Untitled" : title, source: .text(text), start: start)
            }
            if let name = q["inbox"], isSafeInboxName(name) {
                return .add(title: title.isEmpty ? "Untitled" : title, source: .inbox(name), start: start)
            }
            return nil
        case "open":
            guard let title = q["title"], !title.isEmpty else { return nil }
            return .open(title: title, start: start)
        case "start", "play": return .play
        case "pause", "stop": return .pause
        case "toggle": return .toggle
        case "show": return .show
        case "hide": return .hide
        case "restart": return .restart
        case "mode":
            guard let v = q["voice"]?.lowercased() else { return nil }
            return .mode(voice: ["1", "true", "yes", "on"].contains(v))
        default: return nil
        }
    }

    /// Inbox files must be a plain name in the Inbox folder, never a path elsewhere.
    static func isSafeInboxName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
            && (name.hasSuffix(".md") || name.hasSuffix(".txt"))
    }
}

/// Extracts speaker notes from an unzipped PowerPoint file, in slide order, as a script with a
/// `[Slide N]` stage note before each slide's notes. Slides without notes are left out.
public enum PptxNotes {
    public static func extract(fromUnzipped root: URL) throws -> String {
        let ppt = root.appendingPathComponent("ppt")
        let presentation = try Data(contentsOf: ppt.appendingPathComponent("presentation.xml"))
        let slideRIDs = XMLScan.attributeValues(in: presentation, element: "p:sldId", attribute: "r:id")
        let presRels = try relationships(ppt.appendingPathComponent("_rels/presentation.xml.rels"))
        var parts: [String] = []
        for (n, rid) in slideRIDs.enumerated() {
            guard let slideTarget = presRels[rid]?.target else { continue }
            let slideURL = ppt.appendingPathComponent(slideTarget).standardizedFileURL
            let relsURL = slideURL.deletingLastPathComponent()
                .appendingPathComponent("_rels/\(slideURL.lastPathComponent).rels")
            guard let rels = try? relationships(relsURL),
                  let notes = rels.values.first(where: { $0.type.hasSuffix("/notesSlide") }) else { continue }
            let notesURL = slideURL.deletingLastPathComponent().appendingPathComponent(notes.target).standardizedFileURL
            guard let data = try? Data(contentsOf: notesURL) else { continue }
            let text = NotesBodyParser.paragraphs(in: data)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !text.isEmpty { parts.append("[Slide \(n + 1)]\n\(text)") }
        }
        return parts.joined(separator: "\n\n")
    }

    struct Rel { let type: String; let target: String }

    static func relationships(_ url: URL) throws -> [String: Rel] {
        let data = try Data(contentsOf: url)
        var out: [String: Rel] = [:]
        for attrs in XMLScan.elements(in: data, named: "Relationship") {
            if let id = attrs["Id"], let target = attrs["Target"] {
                out[id] = Rel(type: attrs["Type"] ?? "", target: target)
            }
        }
        return out
    }
}

/// Collects the attributes of every element with a given name.
final class XMLScan: NSObject, XMLParserDelegate {
    private let name: String
    private var found: [[String: String]] = []

    private init(name: String) { self.name = name }

    static func elements(in data: Data, named name: String) -> [[String: String]] {
        let scan = XMLScan(name: name)
        let parser = XMLParser(data: data)
        parser.delegate = scan
        parser.parse()
        return scan.found
    }

    static func attributeValues(in data: Data, element: String, attribute: String) -> [String] {
        elements(in: data, named: element).compactMap { $0[attribute] }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName == name { found.append(attributes) }
    }
}

/// Reads the paragraphs of the notes body placeholder (not the slide image or slide number).
final class NotesBodyParser: NSObject, XMLParserDelegate {
    private var inShape = false, isBody = false, inText = false
    private var shapeParagraphs: [String] = []
    private var paragraph = ""
    private var result: [String] = []

    static func paragraphs(in data: Data) -> [String] {
        let p = NotesBodyParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.result
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch e {
        case "p:sp": inShape = true; isBody = false; shapeParagraphs = []
        case "p:ph" where inShape: if a["type"] == "body" { isBody = true }
        case "a:p": paragraph = ""
        case "a:t": inText = true
        case "a:br": paragraph += " "
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { if inText { paragraph += s } }

    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch e {
        case "a:t": inText = false
        case "a:p": if inShape { shapeParagraphs.append(paragraph) }
        case "p:sp":
            if isBody { result.append(contentsOf: shapeParagraphs) }
            inShape = false
        default: break
        }
    }
}
