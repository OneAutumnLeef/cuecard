import Testing
@testable import PrompterCore

@Suite("Pacing and auto-scroll")
struct PacingTests {
    let script = Script(text: """
        Hi everyone, and thanks for joining today. Over the next few minutes I want to walk you through \
        three ideas that changed how our team works.
        [PAUSE] First, we stopped measuring hours and started measuring outcomes.
        """)

    @Test func wholeScriptLastsWordCountOverWPMPlusHolds() {
        let a = AutoScroller(script: script, wpm: 150)
        let expected = Double(script.wordCount) / 150 * 60 + 1.5
        #expect(abs(a.totalTime() - expected) < 1e-9)
    }

    @Test func longerWordsAndSentenceEndsGetMoreTime() {
        let s = Script(text: "a extraordinary word. next")
        let b = Pacing.beats(for: s)
        #expect(b[1] > b[0])            // long word > short word
        #expect(b[2] > b[3])            // "word." carries the sentence pause
    }

    @Test func cuesTakeNoBeats() {
        let s = Script(text: "one [smile] two")
        #expect(Pacing.beats(for: s)[1] == 0)
    }

    @Test func advancingMovesThroughTokensAndFinishes() {
        var a = AutoScroller(script: script, wpm: 150)
        #expect(a.currentIndex == 0)
        a.advance(by: a.duration(of: 0) * 0.5)
        #expect(a.currentIndex == 0)
        #expect(abs(a.position - 0.5) < 1e-9)
        a.advance(by: a.duration(of: 0) * 0.5 + 1e-9)
        #expect(a.currentIndex == 1)
        a.advance(by: 10_000)
        #expect(a.isFinished)
        #expect(a.currentIndex == script.tokens.count - 1)
        #expect(a.remainingTime() == 0)
    }

    @Test func remainingTimeCountsDown() {
        var a = AutoScroller(script: script, wpm: 150)
        let total = a.totalTime()
        a.advance(by: 7.25)
        #expect(abs(a.remainingTime() - (total - 7.25)) < 1e-6)
    }

    @Test func pauseCueHoldsForItsSeconds() {
        let s = Script(text: "go [PAUSE 2] on")
        var a = AutoScroller(script: s, wpm: 60)
        a.advance(by: a.duration(of: 0))          // finish "go"
        #expect(a.currentIndex == 1)
        a.advance(by: 1.9)
        #expect(a.currentIndex == 1)              // still holding
        a.advance(by: 0.2)
        #expect(a.currentIndex == 2)
    }

    @Test func zeroLengthCuesAreSkippedInstantly() {
        let s = Script(text: "go [smile] on")
        var a = AutoScroller(script: s, wpm: 60)
        a.advance(by: a.duration(of: 0) + 0.01)
        #expect(a.currentIndex == 2)
    }

    @Test func speedChangeKeepsPosition() {
        var a = AutoScroller(script: script, wpm: 150)
        a.advance(by: 5)
        let before = a.position
        a.wpm = 200
        #expect(a.position == before)
        let r = a.remainingTime()
        a.wpm = 100
        #expect(a.remainingTime() > r)
    }

    @Test func wpmIsClamped() {
        var a = AutoScroller(script: script, wpm: 5)
        #expect(a.wpm == AutoScroller.minWPM)
        a.wpm = 10_000
        #expect(a.wpm == AutoScroller.maxWPM)
    }

    @Test func jumpClampsToScript() {
        var a = AutoScroller(script: script, wpm: 150)
        a.jump(to: 9_999)
        #expect(a.currentIndex == script.tokens.count - 1)
        #expect(!a.isFinished)
        a.jump(to: -4)
        #expect(a.position == 0)
    }

    @Test func emptyScriptIsSafe() {
        var a = AutoScroller(script: Script(text: ""), wpm: 150)
        a.advance(by: 1)
        a.jump(to: 3)
        #expect(a.isFinished)
        #expect(a.currentIndex == 0)
        #expect(a.totalTime() == 0)
    }
}
