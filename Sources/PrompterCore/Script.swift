import Foundation

/// How long a speaker naturally pauses after a token.
public enum TrailingPause: Int, Sendable, Comparable {
    case none, clause, sentence, paragraph
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One displayed unit of the script: a spoken word, or a bracketed stage note like `[PAUSE]` or `[smile]`.
public struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case word, cue }

    public var text: String
    public var kind: Kind
    /// First token of a line in the source text; it always starts a new display line.
    public var paragraphStart: Bool
    /// First word of a sentence; used for back / forward navigation.
    public var sentenceStart: Bool
    public var trailingPause: TrailingPause
    /// Fixed seconds to hold here regardless of speed (from `[PAUSE]` or `[PAUSE 2]`).
    public var holdSeconds: Double

    public init(text: String, kind: Kind = .word, paragraphStart: Bool = false, sentenceStart: Bool = false,
                trailingPause: TrailingPause = .none, holdSeconds: Double = 0) {
        self.text = text
        self.kind = kind
        self.paragraphStart = paragraphStart
        self.sentenceStart = sentenceStart
        self.trailingPause = trailingPause
        self.holdSeconds = holdSeconds
    }
}

/// A script split into tokens, with sentence boundaries for navigation.
public struct Script: Equatable, Sendable {
    public let tokens: [Token]
    /// Token indices where sentences start, ascending. Always contains 0 for a non-empty script.
    public let sentenceStarts: [Int]
    public let wordCount: Int

    public var isEmpty: Bool { tokens.isEmpty }

    public init(text: String) {
        let toks = ScriptParser.tokenize(text)
        var starts = toks.indices.filter { toks[$0].sentenceStart }
        if !toks.isEmpty, starts.first != 0 { starts.insert(0, at: 0) }
        tokens = toks
        sentenceStarts = starts
        wordCount = toks.lazy.filter { $0.kind == .word }.count
    }

    /// Start of the sentence that contains token `i`.
    public func sentenceStart(containing i: Int) -> Int {
        var lo = 0, hi = sentenceStarts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sentenceStarts[mid] <= i { best = sentenceStarts[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    /// Where "back" goes: the start of the current sentence, or the previous one if already at (or just past) the start.
    public func previousSentenceStart(from i: Int) -> Int {
        let current = sentenceStart(containing: i)
        if i - current >= 2 { return current }
        guard let idx = sentenceStarts.firstIndex(of: current), idx > 0 else { return 0 }
        return sentenceStarts[idx - 1]
    }

    /// Where "forward" goes: the start of the next sentence, if there is one.
    public func nextSentenceStart(from i: Int) -> Int? {
        sentenceStarts.first { $0 > i }
    }
}

enum ScriptParser {
    static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "e.g.", "i.e.", "no.", "inc.", "ltd.", "jr.", "sr.", "approx.",
    ]
    static let closers: Set<Character> = [")", "]", "\"", "'", "”", "’", "»"]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var newSentence = true
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for raw in lines {
            let line = cleanMarkdown(raw)
            let pieces = split(line)
            guard !pieces.isEmpty else { continue }
            if let last = tokens.indices.last { tokens[last].trailingPause = max(tokens[last].trailingPause, .paragraph) }
            newSentence = true
            for (n, piece) in pieces.enumerated() {
                if piece.isCue {
                    tokens.append(Token(text: piece.text, kind: .cue, paragraphStart: n == 0,
                                        holdSeconds: pauseSeconds(inCue: piece.text)))
                    continue
                }
                let pause = trailingPause(of: piece.text)
                tokens.append(Token(text: piece.text, kind: .word, paragraphStart: n == 0,
                                    sentenceStart: newSentence, trailingPause: pause))
                newSentence = pause == .sentence
            }
        }
        return tokens
    }

    /// Strips the Markdown that people paste most: headings, bullets, quotes and bold markers.
    static func cleanMarkdown(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[-*+•]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return s
    }

    /// Splits a line into words and `[bracketed]` cues. A cue may contain spaces.
    static func split(_ line: String) -> [(text: String, isCue: Bool)] {
        var out: [(String, Bool)] = []
        var word = ""
        var i = line.startIndex
        func flush() { if !word.isEmpty { out.append((word, false)); word = "" } }
        while i < line.endIndex {
            let c = line[i]
            if c == "[", let close = line[i...].firstIndex(of: "]") {
                flush()
                let inner = line[line.index(after: i)..<close].trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { out.append(("[\(inner)]", true)) }
                i = line.index(after: close)
                continue
            }
            if c.isWhitespace { flush() } else { word.append(c) }
            i = line.index(after: i)
        }
        flush()
        return out
    }

    static func trailingPause(of word: String) -> TrailingPause {
        var w = Substring(word)
        while let last = w.last, closers.contains(last) { w = w.dropLast() }
        guard let last = w.last else { return .none }
        if ".!?…".contains(last) {
            return abbreviations.contains(w.lowercased()) ? .none : .sentence
        }
        if ",;:—–".contains(last) { return .clause }
        return .none
    }

    /// `[PAUSE]` holds 1.5 s; `[pause 3]` or `[PAUSE: 2.5s]` holds that many seconds; other cues hold 0.
    static func pauseSeconds(inCue cue: String) -> Double {
        let inner = cue.dropFirst().dropLast().lowercased()
        guard inner.hasPrefix("pause") else { return 0 }
        if let r = inner.range(of: #"\d+(\.\d+)?"#, options: .regularExpression), let v = Double(inner[r]) {
            return min(max(v, 0), 30)
        }
        return 1.5
    }
}
