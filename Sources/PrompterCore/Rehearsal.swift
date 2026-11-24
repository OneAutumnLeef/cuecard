import Foundation

/// What a voice run-through looked like: pace, pauses, filler words, and what was skipped or re-read.
public struct RehearsalReport: Codable, Equatable, Sendable {
    public struct PacePoint: Codable, Equatable, Sendable { public var t: Double; public var wpm: Double }
    public struct Pause: Codable, Equatable, Sendable { public var t: Double; public var seconds: Double; public var word: Int }
    public struct Section: Codable, Equatable, Sendable { public var from: Int; public var to: Int; public var excerpt: String }

    public var scriptTitle: String
    public var date: Date
    public var duration: Double
    public var speakingTime: Double
    public var scriptWords: Int
    public var wordsCovered: Int
    public var averageWPM: Double
    public var pace: [PacePoint]
    public var pauses: [Pause]
    public var fillers: [String: Int]
    public var skipped: [Section]
    public var reread: [Section]
    public var finished: Bool

    public var coverage: Double { scriptWords > 0 ? Double(wordsCovered) / Double(scriptWords) : 0 }
    public var fillerCount: Int { fillers.values.reduce(0, +) }
    public var longestPause: Double { pauses.map(\.seconds).max() ?? 0 }
}

/// Collects a voice session as it happens and turns it into a `RehearsalReport`.
/// Fed with the tracker's confirmed position (about 20 times a second) and the settled transcript.
public struct RehearsalRecorder: Sendable {
    public let script: SpokenScript
    private var samples: [(t: Double, pos: Int, speaking: Bool)] = []
    private var finals: [String] = []

    /// Filler words always counted, and words that count as filler only beyond their uses in the script.
    static let alwaysFiller: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "hmm", "mm", "ah"]
    static let maybeFiller = ["basically", "actually", "literally", "you know", "i mean", "sort of", "kind of"]

    public init(script: SpokenScript) { self.script = script }

    public var isEmpty: Bool { samples.isEmpty }

    public mutating func sample(t: Double, confirmed: Double, speaking: Bool) {
        samples.append((t, Int(confirmed), speaking))
    }

    public mutating func heard(final text: String) { finals.append(text) }

    /// nil if too little happened to be worth a report (under 8 s of speech or 10 words of progress).
    public func report(title: String, date: Date = Date()) -> RehearsalReport? {
        guard let firstVoice = samples.firstIndex(where: \.speaking),
              let lastVoice = samples.lastIndex(where: \.speaking) else { return nil }
        // Run to the end of the samples: the last words are confirmed after you stop talking (recognition lag).
        let span = Array(samples[firstVoice...])
        let start = span[0].t
        var speaking = 0.0, advanced = 0
        var speakingSinceMove = 0.0          // talking time since the position last moved
        var skipped: [RehearsalReport.Section] = [], reread: [RehearsalReport.Section] = []
        var pauses: [RehearsalReport.Pause] = []
        var silenceStart: Double?
        var bucket = (start: start, words: 0, speak: 0.0)
        var pace: [RehearsalReport.PacePoint] = []
        for i in 1..<max(span.count, 1) {
            let a = span[i - 1], b = span[i]
            let dt = b.t - a.t
            if a.speaking { speaking += dt; bucket.speak += dt; speakingSinceMove += dt }
            let d = b.pos - a.pos
            // A big forward jump is a skip only if it's more than you could have said since the last move;
            // otherwise the tracker is just catching up after misheard words.
            let rate = speaking > 3 ? max(Double(advanced) / speaking, 1.5) : 2.5
            let couldHaveSaid = Int((rate * speakingSinceMove * 1.4).rounded()) + 4
            if d > 8 && d > couldHaveSaid {
                skipped.append(.init(from: a.pos + 1, to: b.pos - 1, excerpt: excerpt(a.pos + 1, b.pos - 1)))
            } else if d < -2 {
                reread.append(.init(from: b.pos, to: a.pos, excerpt: excerpt(b.pos, a.pos)))
            } else if d > 0 {
                advanced += d
                bucket.words += d
            }
            if d != 0 { speakingSinceMove = 0 }
            // Pauses: silences of 1.5 s or more between your first and last words.
            if !b.speaking, silenceStart == nil { silenceStart = b.t }
            if b.speaking, let s = silenceStart {
                if b.t - s >= 1.5 { pauses.append(.init(t: s - start, seconds: b.t - s, word: b.pos)) }
                silenceStart = nil
            }
            if b.t - bucket.start >= 5 {
                if bucket.speak >= 2 {
                    pace.append(.init(t: (bucket.start + b.t) / 2 - start, wpm: Double(bucket.words) / bucket.speak * 60))
                }
                bucket = (b.t, 0, 0)
            }
        }
        let maxPos = span.map(\.pos).max() ?? 0
        let skippedWords = skipped.reduce(0) { $0 + max($1.to - $1.from + 1, 0) }
        guard speaking >= 8, advanced >= 10 else { return nil }
        let covered = min(max(maxPos + 1 - skippedWords, 0), script.count)
        return RehearsalReport(
            scriptTitle: title, date: date,
            duration: samples[lastVoice].t - start, speakingTime: speaking,
            scriptWords: script.count, wordsCovered: covered,
            averageWPM: Double(advanced) / speaking * 60,
            pace: pace, pauses: pauses, fillers: fillerCounts(),
            skipped: skipped, reread: reread,
            finished: maxPos >= script.count - 3)
    }

    private func excerpt(_ from: Int, _ to: Int) -> String {
        guard from <= to, from >= 0, to < script.count else { return "" }
        let words = script.words[from...to]
        return words.count <= 12 ? words.joined(separator: " ")
            : (words.prefix(6) + ["…"] + words.suffix(4)).joined(separator: " ")
    }

    func fillerCounts() -> [String: Int] {
        let heard = finals.flatMap { $0.split(whereSeparator: \.isWhitespace).flatMap { SpokenForm.words(String($0)) } }
        var out: [String: Int] = [:]
        for w in heard where Self.alwaysFiller.contains(w) { out[w, default: 0] += 1 }
        for phrase in Self.maybeFiller {
            let words = phrase.split(separator: " ").map(String.init)
            let extra = occurrences(of: words, in: heard) - occurrences(of: words, in: script.words)
            if extra > 0 { out[phrase] = extra }
        }
        return out
    }

    /// Counts a word sequence in a word list (every position, so repeats like "actually actually" both count).
    private func occurrences(of needle: [String], in hay: [String]) -> Int {
        guard !needle.isEmpty, hay.count >= needle.count else { return 0 }
        return (0...(hay.count - needle.count)).filter { Array(hay[$0..<($0 + needle.count)]) == needle }.count
    }
}

/// Saved reports, one JSON file each, in ~/Library/Application Support/MacTele/Rehearsals.
public struct RehearsalStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func save(_ r: RehearsalReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(ScriptLibrary.cleanTitle(r.scriptTitle)) \(f.string(from: r.date)).json"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Newest first; optionally only one script's reports.
    public func all(script title: String? = nil) -> [RehearsalReport] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(RehearsalReport.self, from: Data(contentsOf: $0)) }
            .filter { title == nil || $0.scriptTitle == title }
            .sorted { $0.date > $1.date }
    }
}

extension Store {
    public var rehearsals: RehearsalStore {
        RehearsalStore(directory: directory.appendingPathComponent("Rehearsals", isDirectory: true))
    }
}
