import Foundation

/// Extra time after words, in "beats" (one beat is roughly one average word).
public struct PacingRules: Sendable, Equatable {
    public var clausePause = 0.35
    public var sentencePause = 0.7
    public var paragraphPause = 1.1
    public init() {}
    public static let standard = PacingRules()
}

public enum Pacing {
    /// Relative speaking time of each token. Longer words and punctuation pauses take longer, and the
    /// beats are scaled so the whole script lasts exactly `wordCount / wpm` minutes (plus `[PAUSE]` holds).
    public static func beats(for script: Script, rules: PacingRules = .standard) -> [Double] {
        var raw = script.tokens.map { token -> Double in
            guard token.kind == .word else { return 0 }
            var letters = 0, digits = 0
            for s in token.text.unicodeScalars {
                if CharacterSet.letters.contains(s) { letters += 1 } else if CharacterSet.decimalDigits.contains(s) { digits += 1 }
            }
            let base = min(max(0.5 + 0.1 * Double(letters + 2 * digits), 0.6), 2.2)
            switch token.trailingPause {
            case .none: return base
            case .clause: return base + rules.clausePause
            case .sentence: return base + rules.sentencePause
            case .paragraph: return base + rules.paragraphPause
            }
        }
        let total = raw.reduce(0, +)
        if total > 0, script.wordCount > 0 {
            let scale = Double(script.wordCount) / total
            raw = raw.map { $0 * scale }
        }
        return raw
    }
}

/// Moves a position through the script at a words-per-minute pace.
///
/// `position` is a token index plus progress through that token (3.5 = halfway through token 3).
/// Changing `wpm` mid-way keeps the position, so speed changes are seamless.
public struct AutoScroller: Sendable, Equatable {
    public private(set) var position: Double
    public var wpm: Double { didSet { wpm = min(max(wpm, AutoScroller.minWPM), AutoScroller.maxWPM) } }

    public static let minWPM = 40.0
    public static let maxWPM = 300.0

    private let beats: [Double]
    private let holds: [Double]
    private let cumBeats: [Double]   // cumBeats[i] = sum of beats before token i
    private let cumHolds: [Double]

    public init(script: Script, wpm: Double, position: Double = 0, rules: PacingRules = .standard) {
        beats = Pacing.beats(for: script, rules: rules)
        holds = script.tokens.map(\.holdSeconds)
        var cb = [0.0], ch = [0.0]
        for i in beats.indices { cb.append(cb[i] + beats[i]); ch.append(ch[i] + holds[i]) }
        cumBeats = cb
        cumHolds = ch
        self.wpm = min(max(wpm, AutoScroller.minWPM), AutoScroller.maxWPM)
        self.position = min(max(position, 0), Double(beats.count))
    }

    public var tokenCount: Int { beats.count }
    public var isFinished: Bool { position >= Double(beats.count) }
    /// The token to highlight. Stays on the last token once finished.
    public var currentIndex: Int { beats.isEmpty ? 0 : min(Int(position), beats.count - 1) }

    public func duration(of i: Int) -> Double { beats[i] * 60 / wpm + holds[i] }

    public mutating func advance(by dt: Double) {
        guard dt > 0 else { return }
        var t = dt
        while t > 0, !isFinished {
            let i = Int(position)
            let d = duration(of: i)
            if d <= 0 { position = Double(i + 1); continue }
            let remaining = (Double(i + 1) - position) * d
            if t < remaining {
                position += t / d
                t = 0
            } else {
                t -= remaining
                position = Double(i + 1)
            }
        }
    }

    public mutating func jump(to index: Int) {
        position = Double(min(max(index, 0), max(beats.count - 1, 0)))
    }

    public func totalTime() -> Double { timeFrom(0) }

    public func remainingTime() -> Double {
        guard !isFinished else { return 0 }
        let i = Int(position)
        return timeFrom(i) - (position - Double(i)) * duration(of: i)
    }

    private func timeFrom(_ i: Int) -> Double {
        guard i < beats.count else { return 0 }
        let n = beats.count
        return (cumBeats[n] - cumBeats[i]) * 60 / wpm + (cumHolds[n] - cumHolds[i])
    }
}
