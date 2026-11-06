import Foundation

/// Runs Apple Shortcuts through the `shortcuts` command-line tool that ships with macOS.
public enum Shortcuts {
    public static let tool = "/usr/bin/shortcuts"

    /// Names of the user's shortcuts, for the settings picker.
    public static func list() async -> [String] {
        guard let r = try? await Subprocess.run(tool, ["list"]), r.status == 0 else { return [] }
        return r.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// Runs `name`. Files go in as input; text and links are written to a temporary file first,
    /// because the tool only takes input as file paths.
    public static func run(_ name: String, input: JobInput? = nil, scratch: URL = ShakenPaths.inbox) async throws {
        var args = ["run", name]
        switch input {
        case .files(let f)?:
            args += ["--input-path"] + f.map(\.path)
        case .text(let t)?:
            args += ["--input-path", try write(t, ext: "txt", in: scratch).path]
        case .link(let u)?:
            args += ["--input-path", try write(u.absoluteString, ext: "txt", in: scratch).path]
        case nil:
            break
        }
        let r = try await Subprocess.run(tool, args)
        guard r.status == 0 else {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShakenError.scriptFailed(name: name, message: msg.isEmpty ? L("Shortcut “%@” failed.", name) : msg)
        }
    }

    private static func write(_ text: String, ext: String, in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Input.\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
