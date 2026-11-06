import Foundation
import Testing
@testable import ShakenCore

struct ShelfTests {
    func store(_ s: Sandbox) -> ShelfStore {
        ShelfStore(url: s.root.appendingPathComponent("shelf.json"), filesDir: s.root.appendingPathComponent("ShelfFiles"))
    }

    @Test func addPersistsAndDeduplicates() throws {
        let s = try Sandbox()
        let a = try s.image("a.png"), b = try s.image("b.png")
        let shelf = store(s)
        shelf.add(.files([a, b]))
        shelf.add(.files([a]))
        shelf.add(.link(URL(string: "https://example.com")!))
        shelf.add(.text("hello"))
        #expect(shelf.items.map(\.kind) == [.file, .file, .link, .text])
        #expect(store(s).items == shelf.items)
    }

    @Test func movedFilesDropOff() throws {
        let s = try Sandbox()
        let a = try s.image("a.png")
        let shelf = store(s)
        shelf.add(.files([a]))
        try FileManager.default.removeItem(at: a)
        shelf.pruneMissing()
        #expect(shelf.isEmpty)
    }

    @Test func removeNeverTouchesFilesElsewhere() throws {
        let s = try Sandbox()
        let a = try s.image("a.png")
        let shelf = store(s)
        shelf.add(.files([a]))
        shelf.clear()
        shelf.cleanOrphans()
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func orphanedOwnFilesAreCleanedButUsedOnesKept() throws {
        let s = try Sandbox()
        let dir = s.root.appendingPathComponent("ShelfFiles")
        let keep = try s.image("keep.png", in: try mk(dir.appendingPathComponent("k")))
        let gone = try s.image("gone.png", in: try mk(dir.appendingPathComponent("g")))
        let shelf = store(s)
        shelf.add(.files([keep, gone]))
        shelf.remove([shelf.items[1].id])
        #expect(FileManager.default.fileExists(atPath: gone.path))   // still readable right after a drop
        shelf.cleanOrphans()
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("g").path))
    }

    @Test func inputPrefersFiles() throws {
        let s = try Sandbox()
        let a = try s.image("a.png")
        let shelf = store(s)
        shelf.add(.text("t"))
        #expect(shelf.jobInput == .text("t"))
        shelf.add(.files([a]))
        #expect(shelf.jobInput == .files([a.standardizedFileURL]))
        #expect(shelf.payload.items.count == 2)
    }

    @Test func capsItemCount() throws {
        let s = try Sandbox()
        let shelf = store(s)
        for i in 0..<(ShelfStore.maxItems + 5) { shelf.add(.text("t\(i)")) }
        #expect(shelf.items.count == ShelfStore.maxItems)
        #expect(shelf.items.first?.value == "t5")
    }

    func mk(_ u: URL) throws -> URL {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
}

struct FallbackTests {
    @Test func emptyAutoSlotsBecomeFolders() {
        let l = ActionResolver.layout(payload: DragPayload([]), actions: ActionRegistry.builtins(), settings: ShakenSettings(),
                                      fallbacks: ActionResolver.defaultFallbacks())
        #expect(l[0].kind == .folder && l[0].target == ShakenPaths.downloads.path && l[0].enabled)
        #expect(l[1].kind == .folder && l[1].target == ShakenPaths.desktop.path)
        #expect(l[2].kind == .empty)
        #expect(l[0].id == "slot-1")
    }

    @Test func suggestionsComeBeforeFallbacks() {
        let l = ActionResolver.layout(payload: DragPayload([.text("x")]), actions: ActionRegistry.builtins(), settings: ShakenSettings(),
                                      fallbacks: ActionResolver.defaultFallbacks())
        #expect(l[0].actionID == "builtin.save-text")
        #expect(l[2].kind == .folder)
    }

    @Test func noDuplicateOfAFolderAlreadyOnTheWheel() {
        var s = ShakenSettings()
        s.slots[5] = Slot(kind: .folder, target: ShakenPaths.downloads.path)
        let l = ActionResolver.layout(payload: DragPayload([]), actions: [], settings: s, fallbacks: ActionResolver.defaultFallbacks())
        #expect(l.filter { $0.target == ShakenPaths.downloads.path }.count == 1)
        #expect(l[0].target == ShakenPaths.desktop.path)
    }
}

@Suite struct ClipboardSuggestionTests {
    @Test func copyCommandsAreFlagged() {
        let ids = Set(ActionRegistry.builtins().filter(\.onlyCopiesText).map(\.id))
        #expect(ids == ["builtin.copy-text", "builtin.copy-link"])
    }
}
