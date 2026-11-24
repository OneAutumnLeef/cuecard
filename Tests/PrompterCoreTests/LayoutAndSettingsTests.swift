import Foundation
import Testing
@testable import PrompterCore

@Suite("Line layout")
struct LayoutTests {
    // Every character is 10 points wide, a space is 10 points.
    func wrap(_ text: String, width: Double) -> [[String]] {
        let s = Script(text: text)
        let lines = LineLayout.wrap(s.tokens, maxWidth: width, spaceWidth: 10) { Double(s.tokens[$0].text.count) * 10 }
        return lines.map { $0.map { s.tokens[$0].text } }
    }

    @Test func wrapsGreedily() {
        #expect(wrap("aa bb cc dd", width: 50) == [["aa", "bb"], ["cc", "dd"]])
        #expect(wrap("aa bb cc dd", width: 49) == [["aa"], ["bb"], ["cc"], ["dd"]])
    }

    @Test func paragraphsStartNewLines() {
        #expect(wrap("aa\nbb cc", width: 1000) == [["aa"], ["bb", "cc"]])
    }

    @Test func overlongWordGetsItsOwnLine() {
        #expect(wrap("a enormousword b", width: 50) == [["a"], ["enormousword"], ["b"]])
    }

    @Test func lineIndexMapsTokensToLines() {
        let lines = [[0, 1], [2], [3, 4]]
        #expect(LineLayout.lineIndex(of: lines, tokenCount: 5) == [0, 0, 1, 2, 2])
    }
}

@Suite("Settings and storage")
struct SettingsTests {
    @Test func roundTripsThroughJSON() throws {
        var s = PrompterSettings()
        s.fontSize = 30
        s.highlightStyle = .pill
        s.highlightColor = RGBA(0.1, 0.2, 0.3)
        let back = try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let s = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"fontSize": 30}"#.utf8))
        #expect(s.fontSize == 30)
        #expect(s.panelWidth == PrompterSettings().panelWidth)
        #expect(s.hideFromScreenShare)
    }

    @Test func badValuesAreClampedOrIgnored() throws {
        let json = #"{"fontSize": 400, "visibleLines": 0, "wpm": 2, "highlightStyle": "sparkles"}"#
        let s = try JSONDecoder().decode(PrompterSettings.self, from: Data(json.utf8))
        #expect(s.fontSize == 44)
        #expect(s.visibleLines == 1)
        #expect(s.wpm == AutoScroller.minWPM)
        #expect(s.highlightStyle == .color)
    }

    @Test func hexColours() {
        #expect(RGBA(hex: "#FFCC40")?.hex == "#FFCC40")
        #expect(RGBA(hex: "00000080")?.a ?? 0 > 0.49)
        #expect(RGBA(hex: "nope") == nil)
    }

    @Test func storeSavesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactele-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        #expect(store.loadScript() == nil)
        #expect(store.loadSettings() == PrompterSettings())
        var s = PrompterSettings()
        s.wpm = 180
        try store.save(s)
        try store.saveScript("Hello [PAUSE] world.")
        #expect(store.loadSettings().wpm == 180)
        #expect(store.loadScript() == "Hello [PAUSE] world.")
    }
}

@Suite("Presets and new settings")
struct PresetTests {
    @Test func presetsChangeLookButNotBehaviour() {
        var s = PrompterSettings()
        s.wpm = 190; s.scrollMode = .fixed; s.speechLocale = "en-IN"; s.displayMode = .floating; s.mirror = true
        for p in LookPreset.all {
            let out = p.applied(to: s)
            #expect(out.wpm == 190 && out.scrollMode == .fixed && out.speechLocale == "en-IN")
            #expect(out.displayMode == .floating && out.mirror && out.hideFromScreenShare)
            #expect(p.matches(out))
        }
        #expect(LookPreset.all.first!.applied(to: s).fontSize == PrompterSettings().fontSize)
        #expect(LookPreset.all[3].applied(to: s).visibleLines == 2)
        #expect(!LookPreset.all[3].matches(PrompterSettings()))
        #expect(Set(LookPreset.all.map(\.id)).count == LookPreset.all.count)
    }

    @Test func newSettingsRoundTripAndDefault() throws {
        var s = PrompterSettings()
        s.displayMode = .floating; s.screenName = "LG UltraFine"; s.mirror = true
        s.floatingX = 120; s.floatingY = 700; s.currentScriptID = "Pitch"
        let back = try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let old = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"fontSize": 24}"#.utf8))
        #expect(old.displayMode == .notch && !old.mirror && old.floatingX == nil && old.currentScriptID.isEmpty)
    }
}
