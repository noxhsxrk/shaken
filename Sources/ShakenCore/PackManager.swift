import Foundation

/// Installs action packs from Git (R9). Installing only fetches files — nothing
/// runs until the user has seen the scripts and approved their exact hashes.
public final class PackManager {
    public struct Pack: Equatable, Identifiable {
        public var name: String
        public var directory: URL
        public var remote: String?
        public var id: String { name }
    }

    public let packsDir: URL

    public init(packsDir: URL = ShakenPaths.packs) { self.packsDir = packsDir }

    public func packs() -> [Pack] {
        ActionRegistry.subdirectories(packsDir).map { dir in
            Pack(name: dir.lastPathComponent, directory: dir, remote: try? String(contentsOf: dir.appendingPathComponent(".git/shaken-remote"), encoding: .utf8))
        }
    }

    public static func packName(for url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let last = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "pack"
        let cleaned = last.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "pack" : cleaned
    }

    static func validateURL(_ url: String) throws {
        let u = url.trimmingCharacters(in: .whitespaces)
        let ok = u.hasPrefix("https://") || u.hasPrefix("git@") || u.hasPrefix("ssh://") || u.hasPrefix("file://")
        if !ok || u.hasPrefix("-") || u.contains(" ") {
            throw ShakenError.git(L("Enter a Git URL starting with https:// or git@"))
        }
    }

    /// git with repository hooks and submodules disabled, and no prompts.
    static func git(_ args: [String], cwd: URL? = nil) async throws {
        guard let git = ToolLocator.find("git") else {
            throw ShakenError.missingRequirement(tool: "git", hint: "xcode-select --install")
        }
        let r = try await Subprocess.run(git.path, ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never"] + args,
                                         env: ["GIT_TERMINAL_PROMPT": "0", "GIT_LFS_SKIP_SMUDGE": "1"], cwd: cwd)
        if r.status != 0 {
            throw ShakenError.git(L("Git failed: %@", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    @discardableResult
    public func install(_ url: String) async throws -> Pack {
        try PackManager.validateURL(url)
        let name = Self.packName(for: url)
        let dest = packsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw ShakenError.git(L("A pack named “%@” is already installed", name))
        }
        try FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
        let tmp = packsDir.appendingPathComponent(".installing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await Self.git(["clone", "--depth", "1", "--no-recurse-submodules", "--", url, tmp.path])
        try url.write(to: tmp.appendingPathComponent(".git/shaken-remote"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return Pack(name: name, directory: dest, remote: url)
    }

    /// Pulls new commits. Changed files change their hashes, so they need approval again.
    public func update(_ pack: Pack) async throws {
        try await Self.git(["pull", "--ff-only", "--no-recurse-submodules"], cwd: pack.directory)
    }

    public func uninstall(_ pack: Pack) throws {
        try FileManager.default.removeItem(at: pack.directory)
    }

    /// Everything a user must approve for one action: each file and its hash.
    public static func fingerprint(of action: ActionManifest) throws -> [String: String] {
        guard let dir = action.directory else { return [:] }
        return try Fingerprint.tree(dir)
    }

    public static func needsApproval(_ action: ActionManifest) -> Bool {
        if case .pack = action.source { return true }
        return false
    }

    public static func isApproved(_ action: ActionManifest, settings: ShakenSettings) -> Bool {
        guard needsApproval(action) else { return true }
        guard let approved = settings.approvals[action.id], let now = try? fingerprint(of: action) else { return false }
        return approved == now
    }
}
