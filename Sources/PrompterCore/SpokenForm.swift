import Foundation

/// Turns written text into the words a person actually says, so the script and the recogniser's
/// output can be compared: "40%" → ["forty", "percent"], "1st" → ["first"], "3" → ["three"],
/// "twenty-six" → ["twenty", "six"], "Don’t" → ["dont"].
public enum SpokenForm {
    public static func words(_ token: String) -> [String] {
        var s = token.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        s = s.replacingOccurrences(of: "&", with: " and ")
        var out: [String] = []
        for part in s.split(whereSeparator: { "-–—/".contains($0) || $0.isWhitespace }) {
            out.append(contentsOf: expand(String(part)))
        }
        return out
    }

    private static func expand(_ raw: String) -> [String] {
        // Trim punctuation around the word, keeping symbols that are spoken.
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "%$₹£€.,'"))
        var p = raw.unicodeScalars.filter { keep.contains($0) }.map(String.init).joined()
        while let f = p.first, ".,'".contains(f) { p.removeFirst() }
        while let l = p.last, ".,'".contains(l) { p.removeLast() }
        guard !p.isEmpty else { return [] }

        let prefixWords: [String] = []
        var suffixWords: [String] = []
        if let f = p.first, let currency = ["$": "dollars", "₹": "rupees", "£": "pounds", "€": "euros"][String(f)] {
            p.removeFirst()
            suffixWords.append(currency)
        }
        if p.hasSuffix("%") {
            p.removeLast()
            suffixWords.insert("percent", at: 0)
        }
        // Ordinals: 1st, 22nd, 3rd, 4th
        if let m = p.wholeMatch(of: /(\d+)(st|nd|rd|th)/), let n = Int(m.1) {
            return prefixWords + ordinal(n) + suffixWords
        }
        // Plain numbers, with thousands separators and decimals: 1,200 · 2.5
        if p.wholeMatch(of: /\d{1,3}(,\d{3})+|\d+/) != nil, let n = Int(p.replacingOccurrences(of: ",", with: "")) {
            return prefixWords + cardinal(n) + suffixWords
        }
        if let m = p.wholeMatch(of: /(\d+)\.(\d+)/), let whole = Int(m.1) {
            let digits = m.2.compactMap { Int(String($0)) }.flatMap { cardinal($0) }
            return prefixWords + cardinal(whole) + ["point"] + digits + suffixWords
        }
        // Ordinary word: drop remaining punctuation (apostrophes, stray dots).
        let letters = p.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return letters.isEmpty ? prefixWords + suffixWords : prefixWords + [letters] + suffixWords
    }

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                       "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    public static func cardinal(_ n: Int) -> [String] {
        if n < 0 { return ["minus"] + cardinal(-n) }
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : cardinal(n % 100)) }
        for (size, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] where n >= size {
            return cardinal(n / size) + [name] + (n % size == 0 ? [] : cardinal(n % size))
        }
        return [String(n)]
    }

    public static func ordinal(_ n: Int) -> [String] {
        var w = cardinal(n)
        guard let last = w.popLast() else { return [] }
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        if let r = irregular[last] { w.append(r) }
        else if last.hasSuffix("y") { w.append(String(last.dropLast()) + "ieth") }
        else { w.append(last + "th") }
        return w
    }
}

/// How alike two spoken words are, from 0 (unrelated) to 1 (identical).
public enum WordMatch {
    /// Short, frequent words. A match on one of these is weak evidence of position.
    public static let common: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "by", "with", "from", "as",
        "is", "it", "its", "i", "we", "you", "he", "she", "they", "be", "are", "was", "were", "this", "that",
        "so", "if", "do", "not", "no", "yes", "my", "our", "your", "me", "us", "what", "how", "all", "can",
        "have", "has", "had", "will", "just", "um", "uh", "then", "than", "there", "their", "up", "out",
    ]

    public static func similarity(_ heard: String, _ script: String, heardIsPartial: Bool = false) -> Double {
        if heard == script { return 1 }
        if heard.isEmpty || script.isEmpty { return 0 }
        // A half-spoken last word, e.g. "disapp" while saying "disappeared".
        if heardIsPartial, heard.count >= 3, script.hasPrefix(heard) { return 0.75 }
        let longest = max(heard.count, script.count)
        guard longest >= 4, abs(heard.count - script.count) <= 3 else { return 0 }
        let ratio = 1 - Double(editDistance(Array(heard), Array(script))) / Double(longest)
        return ratio >= 0.7 ? ratio * 0.9 : 0
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// The script as a flat list of spoken words, with a map back to display tokens.
public struct SpokenScript: Sendable {
    public let words: [String]
    /// For each spoken word, the token it belongs to.
    public let tokenOf: [Int]
    /// For each token, its first spoken word (cues have none and point at the next word).
    public let firstWordOfToken: [Int]

    public init(_ script: Script) {
        var words: [String] = []
        var tokenOf: [Int] = []
        var first: [Int] = []
        for (ti, token) in script.tokens.enumerated() {
            first.append(words.count)
            guard token.kind == .word else { continue }
            for w in SpokenForm.words(token.text) {
                words.append(w)
                tokenOf.append(ti)
            }
        }
        self.words = words
        self.tokenOf = tokenOf
        self.firstWordOfToken = first.map { min($0, max(words.count - 1, 0)) }
    }

    public var count: Int { words.count }

    public func token(atWord i: Int) -> Int {
        tokenOf.isEmpty ? 0 : tokenOf[min(max(i, 0), tokenOf.count - 1)]
    }
}
