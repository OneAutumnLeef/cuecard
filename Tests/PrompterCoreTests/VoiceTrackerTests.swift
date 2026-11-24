import Testing
@testable import PrompterCore

/// Simulates a speaker and a recogniser that behaves like the one measured in Phase 0:
/// results every `burst` seconds, covering words spoken up to `lag` seconds earlier.
struct SpeechSim {
    struct Spoken { var word: String; var scriptIndex: Int?; var time: Double }

    var spoken: [Spoken] = []
    var lag = 0.7
    var burst = 1.0
    var silences: [ClosedRange<Double>] = []

    /// Reads `words` (with optional script positions) at `rate` words per second starting at `start`.
    mutating func say(_ words: [(String, Int?)], rate: Double = 2.5, start: Double? = nil) {
        var t = start ?? ((spoken.last?.time ?? -1 / rate) + 1 / rate)
        for (w, i) in words {
            spoken.append(Spoken(word: w, scriptIndex: i, time: t))
            t += 1 / rate
        }
    }

    mutating func pause(_ seconds: Double) {
        let from = (spoken.last?.time ?? 0) + 0.4
        silences.append(from...(from + seconds))
        // shift later words is the caller's job: pass `start:` to the next say()
    }

    var end: Double { (spoken.last?.time ?? 0) + 2.5 }

    func isVoiced(_ t: Double) -> Bool {
        guard let first = spoken.first?.time, t >= first, t <= (spoken.last?.time ?? 0) + 0.4 else { return false }
        if silences.contains(where: { $0.contains(t) }) { return false }
        // voiced for the first 0.28 s of each word, with a short dip before the next (like real speech)
        return spoken.contains { $0.time <= t && t - $0.time < 0.28 }
    }

    /// Where the speaker truly is in the script at time t (last script word started).
    func truth(_ t: Double) -> Double? {
        spoken.last { $0.time <= t && $0.scriptIndex != nil }?.scriptIndex.map(Double.init)
    }

    /// Runs a tracker through the whole simulation, returning (time, display, truth) samples.
    func run(_ tracker: inout VoiceTracker, onFrame: ((Double, inout VoiceTracker) -> Void)? = nil) -> [(t: Double, display: Double, truth: Double?)] {
        var out: [(Double, Double, Double?)] = []
        var t = 0.0
        var nextBurst = burst
        var nextLevel = 0.0
        let dt = 1.0 / 60
        var sentFinalUpTo = 0
        while t < end {
            if t >= nextLevel {
                tracker.level(isVoiced(t) ? -24 : -62, at: t)
                nextLevel += 0.05
            }
            if t >= nextBurst {
                let heardUpTo = spoken.lastIndex { $0.time <= t - lag } ?? -1
                if heardUpTo >= sentFinalUpTo {
                    let text = spoken[sentFinalUpTo...heardUpTo].map(\.word).joined(separator: " ")
                    // settle (final) every 12 words, like sentence-sized finals
                    let isFinal = heardUpTo - sentFinalUpTo + 1 >= 12
                    tracker.hear(text, isFinal: isFinal, at: t)
                    if isFinal { sentFinalUpTo = heardUpTo + 1 }
                }
                nextBurst += burst
            }
            onFrame?(t, &tracker)
            tracker.advance(to: t)
            out.append((t, tracker.display, truth(t)))
            t += dt
        }
        return out
    }
}

let trackerScript = Script(text: """
    Hi everyone, and thanks for joining today. Over the next few minutes I want to walk you through three ideas \
    that changed how our team works. First, we stopped measuring hours and started measuring outcomes. That sounds \
    simple, but it forced every person to explain what they were actually trying to achieve. Second, we moved our \
    planning from once a quarter to every two weeks. Plans got smaller, and we finally learned to say no. Third, \
    and this is the one people ask about most, we made every meeting optional unless it had a written agenda.
    """)

func words(_ range: Range<Int>, in s: SpokenScript) -> [(String, Int?)] {
    range.map { (s.words[$0], $0) }
}

/// Fraction of samples (after speech starts) where |display − truth| ≤ tolerance.
func within(_ samples: [(t: Double, display: Double, truth: Double?)], _ tolerance: Double, from: Double = 0, to: Double = .infinity) -> Double {
    let s = samples.filter { $0.truth != nil && $0.t >= from && $0.t <= to }
    guard !s.isEmpty else { return 0 }
    return Double(s.filter { abs($0.display - $0.truth!) <= tolerance }.count) / Double(s.count)
}

@Suite("Spoken form")
struct SpokenFormTests {
    @Test func numbersAndSymbols() {
        #expect(SpokenForm.words("40%") == ["forty", "percent"])
        #expect(SpokenForm.words("1st") == ["first"])
        #expect(SpokenForm.words("22nd") == ["twenty", "second"])
        #expect(SpokenForm.words("3") == ["three"])
        #expect(SpokenForm.words("1,200") == ["one", "thousand", "two", "hundred"])
        #expect(SpokenForm.words("2.5") == ["two", "point", "five"])
        #expect(SpokenForm.words("$5") == ["five", "dollars"])
        #expect(SpokenForm.words("twenty-six") == ["twenty", "six"])
        #expect(SpokenForm.words("Don’t") == ["dont"])
        #expect(SpokenForm.words("“Hello,”") == ["hello"])
        #expect(SpokenForm.words("—") == [])
        #expect(SpokenForm.ordinal(20) == ["twentieth"])
    }

    @Test func similarity() {
        #expect(WordMatch.similarity("plants", "plans") > 0.6)
        #expect(WordMatch.similarity("measureing", "measuring") > 0.6)
        #expect(WordMatch.similarity("cat", "dog") == 0)
        #expect(WordMatch.similarity("disapp", "disappeared", heardIsPartial: true) > 0.6)
        #expect(WordMatch.similarity("disapp", "disappeared", heardIsPartial: false) == 0)
    }

    @Test func spokenScriptMapsBackToTokens() {
        let s = SpokenScript(Script(text: "Up 40% [smile] today"))
        #expect(s.words == ["up", "forty", "percent", "today"])
        #expect(s.tokenOf == [0, 1, 1, 3])
        #expect(s.firstWordOfToken == [0, 1, 3, 3])
    }
}

@Suite("Voice tracker")
struct VoiceTrackerTests {
    let spoken = SpokenScript(trackerScript)

    @Test func followsAPerfectReading() {
        var sim = SpeechSim()
        sim.say(words(0..<spoken.count, in: spoken))
        var tracker = VoiceTracker(script: spoken)
        let samples = sim.run(&tracker)
        #expect(within(samples, 1.5, from: 3) > 0.85)
        #expect(tracker.isFinished)
    }

    @Test func toleratesAQuarterOfWordsMisheard() {
        var sim = SpeechSim()
        let junk = ["blue", "kettle", "orbit", "sand", "violin"]
        sim.say((0..<spoken.count).map { i in (i % 4 == 2 ? junk[i % junk.count] : spoken.words[i], i) })
        var tracker = VoiceTracker(script: spoken)
        let samples = sim.run(&tracker)
        #expect(within(samples, 2, from: 3) > 0.8)
        #expect(tracker.confirmed > Double(spoken.count - 5))
    }

    @Test func catchesUpAfterASkippedSentence() {
        // "That sounds simple ... achieve." is skipped.
        let skipStart = spoken.words.firstIndex(of: "sounds")! - 1
        let skipEnd = spoken.words.firstIndex(of: "second")!
        var sim = SpeechSim()
        sim.say(words(0..<skipStart, in: spoken) + words(skipEnd..<spoken.count, in: spoken))
        var tracker = VoiceTracker(script: spoken)
        let samples = sim.run(&tracker)
        let resume = sim.spoken.first { $0.scriptIndex == skipEnd }!.time
        #expect(within(samples, 2, from: resume + 4) > 0.8)
    }

    @Test func goesBackWhenARepeatedSentenceIsReRead() {
        let a = spoken.words.firstIndex(of: "first")!
        let b = spoken.words.firstIndex(of: "that")!     // "That sounds simple"
        var sim = SpeechSim()
        sim.say(words(0..<b, in: spoken) + words(a..<spoken.count, in: spoken))   // re-reads "First, we stopped…"
        var tracker = VoiceTracker(script: spoken)
        let samples = sim.run(&tracker)
        let reRead = sim.spoken[b].time
        #expect(within(samples, 2, from: reRead + 4) > 0.75)
    }

    @Test func holdsDuringAnAdLibThenResumes() {
        let cut = spoken.words.firstIndex(of: "second")!
        let adlib = "and honestly nobody on the team believed it would work at all".split(separator: " ").map { (String($0), Int?.none) }
        var sim = SpeechSim()
        sim.say(words(0..<cut, in: spoken) + adlib + words(cut..<spoken.count, in: spoken))
        var tracker = VoiceTracker(script: spoken)
        var maxDuringAdlib = 0.0
        let adlibStart = sim.spoken[cut].time, adlibEnd = sim.spoken[cut + adlib.count - 1].time
        let samples = sim.run(&tracker) { t, tr in
            if t > adlibStart, t < adlibEnd { maxDuringAdlib = max(maxDuringAdlib, tr.display) }
        }
        #expect(maxDuringAdlib <= Double(cut) + 5.5)            // didn't run away through the next sentence
        #expect(within(samples, 2, from: adlibEnd + 4) > 0.8)  // and picked up again afterwards
    }

    @Test func stopsWhenTheSpeakerStops() {
        let half = spoken.count / 2
        var sim = SpeechSim()
        sim.say(words(0..<half, in: spoken))
        let pauseStart = sim.spoken.last!.time
        sim.say(words(half..<spoken.count, in: spoken), start: pauseStart + 4)
        var tracker = VoiceTracker(script: spoken)
        var displayAtPauseEnd = 0.0
        _ = sim.run(&tracker) { t, tr in
            if abs(t - (pauseStart + 3.8)) < 0.01 { displayAtPauseEnd = tr.display }
        }
        #expect(displayAtPauseEnd <= Double(half) + 1.5)
        #expect(displayAtPauseEnd >= Double(half) - 2.5)
        #expect(tracker.isFinished)
    }

    @Test func numbersInTheScriptMatchDigitsHeard() {
        let s = SpokenScript(Script(text: "Attendance dropped by forty percent in the first month and nobody missed them"))
        var tracker = VoiceTracker(script: s)
        tracker.level(-20, at: 0)
        tracker.hear("Attendance dropped by 40% in the 1st month", isFinal: false, at: 1)
        tracker.advance(to: 1)
        #expect(tracker.confirmed == Double(s.words.firstIndex(of: "month")!))
    }

    @Test func clickJumpWaitsForSpeechAtTheNewPlace() {
        var tracker = VoiceTracker(script: spoken)
        tracker.jump(toWord: 40)
        #expect(tracker.display == 40)
        #expect(tracker.confidence == .waiting)
        for k in 0..<20 { tracker.level(-20, at: Double(k) * 0.05); tracker.advance(to: Double(k) * 0.05) }
        #expect(tracker.display == 40)    // talking, but nothing matched yet: no guessing
    }

    @Test func emptyScriptIsSafe() {
        var tracker = VoiceTracker(script: SpokenScript(Script(text: "")))
        tracker.hear("hello there", isFinal: true, at: 1)
        tracker.level(-20, at: 1)
        tracker.advance(to: 2)
        tracker.jump(toWord: 5)
        #expect(tracker.display == 0)
        #expect(!tracker.isFinished)
    }
}
