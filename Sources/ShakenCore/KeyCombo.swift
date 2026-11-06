import Foundation

/// A key combination typed as text, e.g. "cmd+shift+4", "⌃⌥T" or "F5".
public struct KeyCombo: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// macOS virtual key code (ANSI layout).
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var keyName: String

    static let modifierWords: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    static let keys: [String: UInt16] = {
        var k: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "↩": 36, "tab": 48, "⇥": 48, "space": 49, "delete": 51, "⌫": 51,
            "esc": 53, "escape": 53, "⎋": 53, "forwarddelete": 117, "⌦": 117,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "←": 123, "right": 124, "→": 124, "down": 125, "↓": 125, "up": 126, "↑": 126,
        ]
        let f: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f.enumerated() { k["f\(i + 1)"] = code }
        return k
    }()

    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !rest.isEmpty else { return nil }
        var mods: Modifiers = []
        // Leading symbol glyphs: ⌃⌥⇧⌘
        while let c = rest.first, let m = Self.modifierWords[String(c)], rest.count > 1 {
            mods.insert(m); rest.removeFirst()
        }
        let parts = rest.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var key: String?
        for (i, p) in parts.enumerated() {
            let word = p.isEmpty && i == parts.count - 1 ? "+" : p
            if let m = Self.modifierWords[word], i < parts.count - 1 { mods.insert(m); continue }
            guard key == nil, i == parts.count - 1 else { return nil }
            key = word
        }
        guard let name = key, let code = Self.keys[name] else { return nil }
        keyCode = code
        modifiers = mods
        keyName = name
    }

    /// "⌃⌥⇧⌘K"
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let named: [String: String] = ["return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "esc": "⎋",
                                       "escape": "⎋", "left": "←", "right": "→", "up": "↑", "down": "↓", "forwarddelete": "⌦"]
        return s + (named[keyName] ?? keyName.uppercased())
    }
}
