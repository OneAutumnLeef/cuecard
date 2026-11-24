import Testing
@testable import PrompterCore

@Suite("Script parsing")
struct ScriptTests {
    @Test func splitsWordsAndKeepsPunctuationOnTheWord() {
        let s = Script(text: "Hi everyone, and thanks.")
        #expect(s.tokens.map(\.text) == ["Hi", "everyone,", "and", "thanks."])
        #expect(s.wordCount == 4)
    }

    @Test func detectsPausesFromPunctuation() {
        let s = Script(text: "One, two; three. Four? “Five!” six")
        #expect(s.tokens.map(\.trailingPause) == [.clause, .clause, .sentence, .sentence, .sentence, .none])
    }

    @Test func marksSentenceStarts() {
        let s = Script(text: "First one. Second one! Third")
        #expect(s.sentenceStarts == [0, 2, 4])
    }

    @Test func abbreviationsDoNotEndSentences() {
        let s = Script(text: "Ask Dr. Rao, e.g. today. Then go.")
        #expect(s.sentenceStarts == [0, 5])
    }

    @Test func eachSourceLineStartsAParagraphAndASentence() {
        let s = Script(text: "Heading without period\nBody text here.\n\n\nLast line")
        #expect(s.tokens.filter(\.paragraphStart).map(\.text) == ["Heading", "Body", "Last"])
        #expect(s.sentenceStarts == [0, 3, 6])
        #expect(s.tokens[2].trailingPause == .paragraph)
        #expect(s.tokens[5].trailingPause == .paragraph)
    }

    @Test func bracketedCuesBecomeSingleCueTokens() {
        let s = Script(text: "Hello [look at camera] there[SMILE] friend")
        #expect(s.tokens.map(\.text) == ["Hello", "[look at camera]", "there", "[SMILE]", "friend"])
        #expect(s.tokens.map(\.kind) == [.word, .cue, .word, .cue, .word])
        #expect(s.wordCount == 3)
    }

    @Test func pauseCuesHoldTime() {
        let s = Script(text: "[PAUSE] a [pause 3] b [Pause: 2.5s] c [smile]")
        let holds = s.tokens.filter { $0.kind == .cue }.map(\.holdSeconds)
        #expect(holds == [1.5, 3, 2.5, 0])
    }

    @Test func unclosedBracketIsJustText() {
        let s = Script(text: "an [open bracket")
        #expect(s.tokens.map(\.text) == ["an", "[open", "bracket"])
    }

    @Test func stripsCommonMarkdown() {
        let s = Script(text: "# Title\n- **Bold** point\n> quoted line")
        #expect(s.tokens.map(\.text) == ["Title", "Bold", "point", "quoted", "line"])
    }

    @Test func emptyAndWhitespaceScripts() {
        #expect(Script(text: "").isEmpty)
        #expect(Script(text: "  \n\n \t ").isEmpty)
        #expect(Script(text: "").sentenceStarts.isEmpty)
    }

    @Test func sentenceNavigation() {
        // sentences start at 0, 3, 6
        let s = Script(text: "A b c. D e f. G h i.")
        #expect(s.sentenceStart(containing: 4) == 3)
        #expect(s.previousSentenceStart(from: 5) == 3)   // well into a sentence: back to its start
        #expect(s.previousSentenceStart(from: 3) == 0)   // at a start: back to the previous one
        #expect(s.previousSentenceStart(from: 4) == 0)   // just past a start counts as "at the start"
        #expect(s.previousSentenceStart(from: 1) == 0)
        #expect(s.nextSentenceStart(from: 0) == 3)
        #expect(s.nextSentenceStart(from: 6) == nil)
    }

    @Test func windowsLineEndings() {
        let s = Script(text: "One.\r\nTwo.\rThree.")
        #expect(s.tokens.filter(\.paragraphStart).count == 3)
    }
}
