import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ShakenCore

struct TOMLTests {
    @Test func parsesTheReadmeExample() throws {
        let t = try TOML.parse("""
        # comment
        name = "เตรียมขึ้นเว็บ"
        icon = "globe"
        accepts = ["public.image"]   # trailing comment
        requires = [
          "cwebp",
        ]
        run = "./web-ready.sh"
        max = 3
        on = true
        """)
        #expect(t["name"]?.string == "เตรียมขึ้นเว็บ")
        #expect(t["accepts"]?.stringArray == ["public.image"])
        #expect(t["requires"]?.stringArray == ["cwebp"])
        #expect(t["max"]?.int == 3)
        #expect(t["on"]?.bool == true)
    }

    @Test func stringsAndTables() throws {
        let t = try TOML.parse(#"""
        a = "tab\there \"q\" \u0E01"
        b = 'C:\raw'
        c = """
        line1
        line2"""
        [names]
        th = "ไทย"
        x.y = 1
        inline = { k = "v" }
        """#)
        #expect(t["a"]?.string == "tab\there \"q\" ก")
        #expect(t["b"]?.string == #"C:\raw"#)
        #expect(t["c"]?.string == "line1\nline2")
        #expect(t["names"]?.table?["th"]?.string == "ไทย")
        #expect(t["names"]?.table?["x"]?.table?["y"]?.int == 1)
        #expect(t["names"]?.table?["inline"]?.table?["k"]?.string == "v")
    }

    @Test func errorsCarryLineNumbers() {
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\nb = \"open") }
        do { _ = try TOML.parse("a = 1\nb = nope") } catch let e as TOMLError { #expect(e.line == 2) } catch { Issue.record("wrong error") }
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\na = 2") }
    }
}

struct ManifestTests {
    @Test func builtinsParseWithTheSameModel() {
        let all = ActionRegistry.builtins()
        #expect(all.count == 14)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.allSatisfy { $0.source == .builtin && !$0.steps.isEmpty })
    }

    @Test func runAndSteps() throws {
        let a = try ActionManifest.parse(toml: #"name = "x"\#nrun = "./a.sh""#, id: "x", directory: nil, source: .local)
        #expect(a.steps == [.script("./a.sh")])
        #expect(a.accepts == [Pseudo.any])
        let b = try ActionManifest.parse(toml: #"name = "x"\#nsteps = ["resize:1920", "strip-metadata", "./to-webp.sh"]"#, id: "x", directory: nil, source: .local)
        #expect(b.steps == [.builtin(name: "resize", arg: "1920"), .builtin(name: "strip-metadata", arg: nil), .script("./to-webp.sh")])
    }

    @Test func rejectsBadManifests() {
        #expect(throws: ShakenError.self) { try ActionManifest.parse(toml: #"run = "./a.sh""#, id: "x", directory: nil, source: .local) }
        #expect(throws: ShakenError.self) { try ActionManifest.parse(toml: #"name = "x""#, id: "x", directory: nil, source: .local) }
        #expect(throws: ShakenError.self) { try ActionManifest.parse(toml: "name = \"x\"\nrun = \"./a\"\nsteps = [\"zip\"]", id: "x", directory: nil, source: .local) }
        #expect(throws: ShakenError.self) { try ActionManifest.parse(toml: "name = \"x\"\nsteps = [\"rezise:10\"]", id: "x", directory: nil, source: .local) }
        #expect(throws: ShakenError.self) { try ActionManifest.parse(toml: "name = \"x\"\nsteps = [\"copy-names\", \"zip\"]", id: "x", directory: nil, source: .local) }
    }

    @Test func missingRequirementsAreReported() throws {
        let a = try ActionManifest.parse(toml: "name = \"x\"\nrequires = [\"definitely-not-a-tool-zz\", \"sh\"]\nrun = \"true\"", id: "x", directory: nil, source: .local)
        #expect(a.missingRequirements() == ["definitely-not-a-tool-zz"])
        #expect(a.installHint == "brew install definitely-not-a-tool-zz")
    }
}

func item(_ ext: String) -> DragItem {
    DragItem(kind: .file, url: URL(fileURLWithPath: "/tmp/a.\(ext)"), types: [UTType(filenameExtension: ext)!.identifier], displayName: "a.\(ext)")
}

struct ResolverTests {
    let actions = ActionRegistry.builtins()
    let settings = ShakenSettings()

    func ids(_ p: DragPayload) -> [String] {
        ActionResolver.suggestions(for: p, actions: actions, settings: settings).map(\.id)
    }

    @Test func defaultsMatchThePRDTable() {
        #expect(ids(DragPayload([item("heic")])) == ["builtin.to-jpg", "builtin.shrink", "builtin.strip-metadata", "builtin.open-preview", "builtin.copy-names"])
        #expect(ids(DragPayload([item("png")])) == ["builtin.to-jpg", "builtin.shrink", "builtin.strip-metadata", "builtin.open-preview", "builtin.copy-names"])
        #expect(ids(DragPayload([item("jpg")])) == ["builtin.shrink", "builtin.strip-metadata", "builtin.to-pdf", "builtin.open-preview", "builtin.copy-names"])
        #expect(ids(DragPayload([item("pdf")])) == ["builtin.split-pdf", "builtin.open-preview", "builtin.copy-names"])
        #expect(ids(DragPayload([item("jpg"), item("pdf")])) == ["builtin.zip", "builtin.merge-pdf", "builtin.copy-names"])
        #expect(ids(DragPayload([item("jpg"), item("zip")])) == ["builtin.zip", "builtin.copy-names"])
        let folder = DragItem(kind: .folder, url: URL(fileURLWithPath: "/tmp"), types: [UTType.folder.identifier], displayName: "tmp")
        #expect(ids(DragPayload([folder])) == ["builtin.zip", "builtin.copy-names"])
        #expect(ids(DragPayload([.link(URL(string: "https://example.com")!)])) == ["builtin.open-link", "builtin.copy-link", "builtin.qr"])
        #expect(ids(DragPayload([.text("hello")])) == ["builtin.save-text", "builtin.copy-text"])
    }

    @Test func promisesResolveByTheirTypes() {
        #expect(ids(DragPayload([.promise(types: ["public.heic"])])).first == "builtin.to-jpg")
    }

    @Test func userOrderAndHiddenPerKind() {
        var s = settings
        s.kindPreferences[KindKey.image.rawValue] = KindPreference(order: ["builtin.open-preview"], hidden: ["builtin.strip-metadata"])
        let r = ActionResolver.suggestions(for: DragPayload([item("heic")]), actions: actions, settings: s).map(\.id)
        #expect(r == ["builtin.open-preview", "builtin.to-jpg", "builtin.shrink", "builtin.copy-names"])
        // Other kinds are unaffected.
        #expect(ActionResolver.suggestions(for: DragPayload([item("jpg")]), actions: actions, settings: s).map(\.id).contains("builtin.strip-metadata"))
    }

    @Test func layoutFillsAutoSlotsAndKeepsFixedOnes() {
        var s = settings
        s.slots[0] = Slot(id: "fixed", kind: .folder, target: "/Users/me/Desktop")
        s.slots[5] = Slot(id: "pinned", kind: .action, target: "builtin.copy-names")
        let l = ActionResolver.layout(payload: DragPayload([item("heic")]), actions: actions, settings: s)
        #expect(l.count == 6)
        #expect(l[0].kind == .folder && l[0].title == "Desktop" && l[0].enabled)
        #expect(l[1...4].map(\.actionID) == ["builtin.to-jpg", "builtin.shrink", "builtin.strip-metadata", "builtin.open-preview"])
        #expect(l[5].actionID == "builtin.copy-names")
    }

    @Test func layoutIsStableForTheSameDrag() {
        let p = DragPayload([item("heic")])
        #expect(ActionResolver.layout(payload: p, actions: actions, settings: settings) == ActionResolver.layout(payload: p, actions: actions, settings: settings))
    }

    @Test func emptySlotsWhenNothingMatches() {
        let l = ActionResolver.layout(payload: DragPayload([.text("x")]), actions: actions, settings: settings)
        #expect(l.filter(\.enabled).count == 2)
        #expect(l[2].kind == .empty)
    }

    @Test func disabledFixedActionThatDoesNotFit() {
        var s = settings
        s.slots[0] = Slot(kind: .action, target: "builtin.split-pdf")
        let l = ActionResolver.layout(payload: DragPayload([item("jpg")]), actions: actions, settings: s)
        #expect(l[0].enabled == false)
    }

    @Test func submenuChildrenTakeSuggestionsToo() {
        var s = settings
        s.slots = [Slot(kind: .submenu, title: "More", children: [Slot(kind: .auto), Slot(kind: .auto)])] + (1..<6).map { _ in Slot(kind: .empty) }
        let l = ActionResolver.layout(payload: DragPayload([item("heic")]), actions: actions, settings: s)
        #expect(l[0].children.map(\.actionID) == ["builtin.to-jpg", "builtin.shrink"])
        #expect(l[0].enabled)
    }
}

struct SettingsTests {
    @Test func validationRepairsShape() {
        var s = ShakenSettings()
        s.slots = [Slot(id: "a", kind: .submenu, children: (0..<9).map { _ in Slot(kind: .submenu) }), Slot(id: "a", kind: .app, target: "")]
        s.gesture.sensitivity = 99
        s.shrinkTargetKB = 1
        let v = s.validated()
        #expect(v.slots.count == 6)
        #expect(v.slots[0].children.count == 6)
        #expect(v.slots[0].children.allSatisfy { $0.kind == .empty })
        #expect(v.slots[1].id != "a")
        #expect(v.slots[1].kind == .empty)
        #expect(v.gesture.sensitivity == 5)
        #expect(v.shrinkTargetKB == 50)
        #expect(Set(v.slots.map(\.id)).count == 6)
    }

    @Test func roundTripsAndToleratesOldOrBrokenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")

        let store = SettingsStore(url: url)
        store.update { $0.excludedApps = ["com.example.app"]; $0.gesture.sensitivity = 4 }
        #expect(SettingsStore(url: url).settings == store.settings)

        try Data(#"{"version":1,"gesture":{"sensitivity":2}}"#.utf8).write(to: url)
        let partial = SettingsStore(url: url).settings
        #expect(partial.gesture.sensitivity == 2)
        #expect(partial.slots.count == 6)

        try Data(#"{"version":99}"#.utf8).write(to: url)
        #expect(SettingsStore(url: url).settings == ShakenSettings())
        try Data("garbage".utf8).write(to: url)
        #expect(SettingsStore(url: url).settings == ShakenSettings())
    }
}
