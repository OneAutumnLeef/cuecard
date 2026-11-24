import Foundation
import Testing
@testable import PrompterCore

@Suite("Handoff links and PowerPoint notes")
struct HandoffTests {
    func cmd(_ s: String) -> URLCommand? { URLCommand.parse(URL(string: s)!) }

    @Test func parsesLinks() {
        #expect(cmd("notchprompter://add?title=Pitch&text=Hello%20there&start=1")
                == .add(title: "Pitch", source: .text("Hello there"), start: true))
        #expect(cmd("notchprompter://add?inbox=AB12.md") == .add(title: "Untitled", source: .inbox("AB12.md"), start: false))
        #expect(cmd("notchprompter://open?title=Q3%20Review") == .open(title: "Q3 Review", start: false))
        #expect(cmd("notchprompter://toggle") == .toggle)
        #expect(cmd("NotchPrompter://START") == .play)
        #expect(cmd("notchprompter://mode?voice=0") == .mode(voice: false))
        #expect(cmd("notchprompter://mode?voice=on") == .mode(voice: true))
    }

    @Test func rejectsUnsafeOrIncompleteLinks() {
        #expect(cmd("notchprompter://add?inbox=../../etc/passwd") == nil)
        #expect(cmd("notchprompter://add?inbox=.hidden.md") == nil)
        #expect(cmd("notchprompter://add?inbox=notes.sh") == nil)
        #expect(cmd("notchprompter://add?title=Empty") == nil)
        #expect(cmd("notchprompter://open") == nil)
        #expect(cmd("notchprompter://format-disk") == nil)
        #expect(cmd("https://example.com/add?text=hi") == nil)
    }

    @Test func titlesAreCleaned() {
        #expect(cmd("notchprompter://add?title=a/b&text=x") == .add(title: "a-b", source: .text("x"), start: false))
    }

    @Test func extractsSpeakerNotesInSlideOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ xml: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        }
        let ns = #"xmlns:p="p" xmlns:a="a" xmlns:r="r""#
        // Presentation order is slide2 then slide1 (rId order), to prove order comes from presentation.xml.
        try write("ppt/presentation.xml", #"<p:presentation \#(ns)><p:sldIdLst><p:sldId id="256" r:id="rId8"/><p:sldId id="257" r:id="rId7"/><p:sldId id="258" r:id="rId9"/></p:sldIdLst></p:presentation>"#)
        try write("ppt/_rels/presentation.xml.rels", #"<Relationships><Relationship Id="rId7" Type="x/slide" Target="slides/slide1.xml"/><Relationship Id="rId8" Type="x/slide" Target="slides/slide2.xml"/><Relationship Id="rId9" Type="x/slide" Target="slides/slide3.xml"/></Relationships>"#)
        for k in 1...3 {
            try write("ppt/slides/slide\(k).xml", "<p:sld \(ns)/>")
        }
        try write("ppt/slides/_rels/slide1.xml.rels", #"<Relationships><Relationship Id="rId2" Type="http://x/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>"#)
        try write("ppt/slides/_rels/slide2.xml.rels", #"<Relationships><Relationship Id="rId2" Type="http://x/relationships/notesSlide" Target="../notesSlides/notesSlide2.xml"/></Relationships>"#)
        try write("ppt/slides/_rels/slide3.xml.rels", #"<Relationships/>"#)     // no notes
        func notes(_ body: String) -> String {
            #"<p:notes \#(ns)><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody>\#(body)</p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>7</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"#
        }
        try write("ppt/notesSlides/notesSlide1.xml", notes("<a:p><a:r><a:t>Second slide </a:t></a:r><a:r><a:t>notes.</a:t></a:r></a:p>"))
        try write("ppt/notesSlides/notesSlide2.xml", notes("<a:p><a:r><a:t>Open with the story.</a:t></a:r></a:p><a:p><a:r><a:t>Then the numbers.</a:t></a:r></a:p>"))
        let text = try PptxNotes.extract(fromUnzipped: root)
        #expect(text == "[Slide 1]\nOpen with the story.\nThen the numbers.\n\n[Slide 2]\nSecond slide notes.")
    }
}
