import Foundation

/// Runs the code typed into a Shell script or AppleScript slot.
/// Dragged files become arguments ($1… in zsh, `on run argv` in AppleScript);
/// dragged text or a link is also in $SHAKEN_TEXT.
public enum InlineScript {
    public enum Language: Sendable { case shell, applescript }

    /// - Parameter output: a folder exposed as `$SHAKEN_OUTPUT`; files the script writes there become results.
    public static func run(_ code: String, language: Language, input: JobInput? = nil, output: URL? = nil) async throws {
        var args: [String] = []
        var env: [String: String] = [:]
        switch input {
        case .files(let f)?: args = f.map(\.path)
        case .text(let t)?: args = [t]; env["SHAKEN_TEXT"] = t
        case .link(let u)?: args = [u.absoluteString]; env["SHAKEN_TEXT"] = u.absoluteString
        case nil: break
        }
        if let output { env["SHAKEN_OUTPUT"] = output.path }
        let r: Subprocess.Result
        switch language {
        case .shell:
            // "shaken" fills $0 so the first argument is $1.
            r = try await Subprocess.run("/bin/zsh", ["-c", code, "shaken"] + args, env: env, cwd: FileManager.default.homeDirectoryForCurrentUser)
        case .applescript:
            r = try await Subprocess.run("/usr/bin/osascript", ["-e", code] + args, env: env)
        }
        guard r.status == 0 else {
            let name = language == .shell ? L("Shell script") : L("AppleScript")
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShakenError.scriptFailed(name: name, message: msg.isEmpty ? L("“%@” stopped with exit code %@", name, String(r.status)) : msg)
        }
    }
}
