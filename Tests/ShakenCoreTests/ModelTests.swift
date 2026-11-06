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
        #expect(all.count == 33)
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
        #expect(Array(ids(DragPayload([item("heic")])).prefix(5)) == ["builtin.to-jpg", "builtin.shrink", "builtin.strip-metadata", "builtin.open-preview", "builtin.copy-names"])
        #expect(Array(ids(DragPayload([item("png")])).prefix(5)) == ["builtin.to-jpg", "builtin.shrink", "builtin.strip-metadata", "builtin.open-preview", "builtin.copy-names"])
        #expect(Array(ids(DragPayload([item("jpg")])).prefix(5)) == ["builtin.shrink", "builtin.strip-metadata", "builtin.to-pdf", "builtin.open-preview", "builtin.copy-names"])
        #expect(Array(ids(DragPayload([item("pdf")])).prefix(3)) == ["builtin.split-pdf", "builtin.open-preview", "builtin.copy-names"])
        #expect(Array(ids(DragPayload([item("jpg"), item("pdf")])).prefix(3)) == ["builtin.zip", "builtin.merge-pdf", "builtin.copy-names"])
        #expect(Array(ids(DragPayload([item("jpg"), item("zip")])).prefix(2)) == ["builtin.zip", "builtin.copy-names"])
        let folder = DragItem(kind: .folder, url: URL(fileURLWithPath: "/tmp"), types: [UTType.folder.identifier], displayName: "tmp")
        #expect(Array(ids(DragPayload([folder])).prefix(2)) == ["builtin.zip", "builtin.copy-names"])
        #expect(Array(ids(DragPayload([.link(URL(string: "https://example.com")!)])).prefix(3)) == ["builtin.open-link", "builtin.copy-link", "builtin.qr"])
        #expect(Array(ids(DragPayload([.text("hello")])).prefix(2)) == ["builtin.save-text", "builtin.copy-text"])
    }

    @Test func promisesResolveByTheirTypes() {
        #expect(ids(DragPayload([.promise(types: ["public.heic"])])).first == "builtin.to-jpg")
    }

    @Test func userOrderAndHiddenPerKind() {
        var s = settings
        s.kindPreferences[KindKey.image.rawValue] = KindPreference(order: ["builtin.open-preview"], hidden: ["builtin.strip-metadata"])
        let r = ActionResolver.suggestions(for: DragPayload([item("heic")]), actions: actions, settings: s).map(\.id)
        #expect(Array(r.prefix(4)) == ["builtin.open-preview", "builtin.to-jpg", "builtin.shrink", "builtin.copy-names"])
        // JPGs share the images list.
        #expect(!ActionResolver.suggestions(for: DragPayload([item("jpg")]), actions: actions, settings: s).map(\.id).contains("builtin.strip-metadata"))
        // Other kinds are unaffected.
        var t = settings
        t.kindPreferences[KindKey.image.rawValue] = KindPreference(hidden: ["builtin.copy-names"])
        #expect(ActionResolver.suggestions(for: DragPayload([item("heic"), item("heic")]), actions: actions, settings: t).map(\.id).contains("builtin.copy-names"))
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
        // An app slot with no app chosen yet stays an app slot, disabled until it's set up.
        #expect(v.slots[1].kind == .app)
        #expect(ActionResolver.layout(payload: DragPayload([]), actions: [], settings: v)[1].enabled == false)
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

struct PlaceCommandTests {
    let actions = ActionRegistry.builtins()

    func wheel(_ s: ShakenSettings) -> [String?] {
        ActionResolver.layout(payload: ActionResolver.samplePayload(for: .image), actions: actions, settings: s).map(\.actionID)
    }

    @Test func pickingACommandSwapsItIntoTheSlot() {
        var s = ShakenSettings()
        let before = wheel(s)
        let all = ActionResolver.suggestions(for: ActionResolver.samplePayload(for: .image), actions: actions, settings: s).map(\.id)
        let extra = all[ShakenSettings.slotCount]   // not on the wheel yet
        ActionResolver.place(extra, inSlot: 2, for: .image, actions: actions, settings: &s)
        let after = wheel(s)
        #expect(after[2] == extra)
        for i in after.indices where i != 2 { #expect(after[i] == before[i]) }
    }

    @Test func pickingOneAlreadyShownSwapsTheTwoSlots() {
        var s = ShakenSettings()
        let before = wheel(s)
        ActionResolver.place(before[4]!, inSlot: 0, for: .image, actions: actions, settings: &s)
        let after = wheel(s)
        #expect(after[0] == before[4] && after[4] == before[0])
        #expect(after[1...3] == before[1...3])
    }

    @Test func pickingAHiddenCommandShowsItAgain() {
        var s = ShakenSettings()
        let id = wheel(s)[1]!
        s.kindPreferences[KindKey.image.rawValue] = KindPreference(hidden: [id])
        #expect(!wheel(s).contains(id))
        ActionResolver.place(id, inSlot: 1, for: .image, actions: actions, settings: &s)
        #expect(wheel(s)[1] == id)
    }

    @Test func jpgsShareTheImagesList() {
        let jpg = DragPayload([DragItem(kind: .file, url: URL(fileURLWithPath: "/tmp/a.jpg"), types: ["public.jpeg"], displayName: "a.jpg")])
        #expect(jpg.kindKey == .image)
        var s = ShakenSettings()
        let shown = ActionResolver.layout(payload: jpg, actions: actions, settings: s).map(\.actionID)
        #expect(!shown.contains("builtin.to-jpg"))
        let extra = ActionResolver.suggestions(for: jpg, actions: actions, settings: s).map(\.id)[ShakenSettings.slotCount]
        ActionResolver.place(extra, inSlot: 0, payload: jpg, wheel: s.slots, actions: actions, settings: &s)
        #expect(ActionResolver.layout(payload: jpg, actions: actions, settings: s).first?.actionID == extra)
    }

    @Test func anOldJPGOrderBecomesTheImagesOrder() {
        var s = ShakenSettings()
        s.kindPreferences["jpeg"] = KindPreference(order: ["builtin.strip-metadata"])
        let v = s.validated()
        #expect(v.kindPreferences["jpeg"] == nil)
        #expect(v.kindPreferences["image"]?.order == ["builtin.strip-metadata"])
    }

    @Test func placesOnAnExtraWheelToo() {
        var s = ShakenSettings()
        var extra = ShakenSettings.defaultSlots()
        extra[0] = Slot(kind: .app, target: "/Applications/Calendar.app")   // fixed, so slot 2 is Suggested #0
        let p = ActionResolver.samplePayload(for: .image)
        let all = ActionResolver.suggestions(for: p, actions: actions, settings: s).map(\.id)
        ActionResolver.place(all[ShakenSettings.slotCount], inSlot: 1, payload: p, wheel: extra, actions: actions, settings: &s)
        let r = ActionResolver.layout(payload: p, actions: actions, settings: s, slots: extra)
        #expect(r[1].actionID == all[ShakenSettings.slotCount])
    }

    @Test func aChangeOnAJPGOnlySwapsThoseTwoOnTheHEICWheel() {
        var s = ShakenSettings()
        let heic = ActionResolver.samplePayload(for: .image)
        let jpg = DragPayload([DragItem(kind: .file, url: URL(fileURLWithPath: "/tmp/a.jpg"), types: ["public.jpeg"], displayName: "a.jpg")])
        // Some order set through the HEIC wheel first.
        ActionResolver.place(ActionResolver.suggestions(for: heic, actions: actions, settings: s).map(\.id)[7], inSlot: 3, for: .image, actions: actions, settings: &s)
        let heicBefore = wheel(s)
        let jpgWheel = ActionResolver.layout(payload: jpg, actions: actions, settings: s).map(\.actionID)
        // On the JPG wheel, put the JPG's slot-5 command into slot 1.
        ActionResolver.place(jpgWheel[4]!, inSlot: 0, payload: jpg, wheel: s.slots, actions: actions, settings: &s)
        let heicAfter = wheel(s)
        let changed = heicAfter.indices.filter { heicAfter[$0] != heicBefore[$0] }
        #expect(changed.count <= 2)
        if changed.count == 2 { #expect(heicAfter[changed[0]] == heicBefore[changed[1]] && heicAfter[changed[1]] == heicBefore[changed[0]]) }
        #expect(ActionResolver.layout(payload: jpg, actions: actions, settings: s).first?.actionID == jpgWheel[4])
    }

    @Test func commandsTheWheelLeavesOutKeepTheirRank() {
        // The clipboard wheel leaves out Copy text / Copy link; picking there must not move them.
        var s = ShakenSettings()
        let link = ActionResolver.samplePayload(for: .link)
        let all = ActionResolver.suggestions(for: link, actions: actions, settings: s).map(\.id)
        let filtered = actions.filter { !$0.onlyCopiesText }
        let left = actions.filter(\.onlyCopiesText).map(\.id).filter { all.contains($0) }
        let offered = ActionResolver.suggestions(for: link, actions: filtered, settings: s).map(\.id)
        #expect(!left.isEmpty && offered.count >= 2)
        guard offered.count >= 2 else { return }
        ActionResolver.place(offered[1], inSlot: 0, payload: link, wheel: s.slots, actions: filtered, allActions: actions, settings: &s)
        #expect(ActionResolver.layout(payload: link, actions: filtered, settings: s).first?.actionID == offered[1])
        let after = ActionResolver.suggestions(for: link, actions: actions, settings: s).map(\.id)
        for id in left { #expect(after.firstIndex(of: id) == all.firstIndex(of: id)) }
    }

    @Test func suggestedIndexSkipsFixedSlots() {
        var slots = ShakenSettings.defaultSlots()
        slots[0] = Slot(kind: .app, target: "/Applications/Calendar.app")
        #expect(ActionResolver.suggestedIndex(ofSlot: 0, in: slots) == nil)
        #expect(ActionResolver.suggestedIndex(ofSlot: 3, in: slots) == 2)
    }
}

struct GlassTintTests {
    @Test func hexRoundTrips() {
        let c = GlassTint.rgb(fromHex: "#7D89ED")!
        #expect(GlassTint.hex(r: c.r, g: c.g, b: c.b) == "#7D89ED")
        #expect(GlassTint.rgb(fromHex: "zz") == nil)
    }

    @Test func oldSettingsFollowTheMacAndBadValuesAreFixed() throws {
        let old = try JSONDecoder().decode(ShakenSettings.self, from: Data("{}".utf8))
        #expect(old.glassTint == .system && old.glassTintStrength == 0.5)
        var s = ShakenSettings()
        s.glassTintStrength = 7
        s.glassTintHex = "nope"
        let v = s.validated()
        #expect(v.glassTintStrength == 1 && v.glassTintHex == GlassTint.shakenHex)
    }
}
