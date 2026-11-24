import Foundation

/// Tuning for `VoiceTracker`. Defaults come from the Phase 0 measurements: words arrive about
/// 0.7 s after they're spoken, in bursts about once a second, with ~25% of words misheard.
public struct TrackerConfig: Sendable, Equatable {
    /// How many of the most recent heard words are matched against the script.
    public var tailWords = 8
    /// Search window around the current position, in spoken words.
    public var windowBehind = 45
    public var windowAhead = 40
    /// Forward moves up to this size need only ordinary evidence; bigger jumps need several strong matches.
    public var smallJump = 8
    /// Seconds between a word being spoken and the recogniser reporting it.
    public var recognitionLag = 0.7
    /// The predicted position never runs more than this many words past the last confirmed word…
    public var maxLeadWords = 4.5
    /// …or this many seconds of speech at your pace, whichever is larger (fast readers need more lead).
    public var maxLeadSeconds = 1.6
    /// Added to the position before choosing the word to light up (positive = slightly ahead).
    public var highlightBias = 0.5
    /// How quickly the display closes the gap to the target (per second).
    public var catchUpGain = 3.0
    /// After the voice drops, keep moving this long (natural gaps between words).
    public var voiceHangover = 0.35
    /// Seconds of speaking with no match before searching the whole script.
    public var lostAfter = 3.0
    /// Starting speaking rate, words per second (replaced by the measured rate once you talk).
    public var initialRate = 2.5

    public init() {}
}

/// Follows a speaker through a script.
///
/// Feed it what the recogniser hears (`hear`), the microphone level (`level`) and the clock (`advance`).
/// It keeps two positions, in spoken-word units:
/// - `confirmed`: the last script word matched against what was heard (reliable, about 0.7 s late);
/// - `display`: where to highlight now, predicted from your measured pace while you're speaking,
///   stopping when you stop, and never running more than a few words ahead of the evidence.
public struct VoiceTracker: Sendable {
    public enum Confidence: Sendable, Equatable { case waiting, locked, coasting, lost }

    public let script: SpokenScript
    public var config: TrackerConfig

    public private(set) var confirmed: Double = 0
    public private(set) var display: Double = 0
    public private(set) var rate: Double
    public private(set) var isSpeaking = false
    public private(set) var confidence: Confidence = .waiting

    private var finalized: [String] = []
    private var volatile: [String] = []
    private var skipVolatile = 0
    private var lastTail: [String] = []
    private var lastTailPartial = false

    private var now = 0.0
    private var lastTime: Double?
    private var speakingTime = 0.0          // a clock that only runs while the voice is on
    private var confirmedAt = 0.0           // speakingTime when `confirmed` last moved
    private var lastMatchAt = 0.0           // speakingTime of the last accepted match
    private var started = false
    private var rateSamples: [(tau: Double, pos: Double)] = []

    private var voiceUntil = -Double.infinity
    private var levelHistory: [Double] = []

    public init(script: SpokenScript, config: TrackerConfig = TrackerConfig(), startWord: Int = 0) {
        self.script = script
        self.config = config
        rate = config.initialRate
        let p = Double(min(max(startWord, 0), max(script.count - 1, 0)))
        confirmed = p
        display = p
    }

    public var isFinished: Bool { script.count > 0 && confirmed >= Double(script.count - 1) }
    /// Word to highlight.
    public var displayWord: Int { min(max(Int(display + config.highlightBias), 0), max(script.count - 1, 0)) }
    /// Measured pace in words per minute.
    public var wordsPerMinute: Double { rate * 60 }
    /// Noise floor estimate, for diagnostics.
    public var voiceThreshold: Double { threshold() }

    // MARK: - Inputs

    /// A recogniser result: the text so far for the current stretch (volatile), or a settled stretch (final).
    public mutating func hear(_ text: String, isFinal: Bool, at t: Double) {
        now = max(now, t)
        var words = text.split(whereSeparator: \.isWhitespace).flatMap { SpokenForm.words(String($0)) }
        if skipVolatile > 0 { words = Array(words.dropFirst(min(skipVolatile, words.count))) }
        if isFinal {
            finalized.append(contentsOf: words)
            if finalized.count > 48 { finalized.removeFirst(finalized.count - 48) }
            volatile = []
            skipVolatile = 0
        } else {
            volatile = words
        }
        let tail = Array((finalized + volatile).suffix(config.tailWords))
        let partial = !isFinal && !volatile.isEmpty
        guard !tail.isEmpty, tail != lastTail || partial != lastTailPartial else { return }
        lastTail = tail
        lastTailPartial = partial
        locate(tail, lastIsPartial: partial)
    }

    /// Microphone level in dBFS (about 20 times a second).
    ///
    /// Voice is "on" when the level is 10 dB above the background. The background is the quietest
    /// fifth of the last 10 seconds: speech always has gaps between words, so this tracks the room,
    /// not the voice, and it adapts to a noisy room within seconds.
    public mutating func level(_ db: Double, at t: Double) {
        now = max(now, t)
        levelHistory.append(max(db, -90))
        if levelHistory.count > 200 { levelHistory.removeFirst(levelHistory.count - 200) }
        if db > threshold() { voiceUntil = t + config.voiceHangover }
    }

    /// The recogniser restarted (new session): forget the unsettled text it had.
    public mutating func recogniserRestarted() {
        volatile = []
        skipVolatile = 0
        lastTail = []
    }

    /// Move to a word (a click, or a sentence jump). Waits for speech before predicting again.
    public mutating func jump(toWord i: Int) {
        let p = Double(min(max(i, 0), max(script.count - 1, 0)))
        confirmed = p
        display = p
        started = false
        confidence = .waiting
        rateSamples.removeAll()
        finalized.removeAll()
        skipVolatile = volatile.count     // ignore what the recogniser already heard before the jump
        volatile.removeAll()
        lastTail = []
        lastMatchAt = speakingTime
        confirmedAt = speakingTime
    }

    /// Advance the clock and update `display`.
    public mutating func advance(to t: Double) {
        let dt = lastTime.map { min(max(t - $0, 0), 0.25) } ?? 0
        lastTime = t
        now = max(now, t)
        isSpeaking = t < voiceUntil
        if isSpeaking { speakingTime += dt }

        var target = confirmed
        if isSpeaking && started {
            let lead = rate * (speakingTime - confirmedAt + config.recognitionLag)
            target = confirmed + min(max(lead, 0), max(config.maxLeadWords, rate * config.maxLeadSeconds))
        }
        target = min(target, Double(max(script.count - 1, 0)))
        let gap = target - display
        if gap > 0 {
            display += min(gap, (rate + config.catchUpGain * gap) * dt)
        }
        // A display ahead of the target just waits: the highlight never drifts backwards.

        if started, confidence != .waiting, isSpeaking {
            let since = speakingTime - lastMatchAt
            confidence = since < 1.6 ? .locked : (since < config.lostAfter ? .coasting : .lost)
        }
    }

    // MARK: - Matching

    struct Candidate { var position: Int; var score: Double; var strong: Int }

    private mutating func locate(_ tail: [String], lastIsPartial: Bool) {
        guard script.count > 0 else { return }
        let p = Int(confirmed)
        let lost = started && speakingTime - lastMatchAt > config.lostAfter
        let lo = max(0, p - config.windowBehind), hi = min(script.count, p + config.windowAhead + 1)
        if let c = Self.align(tail, partial: lastIsPartial, words: script.words, lo: lo, hi: hi, expected: p + 1),
           accept(c, from: p) {
            return
        }
        // Lost, or never matched yet: look everywhere, but demand strong evidence.
        if lost || !started,
           let c = Self.align(tail, partial: lastIsPartial, words: script.words, lo: 0, hi: script.count, expected: p + 1),
           c.strong >= 4, c.score >= 8, abs(c.position - p) > config.smallJump {
            move(to: c.position, jump: true)
        }
    }

    /// Applies the movement rules. Returns true if the candidate was used.
    private mutating func accept(_ c: Candidate, from p: Int) -> Bool {
        let d = c.position - p
        switch d {
        case 0, -2 ... -1:
            guard c.score >= 2 else { return false }
            noteMatch()
            return true
        case 1 ... config.smallJump:
            guard c.score >= 2 else { return false }
            move(to: c.position, jump: false)
            return true
        default:
            // Skipping ahead or going back to re-read: needs several strong matches in the new place.
            guard c.strong >= 3, c.score >= 6 else { return false }
            move(to: c.position, jump: true)
            return true
        }
    }

    private mutating func noteMatch() {
        lastMatchAt = speakingTime
        if !started { started = true; confirmedAt = speakingTime }
        confidence = .locked
    }

    private mutating func move(to pos: Int, jump: Bool) {
        let newPos = Double(pos)
        if jump {
            rateSamples.removeAll()
            display = newPos
        } else {
            rateSamples.append((speakingTime, newPos))
            rateSamples.removeAll { speakingTime - $0.tau > 8 }
            if let first = rateSamples.first, let last = rateSamples.last, last.tau - first.tau >= 2.5 {
                let measured = (last.pos - first.pos) / (last.tau - first.tau)
                let blended = 0.7 * rate + 0.3 * measured
                rate = min(max(blended, rate * 0.85, 1.0), rate * 1.15, 5.0)   // pace changes gradually
            }
        }
        confirmed = newPos
        confirmedAt = speakingTime
        if display < confirmed { display = max(display, confirmed - 0.0) }
        noteMatch()
    }

    private func threshold() -> Double {
        guard levelHistory.count >= 8 else { return -45 }
        let sorted = levelHistory.sorted()
        return max(sorted[Int(Double(sorted.count - 1) * 0.2)] + 10, -55)
    }

    /// Local alignment of the heard tail against `words[lo..<hi]`, anchored at the last heard word.
    /// Returns the script position aligned with that last word.
    static func align(_ heard: [String], partial: Bool, words: [String], lo: Int, hi: Int, expected: Int) -> Candidate? {
        let m = heard.count, n = hi - lo
        guard m > 0, n > 0 else { return nil }
        let gapHeard = -0.9, gapScript = -0.7, mismatch = -1.0
        var score = [Double](repeating: 0, count: (m + 1) * (n + 1))
        var strong = [Int](repeating: 0, count: (m + 1) * (n + 1))
        func idx(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        for i in 1...m {
            let h = heard[i - 1]
            let isPartial = partial && i == m
            for j in 1...n {
                let w = words[lo + j - 1]
                let sim = WordMatch.similarity(h, w, heardIsPartial: isPartial)
                let isCommon = WordMatch.common.contains(w)
                let pair = sim >= 0.6 ? (isCommon ? 1.0 : 2.0) * sim : mismatch
                var best = 0.0, bestStrong = 0
                let diag = score[idx(i - 1, j - 1)] + pair
                if diag > best { best = diag; bestStrong = strong[idx(i - 1, j - 1)] + (sim >= 0.8 && !isCommon ? 1 : 0) }
                let up = score[idx(i - 1, j)] + gapHeard
                if up > best { best = up; bestStrong = strong[idx(i - 1, j)] }
                let left = score[idx(i, j - 1)] + gapScript
                if left > best { best = left; bestStrong = strong[idx(i, j - 1)] }
                score[idx(i, j)] = best
                strong[idx(i, j)] = bestStrong
            }
        }
        var bestJ = -1, bestValue = 0.0
        for j in 1...n {
            let s = score[idx(m, j)]
            guard s > 0 else { continue }
            let biased = s - 0.03 * Double(abs(lo + j - 1 - expected))
            if bestJ < 0 || biased > bestValue { bestJ = j; bestValue = biased }
        }
        guard bestJ > 0 else { return nil }
        return Candidate(position: lo + bestJ - 1, score: score[idx(m, bestJ)], strong: strong[idx(m, bestJ)])
    }
}
