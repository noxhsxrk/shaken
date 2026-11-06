import Foundation

/// What one wheel slot does (R3).
public enum SlotKind: String, Codable, CaseIterable, Sendable {
    /// Filled with a suggested action for whatever is being dragged (R5).
    case auto
    case empty
    case app
    case web
    case folder
    case action
    case submenu
}

public struct Slot: Codable, Equatable, Identifiable, Sendable {
    /// Stable id: survives reordering and renaming.
    public var id: String
    public var kind: SlotKind
    public var title: String
    /// SF Symbol name.
    public var icon: String
    /// app: path to .app · web: URL (may contain {query}) · folder: path · action: action id.
    public var target: String
    public var children: [Slot]

    public init(id: String = UUID().uuidString, kind: SlotKind, title: String = "", icon: String = "", target: String = "", children: [Slot] = []) {
        self.id = id; self.kind = kind; self.title = title; self.icon = icon; self.target = target; self.children = children
    }

    public static func auto() -> Slot { Slot(kind: .auto) }
}

public enum ModifierRequirement: String, Codable, CaseIterable, Sendable {
    case none, option, shift, control, command
}

public struct GestureSettings: Codable, Equatable, Sendable {
    /// 1 … 5
    public var sensitivity: Int = 3
    /// Optional key that must be held while shaking a drag.
    public var modifier: ModifierRequirement = .none
    /// ⌥ + shake without dragging opens the wheel (R2). Bare shake never does.
    public var optionShakeWithoutDrag: Bool = true
    public init() {}
}

public struct HotKeySetting: Codable, Equatable, Sendable {
    /// Carbon virtual key code; nil = no hot key.
    public var keyCode: UInt32?
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    public var modifiers: UInt32
    public var display: String

    /// ⌃⌥Space
    public static let `default` = HotKeySetting(keyCode: 49, modifiers: 0x1000 | 0x0800, display: "⌃⌥Space")
    public static let presets: [HotKeySetting] = [
        .default,
        HotKeySetting(keyCode: 49, modifiers: 0x1000 | 0x0200, display: "⌃⇧Space"),
        HotKeySetting(keyCode: 1, modifiers: 0x0100 | 0x0800, display: "⌥⌘S"),
        HotKeySetting(keyCode: nil, modifiers: 0, display: "—"),
    ]
}

public struct KindPreference: Codable, Equatable, Sendable {
    /// Action ids in the user's preferred order (unlisted ones follow in default order).
    public var order: [String] = []
    public var hidden: [String] = []
    public init(order: [String] = [], hidden: [String] = []) { self.order = order; self.hidden = hidden }
}

/// Everything the user can change. Stored as versioned JSON and validated on load and save.
public struct ShakenSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let slotCount = 6
    public static let maxChildren = 6

    public var version: Int = currentVersion
    public var slots: [Slot]
    public var gesture = GestureSettings()
    /// Bundle ids of apps where shaking a drag does nothing.
    public var excludedApps: [String] = []
    public var hotKey = HotKeySetting.default
    /// Target for "Shrink below size limit", in KB.
    public var shrinkTargetKB: Int = 1024
    public var kindPreferences: [String: KindPreference] = [:]
    /// Pack action id → (relative path → SHA-256) the user approved (R9).
    public var approvals: [String: [String: String]] = [:]

    public init(slots: [Slot] = ShakenSettings.defaultSlots()) { self.slots = slots }

    public static func defaultSlots() -> [Slot] {
        (0..<slotCount).map { i in Slot(id: "slot-\(i + 1)", kind: .auto) }
    }

    public func preference(for kind: KindKey) -> KindPreference { kindPreferences[kind.rawValue] ?? KindPreference() }

    /// Brings any decoded or edited value back into a shape the app can trust.
    public func validated() -> ShakenSettings {
        var s = self
        s.version = Self.currentVersion
        var seen = Set<String>()
        func fix(_ slot: Slot, depth: Int) -> Slot {
            var x = slot
            if x.id.isEmpty || !seen.insert(x.id).inserted { x.id = UUID().uuidString; seen.insert(x.id) }
            if depth > 0 && x.kind == .submenu { x.kind = .empty }   // one level of submenus only
            if x.kind == .submenu {
                x.children = Array(x.children.prefix(Self.maxChildren)).map { fix($0, depth: 1) }
            } else {
                x.children = []
            }
            if [.app, .web, .folder, .action].contains(x.kind) && x.target.trimmingCharacters(in: .whitespaces).isEmpty {
                x.kind = .empty
            }
            return x
        }
        var slots = Array(s.slots.prefix(Self.slotCount))
        while slots.count < Self.slotCount { slots.append(Slot(kind: .empty)) }
        s.slots = slots.map { fix($0, depth: 0) }
        s.gesture.sensitivity = min(max(s.gesture.sensitivity, 1), 5)
        s.shrinkTargetKB = min(max(s.shrinkTargetKB, 50), 100_000)
        s.excludedApps = Array(Set(s.excludedApps.filter { !$0.isEmpty })).sorted()
        for (k, v) in s.kindPreferences {
            if KindKey(rawValue: k) == nil { s.kindPreferences[k] = nil; continue }
            var p = v
            var seenIDs = Set<String>()
            p.order = p.order.filter { seenIDs.insert($0).inserted }
            p.hidden = Array(Set(p.hidden)).sorted()
            s.kindPreferences[k] = p
        }
        return s
    }
}

public final class SettingsStore {
    public let url: URL
    public private(set) var settings: ShakenSettings
    public var onChange: ((ShakenSettings) -> Void)?

    public init(url: URL = ShakenPaths.settings) {
        self.url = url
        self.settings = Self.load(url)
    }

    public static func load(_ url: URL) -> ShakenSettings {
        guard let data = try? Data(contentsOf: url) else { return ShakenSettings() }
        // Unknown future versions or broken files fall back to defaults rather than crash.
        guard let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = probe["version"] as? Int, v <= ShakenSettings.currentVersion,
              let decoded = try? JSONDecoder().decode(ShakenSettings.self, from: data)
        else {
            try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("broken.json"))
            return ShakenSettings()
        }
        return decoded.validated()
    }

    public func update(_ change: (inout ShakenSettings) -> Void) {
        var s = settings
        change(&s)
        s = s.validated()
        guard s != settings else { return }
        settings = s
        save()
        onChange?(s)
    }

    public func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings.validated()) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// Decoding tolerates missing keys so older files keep working.
extension ShakenSettings {
    enum CodingKeys: String, CodingKey {
        case version, slots, gesture, excludedApps, hotKey, shrinkTargetKB, kindPreferences, approvals
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(slots: try c.decodeIfPresent([Slot].self, forKey: .slots) ?? Self.defaultSlots())
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        gesture = try c.decodeIfPresent(GestureSettings.self, forKey: .gesture) ?? GestureSettings()
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        hotKey = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotKey) ?? .default
        shrinkTargetKB = try c.decodeIfPresent(Int.self, forKey: .shrinkTargetKB) ?? 1024
        kindPreferences = try c.decodeIfPresent([String: KindPreference].self, forKey: .kindPreferences) ?? [:]
        approvals = try c.decodeIfPresent([String: [String: String]].self, forKey: .approvals) ?? [:]
    }
}

extension GestureSettings {
    enum CodingKeys: String, CodingKey { case sensitivity, modifier, optionShakeWithoutDrag }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sensitivity = try c.decodeIfPresent(Int.self, forKey: .sensitivity) ?? 3
        modifier = try c.decodeIfPresent(ModifierRequirement.self, forKey: .modifier) ?? .none
        optionShakeWithoutDrag = try c.decodeIfPresent(Bool.self, forKey: .optionShakeWithoutDrag) ?? true
    }
}
