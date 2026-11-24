import Foundation
import Testing
@testable import PrompterCore

@Suite("Script library")
struct LibraryTests {
    func makeStore() -> Store {
        Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mactele-lib-\(UUID().uuidString)"))
    }

    func lib(_ store: Store) -> ScriptLibrary {
        var l = store.library
        l.useTrash = false
        return l
    }

    @Test func createSaveLoadAndUniqueNames() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let l = lib(store)
        #expect(l.list().isEmpty)
        let a = try l.create(title: "Pitch", text: "one")
        let b = try l.create(title: "Pitch", text: "two")
        let c = try l.create(title: "  ", text: "three")
        #expect(a.id == "Pitch")
        #expect(b.id == "Pitch 2")
        #expect(c.id == "Untitled")
        #expect(l.load("Pitch 2") == "two")
        try l.save("Pitch", text: "changed")
        #expect(l.load("Pitch") == "changed")
        #expect(Set(l.list().map(\.id)) == ["Pitch", "Pitch 2", "Untitled"])
    }

    @Test func listIsNewestFirst() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let l = lib(store)
        try l.create(title: "Old", text: "x")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: l.url("Old").path)
        try l.create(title: "New", text: "y")
        #expect(l.list().map(\.id) == ["New", "Old"])
    }

    @Test func renameAndDelete() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let l = lib(store)
        try l.create(title: "Draft", text: "hello")
        try l.create(title: "Final", text: "taken")
        #expect(try l.rename("Draft", to: "Final") == "Final 2")      // never overwrites
        #expect(l.load("Final 2") == "hello")
        #expect(try l.rename("Final 2", to: "a/b: c") == "a-b- c")     // unsafe characters replaced
        #expect(try l.rename("a-b- c", to: "   ") == "a-b- c")         // empty title ignored
        try l.delete("a-b- c")
        #expect(!l.contains("a-b- c"))
        #expect(l.list().map(\.id) == ["Final"])
    }

    @Test func migratesTheOldSingleScript() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.saveScript("My own talk about pricing.")
        let current = try store.migrateToLibrary(welcomeText: "Welcome to Notch Prompter. New text.")
        #expect(current == "My Script")
        #expect(Set(store.library.list().map(\.id)) == ["Welcome", "My Script"])
        #expect(store.library.load("My Script") == "My own talk about pricing.")
        // Running again changes nothing.
        #expect(try store.migrateToLibrary(welcomeText: "x") == store.library.list().first?.id)
        #expect(store.library.list().count == 2)
    }

    @Test func oldWelcomeTextIsReplacedNotKept() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.saveScript("Welcome to Notch Prompter. The highlighted word moves at a steady pace.")
        let current = try store.migrateToLibrary(welcomeText: "Welcome to Notch Prompter. New text.")
        #expect(current == "Welcome")
        #expect(store.library.list().map(\.id) == ["Welcome"])
        #expect(store.library.load("Welcome") == "Welcome to Notch Prompter. New text.")
    }
}
