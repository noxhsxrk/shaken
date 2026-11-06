import Foundation
import Testing
@testable import ShakenCore

@Suite struct KeyComboTests {
    @Test func parsesWords() {
        let k = KeyCombo("cmd+shift+4")
        #expect(k?.keyCode == 21)
        #expect(k?.modifiers == [.command, .shift])
        #expect(k?.display == "⇧⌘4")
    }

    @Test func parsesGlyphsAndNamedKeys() {
        #expect(KeyCombo("⌃⌥T")?.modifiers == [.control, .option])
        #expect(KeyCombo("⌃⌥T")?.keyCode == 17)
        #expect(KeyCombo("F5")?.keyCode == 96)
        #expect(KeyCombo("ctrl + left")?.display == "⌃←")
        #expect(KeyCombo("cmd+space")?.keyCode == 49)
    }

    @Test func rejectsNonsense() {
        #expect(KeyCombo("") == nil)
        #expect(KeyCombo("cmd+") == nil)
        #expect(KeyCombo("cmd+shift") == nil)
        #expect(KeyCombo("a+b") == nil)
        #expect(KeyCombo("hyper+k") == nil)
    }
}

@Suite struct NewSlotKindTests {
    @Test func validationKeepsWorkflowStepsOnly() {
        var s = ShakenSettings()
        s.slots[0] = Slot(kind: .workflow, children: [
            Slot(kind: .app, target: "/Applications/Safari.app"),
            Slot(kind: .submenu),
            Slot(kind: .keys, target: "cmd+shift+4"),
            Slot(kind: .keys, target: "nonsense+"),
        ])
        let v = s.validated()
        #expect(v.slots[0].children.map(\.kind) == [.app, .keys])
    }

    @Test func containersCantNest() {
        var s = ShakenSettings()
        s.slots[0] = Slot(kind: .submenu, children: [Slot(kind: .switcher), Slot(kind: .workflow)])
        #expect(s.validated().slots[0].children.map(\.kind) == [.empty, .empty])
    }

    @Test func appWheelReplacesMainWheelWithoutDragging() throws {
        var s = ShakenSettings()
        s.appWheels["com.apple.Safari"] = AppWheel(name: "Safari", slots: [Slot(kind: .snippet, target: "hello")])
        let v = s.validated()
        #expect(v.appWheels["com.apple.Safari"]?.slots.count == ShakenSettings.slotCount)
        #expect(v.clickSlots(frontApp: "com.apple.Safari").first?.kind == .snippet)
        #expect(v.clickSlots(frontApp: "com.apple.finder") == v.slots)
        #expect(v.clickSlots(frontApp: nil) == v.slots)

        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(ShakenSettings.self, from: data) == v)
    }

    @Test func typingSlotsAreOffWhileDragging() {
        var s = ShakenSettings()
        s.slots = [Slot(kind: .snippet, target: "Hi\nthere"), Slot(kind: .keys, target: "cmd+k"),
                   Slot(kind: .shortcut, target: "Resize"), Slot(kind: .file, target: "/etc/hosts"),
                   Slot(kind: .switcher), Slot(kind: .workflow, children: [Slot(kind: .web, target: "https://a.b")])]
        s = s.validated()
        let drag = ActionResolver.layout(payload: ActionResolver.samplePayload(for: .image), actions: [], settings: s)
        #expect(drag.map(\.enabled) == [false, false, true, false, true, false])
        let click = ActionResolver.layout(payload: DragPayload([]), actions: [], settings: s)
        #expect(click.map(\.enabled) == [true, true, true, true, true, true])
        #expect(click[0].title == "Hi")
        #expect(click[1].title == "⌘K")
        #expect(click[3].icon == "/etc/hosts")
    }

    @Test func layoutUsesGivenWheel() {
        let s = ShakenSettings()
        let other = (0..<6).map { _ in Slot(kind: .keys, target: "f1") }
        let r = ActionResolver.layout(payload: DragPayload([]), actions: [], settings: s, slots: other)
        #expect(r.allSatisfy { $0.kind == .keys })
    }
}

@Suite struct ScriptAndSystemTests {
    @Test func systemAndDelayValidation() {
        var s = ShakenSettings()
        s.slots[0] = Slot(kind: .system, target: "mute")
        s.slots[1] = Slot(kind: .system, target: "self-destruct")
        s.slots[2] = Slot(kind: .delay, target: "1")          // not allowed on the wheel itself
        s.slots[3] = Slot(kind: .workflow, children: [
            Slot(kind: .delay, target: "99"), Slot(kind: .delay, target: "soon"), Slot(kind: .shell, target: "true"),
        ])
        let v = s.validated()
        #expect(v.slots[0].kind == .system)
        #expect(v.slots[1].kind == .empty)
        #expect(v.slots[2].kind == .empty)
        #expect(v.slots[3].children.map(\.kind) == [.delay, .shell])
        #expect(v.slots[3].children[0].target == "30.0")
    }

    @Test func workflowsHoldTwelveSteps() {
        var s = ShakenSettings()
        s.slots[0] = Slot(kind: .workflow, children: (0..<20).map { _ in Slot(kind: .system, target: "mute") })
        #expect(s.validated().slots[0].children.count == ShakenSettings.maxWorkflowSteps)
    }

    @Test func shellGetsFilesAsArguments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        try "x".write(to: a, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out")
        try await InlineScript.run("echo \"$1|$#\" > '\(out.path)'", language: .shell, input: .files([a]))
        #expect(try String(contentsOf: out, encoding: .utf8) == "\(a.path)|1\n")
    }

    @Test func failingScriptReportsStderr() async {
        await #expect(throws: ShakenError.self) {
            try await InlineScript.run("echo boom >&2; exit 3", language: .shell)
        }
    }
}

@Suite struct WheelPresetTests {
    @Test func roundTripsWithFreshIDs() throws {
        let slots = [Slot(id: "x", kind: .shell, title: "Hi", target: "echo hi"), Slot(kind: .web, target: "https://a.b")]
        let p = WheelPreset(name: "Mine", app: "com.apple.Safari", slots: slots)
        let back = try WheelPreset.decode(p.encoded())
        #expect(back.name == "Mine")
        #expect(back.app == "com.apple.Safari")
        #expect(back.slots.count == ShakenSettings.slotCount)
        #expect(back.slots[0].id != "x")
        #expect(back.sensitiveSlots.map(\.target) == ["echo hi"])
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: ShakenError.self) { try WheelPreset.decode(Data("{\"slots\":[]}".utf8)) }
        #expect(throws: ShakenError.self) { try WheelPreset.decode(Data("nope".utf8)) }
    }

    @Test func importIsValidated() throws {
        let json = """
        {"format":"shaken.wheel","version":1,"name":"x","slots":[
          {"id":"a","kind":"keys","title":"","icon":"","target":"not a key","children":[]},
          {"id":"a","kind":"submenu","title":"","icon":"","target":"","children":[
            {"id":"c","kind":"workflow","title":"","icon":"","target":"","children":[]}]}]}
        """
        let p = try WheelPreset.decode(Data(json.utf8))
        #expect(p.slots[0].kind == .empty)
        #expect(p.slots[1].children.first?.kind == .empty)
    }
}

@Suite struct NamedWheelTests {
    @Test func blankWheelsAreValidatedAndNamed() throws {
        var s = ShakenSettings()
        s.wheels = [NamedWheel(id: "a", name: "  ", slots: [Slot(kind: .system, target: "mute")]),
                    NamedWheel(id: "a", name: "Work")]
        let v = s.validated()
        #expect(v.wheels.count == 2)
        #expect(v.wheels[0].name == "Wheel 2")
        #expect(v.wheels[0].slots.count == ShakenSettings.slotCount)
        #expect(v.wheels[0].slots[0].kind == .system)
        #expect(v.wheels[0].id != v.wheels[1].id)
        #expect(try JSONDecoder().decode(ShakenSettings.self, from: JSONEncoder().encode(v)) == v)
    }

    @Test func olderSettingsWithoutWheelsStillLoad() throws {
        let json = #"{"version":1,"slots":[]}"#
        #expect(try JSONDecoder().decode(ShakenSettings.self, from: Data(json.utf8)).wheels.isEmpty)
    }
}

@Suite struct UpdateCheckTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateCheck.isNewer("v0.10.0", than: "0.9.3"))
        #expect(UpdateCheck.isNewer("0.2", than: "0.1.9"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1"))
        #expect(!UpdateCheck.isNewer("v0.1.0", than: "0.2.0"))
        #expect(UpdateCheck.isNewer("1.0.0-beta", than: "0.9"))
    }

    @Test func readsReleaseJSON() {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/noxhsxrk/shaken/releases/tag/v0.2.0","body":"Notes","draft":false,"prerelease":false}"#
        let r = UpdateCheck.parse(Data(json.utf8))
        #expect(r?.version == "0.2.0")
        #expect(r?.notes == "Notes")
        #expect(UpdateCheck.parse(Data(#"{"tag_name":"v9","prerelease":true}"#.utf8)) == nil)
    }
}

@Suite struct HotKeyTests {
    @Test func buildsFromKeyPress() throws {
        let hk = try HotKeySetting.make(keyCode: 40, modifiers: HotKeySetting.cmd | HotKeySetting.shift).get()
        #expect(hk.display == "⇧⌘K")
        #expect(try HotKeySetting.make(keyCode: 49, modifiers: HotKeySetting.control | HotKeySetting.option).get() == .default)
        #expect(try HotKeySetting.make(keyCode: 96, modifiers: 0).get().display == "F5")
    }

    @Test func refusesPlainTyping() {
        #expect(throws: ShakenError.self) { try HotKeySetting.make(keyCode: 40, modifiers: 0).get() }
        #expect(throws: ShakenError.self) { try HotKeySetting.make(keyCode: 40, modifiers: HotKeySetting.shift).get() }
    }

    @Test func wheelShortcutsCantRepeat() throws {
        var s = ShakenSettings()
        let k = try HotKeySetting.make(keyCode: 18, modifiers: HotKeySetting.control | HotKeySetting.option).get()
        s.wheels = [NamedWheel(name: "A", hotKey: k), NamedWheel(name: "B", hotKey: k), NamedWheel(name: "C", hotKey: .default)]
        let v = s.validated()
        #expect(v.wheels[0].hotKey == k)
        #expect(!v.wheels[1].hotKey.isSet)
        #expect(!v.wheels[2].hotKey.isSet)   // same as the main shortcut
    }
}
