import Foundation
import Testing
@testable import PrompterCore

@Suite("Rehearsal report")
struct RehearsalTests {
    let spoken = SpokenScript(trackerScript)

    /// Simulates a tracker: reading at `rate` words/s, with optional silences and jumps.
    func record(_ steps: [(seconds: Double, rate: Double, speaking: Bool)], jumps: [Double: Int] = [:],
                finals: [String] = []) -> RehearsalRecorder {
        var r = RehearsalRecorder(script: spoken)
        var t = 0.0, pos = 0.0
        var pendingJumps = jumps
        for step in steps {
            let end = t + step.seconds
            while t < end {
                if let (jt, to) = pendingJumps.first(where: { $0.key <= t }) { pos = Double(to); pendingJumps[jt] = nil }
                r.sample(t: t, confirmed: min(pos, Double(spoken.count - 1)), speaking: step.speaking)
                if step.speaking { pos += step.rate * 0.05 }
                t += 0.05
            }
        }
        for f in finals { r.heard(final: f) }
        return r
    }

    @Test func paceCoverageAndPauses() throws {
        let rest = Double(spoken.count - 50) / 2.5 + 0.3          // read to the end, then stop
        let r = record([(20, 2.5, true), (3, 0, false), (rest, 2.5, true), (2, 0, false)])
        let rep = try #require(r.report(title: "Talk"))
        #expect(abs(rep.averageWPM - 150) < 8)
        #expect(rep.pauses.count == 1)
        #expect(abs(rep.pauses[0].seconds - 3) < 0.2)
        #expect(rep.finished)
        #expect(rep.coverage > 0.95)
        #expect(!rep.pace.isEmpty && rep.pace.allSatisfy { abs($0.wpm - 150) < 20 })
    }

    @Test func detectsSkipsAndRereads() throws {
        // At 10 s jump ahead 20 words (a skip); at 30 s go back 15 words (a re-read).
        let r = record([(35, 2.5, true), (2, 0, false)], jumps: [10: 45, 30: 50])
        let rep = try #require(r.report(title: "Talk"))
        #expect(rep.skipped.count == 1)
        #expect((25...26).contains(rep.skipped[0].from) && rep.skipped[0].to == 44)
        #expect(!rep.skipped[0].excerpt.isEmpty)
        #expect(rep.reread.count == 1)
        #expect(rep.coverage < 0.9)
    }

    @Test func catchUpAfterMisheardWordsIsNotASkip() throws {
        // The position stalls for 4 s of talking (misheard words), then jumps 10 words to catch up.
        var r = RehearsalRecorder(script: spoken)
        var t = 0.0, pos = 0.0
        func run(_ seconds: Double, rate: Double) {
            let end = t + seconds
            while t < end { r.sample(t: t, confirmed: pos, speaking: true); pos += rate * 0.05; t += 0.05 }
        }
        run(10, rate: 2.5)                 // 25 words
        let stalled = pos
        let end = t + 4
        while t < end { r.sample(t: t, confirmed: stalled, speaking: true); t += 0.05 }
        pos = stalled + 10                 // catch-up jump
        run(10, rate: 2.5)
        let rep = try #require(r.report(title: "x"))
        #expect(rep.skipped.isEmpty)
    }

    @Test func trailingConfirmationsAfterSpeechCount() throws {
        // Speech ends, then the last words are confirmed (recognition lag) while silent.
        var r = RehearsalRecorder(script: spoken)
        var t = 0.0, pos = 0.0
        while pos < Double(spoken.count - 4) { r.sample(t: t, confirmed: pos, speaking: true); pos += 0.125; t += 0.05 }
        for _ in 0..<20 { r.sample(t: t, confirmed: Double(spoken.count - 1), speaking: false); t += 0.05 }
        let rep = try #require(r.report(title: "x"))
        #expect(rep.finished)
        #expect(rep.coverage > 0.98)
    }

    @Test func countsFillersButNotScriptWords() {
        let s = SpokenScript(Script(text: "We actually shipped it. Basically done."))
        var r = RehearsalRecorder(script: s)
        r.heard(final: "Um we actually actually shipped it uh")
        r.heard(final: "basically done you know")
        let f = r.fillerCounts()
        #expect(f["um"] == 1 && f["uh"] == 1)
        #expect(f["actually"] == 1)        // said twice, once is in the script
        #expect(f["basically"] == nil)     // in the script
        #expect(f["you know"] == 1)
    }

    @Test func tooShortGivesNoReport() {
        #expect(record([(4, 2.5, true)]).report(title: "x") == nil)
        #expect(RehearsalRecorder(script: spoken).report(title: "x") == nil)
    }

    @Test func storeSavesAndFilters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RehearsalStore(directory: dir)
        let rep = try #require(record([(30, 2.5, true)]).report(title: "Pitch", date: Date(timeIntervalSince1970: 1_000_000)))
        var other = rep
        other.scriptTitle = "Other"
        other.date = Date(timeIntervalSince1970: 2_000_000)
        try store.save(rep)
        try store.save(other)
        #expect(store.all().map(\.scriptTitle) == ["Other", "Pitch"])
        #expect(store.all(script: "Pitch") == [rep])
    }
}
