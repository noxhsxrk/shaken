import Foundation

/// One step of an action: either a built-in Swift step or a script.
public enum Step: Equatable, Sendable {
    case builtin(name: String, arg: String?)
    case script(String)

    /// Built-in steps that create files. Everything else in `effectSteps` acts on files.
    public static let producingSteps: Set<String> = [
        "convert", "resize", "shrink", "strip-metadata", "to-pdf", "split-pdf", "merge-pdf", "zip", "qr", "save-text",
    ]
    /// Steps with a side effect only (open, copy...). They may only appear at the end.
    public static let effectSteps: Set<String> = ["open-with", "copy-names", "copy-text", "open-url", "reveal"]

    public static func parse(_ raw: String) throws -> Step {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("./") || t.hasPrefix("/") || t.hasPrefix("~/") { return .script(t) }
        let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        guard producingSteps.contains(name) || effectSteps.contains(name) else {
            throw ShakenError.invalidManifest(L("Unknown step “%@”. Scripts must start with ./", t))
        }
        return .builtin(name: name, arg: parts.count > 1 ? parts[1] : nil)
    }

    public var isEffect: Bool {
        if case .builtin(let n, _) = self { return Step.effectSteps.contains(n) }
        return false
    }

    public var label: String {
        switch self {
        case .builtin(let n, let a): return a.map { "\(n):\($0)" } ?? n
        case .script(let s): return s
        }
    }
}

/// The single model for every action: built-in, user-written and from Git packs (R8, R9).
public struct ActionManifest: Equatable, Identifiable, Sendable {
    public enum Source: Equatable, Sendable { case builtin, local, pack(String) }

    public var id: String
    public var name: String
    public var localizedNames: [String: String] = [:]
    public var icon: String
    public var accepts: [String]
    /// When exactly one item is dragged it must conform to one of these instead (e.g. zip: folders only).
    public var singleAccepts: [String]?
    public var min: Int
    public var max: Int?
    public var requires: [String]
    public var install: String?
    public var steps: [Step]
    public var directory: URL?
    public var source: Source

    public var displayName: String {
        if source == .builtin { return L(name) }
        for lang in Locale.preferredLanguages {
            let code = String(lang.prefix(2))
            if let n = localizedNames[code] { return n }
        }
        return name
    }

    /// Parses an `action.toml`. `id` defaults to the folder name.
    public static func parse(toml: String, id defaultID: String, directory: URL?, source: Source) throws -> ActionManifest {
        let t: [String: TOMLValue]
        do { t = try TOML.parse(toml) } catch let e as TOMLError {
            throw ShakenError.invalidManifest("action.toml \(e.description)")
        }
        func str(_ k: String) throws -> String? {
            guard let v = t[k] else { return nil }
            guard let s = v.string else { throw ShakenError.invalidManifest(L("“%@” must be text", k)) }
            return s
        }
        func list(_ k: String) throws -> [String]? {
            guard let v = t[k] else { return nil }
            if let s = v.string { return [s] }
            guard let a = v.array, a.allSatisfy({ $0.string != nil }) else {
                throw ShakenError.invalidManifest(L("“%@” must be a list of text", k))
            }
            return a.compactMap(\.string)
        }
        guard let name = try str("name"), !name.isEmpty else {
            throw ShakenError.invalidManifest(L("action.toml needs a name"))
        }
        let run = try str("run")
        let rawSteps = try list("steps")
        let steps: [Step]
        switch (run, rawSteps) {
        case (let r?, nil): steps = [.script(r)]
        case (nil, let s?) where !s.isEmpty: steps = try s.map(Step.parse)
        case (nil, _): throw ShakenError.invalidManifest(L("action.toml needs run or steps"))
        default: throw ShakenError.invalidManifest(L("Use either run or steps, not both"))
        }
        if let bad = steps.dropLast().first(where: \.isEffect) {
            throw ShakenError.invalidManifest(L("Step “%@” can only be the last step", bad.label))
        }
        var names: [String: String] = [:]
        for (k, v) in t where k.hasPrefix("name_") { if let s = v.string { names[String(k.dropFirst(5))] = s } }
        let minV = t["min"]?.int ?? 1
        let maxV = t["max"]?.int
        if minV < 1 || (maxV.map { $0 < minV } ?? false) {
            throw ShakenError.invalidManifest(L("min/max are out of range"))
        }
        return ActionManifest(
            id: (try str("id")) ?? defaultID,
            name: name,
            localizedNames: names,
            icon: (try str("icon")) ?? "bolt",
            accepts: (try list("accepts")) ?? [Pseudo.any],
            singleAccepts: try list("single_accepts"),
            min: minV,
            max: maxV,
            requires: (try list("requires")) ?? [],
            install: try str("install"),
            steps: steps,
            directory: directory,
            source: source
        )
    }

    /// Does this action accept the dragged payload (type and count)?
    public func accepts(_ p: DragPayload) -> Bool {
        let n = p.items.count
        guard n >= min, max.map({ n <= $0 }) ?? true else { return false }
        let list = (n == 1 ? singleAccepts : nil) ?? accepts
        return p.items.allSatisfy { item in list.contains { item.conforms(to: $0) } }
    }

    /// Tools from `requires` that aren't installed.
    public func missingRequirements() -> [String] {
        requires.filter { ToolLocator.find($0) == nil }
    }

    public var installHint: String {
        install ?? "brew install " + missingRequirements().joined(separator: " ")
    }
}

public enum ToolLocator {
    /// GUI apps get a minimal PATH, so also look where Homebrew installs things.
    public static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static var pathEnv: String {
        let existing = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (searchPath + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public static func find(_ tool: String) -> URL? {
        if tool.contains("/") { return FileManager.default.isExecutableFile(atPath: tool) ? URL(fileURLWithPath: tool) : nil }
        for dir in pathEnv.split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}
