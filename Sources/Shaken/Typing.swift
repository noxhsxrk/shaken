import AppKit
import ApplicationServices
import ShakenCore

/// Pressing keys and pasting into the front app. Both need Accessibility permission,
/// which is asked for the first time a snippet or key slot is used.
enum Typing {
    /// True if Shaken may post key events. Shows the system prompt once when it may not.
    static func ensureTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var notTrustedError: ShakenError {
        .other(L("Allow Shaken under System Settings › Privacy & Security › Accessibility, then try again."))
    }

    static func press(_ combo: KeyCombo) {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Puts `text` on the clipboard, presses ⌘V, then puts back what was there before.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount
        press(KeyCombo("cmd+v")!)
        // Give the app time to read the clipboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == ourChange else { return }   // something else copied meanwhile
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

/// Carries out a System slot.
enum SystemActions {
    static func perform(_ c: SystemControl) async throws {
        if c.needsAccessibility && !Typing.ensureTrusted() { throw Typing.notTrustedError }
        switch c {
        case .volumeUp: try await osa("set volume output volume ((output volume of (get volume settings)) + 6)")
        case .volumeDown: try await osa("set volume output volume ((output volume of (get volume settings)) - 6)")
        case .mute: try await osa("set volume output muted (not (output muted of (get volume settings)))")
        case .brightnessUp: mediaKey(2)
        case .brightnessDown: mediaKey(3)
        case .playPause: mediaKey(16)
        case .nextTrack: mediaKey(17)
        case .previousTrack: mediaKey(18)
        case .screenshot: Typing.press(KeyCombo("cmd+shift+5")!)
        case .lockScreen: Typing.press(KeyCombo("ctrl+cmd+q")!)
        case .missionControl: try await run("/usr/bin/open", ["-a", "Mission Control"])
        case .screenSaver: try await run("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        case .displaySleep: try await run("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep: try await run("/usr/bin/pmset", ["sleepnow"])
        case .darkMode:
            // Asks once for permission to control System Events.
            try await osa("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        }
    }

    /// Hardware media keys (NX_KEYTYPE_*), as the keyboard's top row sends them.
    private static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func osa(_ script: String) async throws { try await InlineScript.run(script, language: .applescript) }

    private static func run(_ tool: String, _ args: [String]) async throws {
        let r = try await Subprocess.run(tool, args)
        if r.status != 0 { throw ShakenError.other(r.stderr.isEmpty ? L("“%@” failed.", tool) : r.stderr) }
    }
}
