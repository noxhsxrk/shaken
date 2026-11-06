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
    /// - Parameter output: if given, the shortcut's output is saved into this folder as a file.
    public static func run(_ name: String, input: JobInput? = nil, scratch: URL = ShakenPaths.inbox, output: URL? = nil) async throws {
        var args = ["run", name]
        let raw = output?.appendingPathComponent(".shortcut-output")
        if let raw { args += ["--output-path", raw.path] }
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
        if let raw, let output, FileManager.default.fileExists(atPath: raw.path) {
            try FileManager.default.moveItem(at: raw, to: output.appendingPathComponent(name + "." + sniffExtension(raw)))
        }
    }

    /// The shortcut tool writes output without an extension; guess one from the content.
    static func sniffExtension(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "txt" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 16)) ?? Data()
        let b = [UInt8](head)
        if b.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            return brand.hasPrefix("heic") || brand.hasPrefix("mif1") ? "heic" : (brand.hasPrefix("avif") ? "avif" : "mp4")
        }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "txt"
    }

    private static func write(_ text: String, ext: String, in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Input.\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
