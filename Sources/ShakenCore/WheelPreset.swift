import Foundation

/// A wheel saved to a file so it can be shared: `Name.shakenwheel` (JSON).
public struct WheelPreset: Codable, Equatable, Sendable {
    public static let format = "shaken.wheel"
    public static let fileExtension = "shakenwheel"

    public var format: String = WheelPreset.format
    public var version: Int = 1
    public var name: String
    /// Bundle id when the wheel is meant for one app.
    public var app: String?
    public var slots: [Slot]

    public init(name: String, app: String? = nil, slots: [Slot]) {
        self.name = name; self.app = app; self.slots = slots
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Paths to apps and files only mean something on this Mac, but they're kept so a
        // wheel moved between your own Macs still works.
        return try enc.encode(self)
    }

    /// Reads and cleans a preset. Ids are replaced so an import never collides with existing slots.
    public static func decode(_ data: Data) throws -> WheelPreset {
        guard var p = try? JSONDecoder().decode(WheelPreset.self, from: data), p.format == format else {
            throw ShakenError.other(L("This isn't a Shaken wheel file"))
        }
        guard p.version <= 1 else { throw ShakenError.other(L("This wheel was made by a newer version of Shaken")) }
        func fresh(_ s: Slot) -> Slot { var x = s; x.id = UUID().uuidString; x.children = x.children.map(fresh); return x }
        p.slots = ShakenSettings.validatedWheel(p.slots.map(fresh))
        if let a = p.app, a.isEmpty { p.app = nil }
        return p
    }

    /// Slots that run code, press keys or paste text, flattened — what to show before importing.
    public var sensitiveSlots: [Slot] {
        slots.flatMap { [$0] + $0.children }.filter { $0.kind.isSensitive }
    }
}
