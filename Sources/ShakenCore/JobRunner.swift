import AppKit
import Foundation

public struct JobResult: Equatable, Sendable {
    public var actionName: String
    /// Final locations of created files (empty for open/copy-only actions).
    public var outputs: [URL]
    /// path → SHA-256 at creation, used to refuse undo once a file was edited.
    public var fingerprints: [String: String]
    public var inputBytes: Int64
    public var outputBytes: Int64
    /// Short note such as "Copied".
    public var message: String?
}

/// Runs every kind of action — Swift built-ins and scripts — the same way, so
/// they all get the chip, cancel (R7) and undo (R7).
public final class JobRunner {
    public var shrinkTargetKB: Int
    public var inbox: URL
    public var downloads: URL

    public init(shrinkTargetKB: Int = 1024, inbox: URL = ShakenPaths.inbox, downloads: URL = ShakenPaths.downloads) {
        self.shrinkTargetKB = shrinkTargetKB
        self.inbox = inbox
        self.downloads = downloads
    }

    /// Runs `action` on `input`. Cancel the surrounding Task to stop it: temp files are
    /// removed and nothing is moved into place.
    /// - Parameter destination: overrides the "next to the original" rule (e.g. folder slots).
    public func run(_ action: ActionManifest, input: JobInput, destination: URL? = nil) async throws -> JobResult {
        let missing = action.missingRequirements()
        if let tool = missing.first { throw ShakenError.missingRequirement(tool: tool, hint: action.installHint) }

        let producing = action.steps.filter { !$0.isEffect }
        let effects = action.steps.filter(\.isEffect)
        let inBytes = Self.totalSize(input.files)

        var outputs: [URL] = []
        var current = input
        if !producing.isEmpty {
            let dest = destination ?? OutputPlacer.destination(for: input.files, inbox: inbox, downloads: downloads)
            try Self.checkWritable(dest)
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
            defer { try? FileManager.default.removeItem(at: work) }

            for (i, step) in producing.enumerated() {
                try Task.checkCancellation()
                let out = work.appendingPathComponent("step-\(i + 1)", isDirectory: true)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try await runStep(step, action: action, input: current, outDir: out)
                try Task.checkCancellation()
                let made = try Self.validatedOutputs(out, step: step)
                current = .files(made)
            }
            try Task.checkCancellation()
            outputs = try OutputPlacer.place(current.files, into: dest)
            current = .files(outputs)
        }

        var message: String?
        for step in effects {
            try Task.checkCancellation()
            if case .builtin(let name, let arg) = step {
                message = try await BuiltinSteps.effect(name, arg: arg, input: current)
            }
        }

        var prints: [String: String] = [:]
        for o in outputs { prints[o.path] = try Fingerprint.sha256(o) }
        return JobResult(actionName: action.displayName, outputs: outputs, fingerprints: prints,
                         inputBytes: inBytes, outputBytes: Self.totalSize(outputs), message: message)
    }

    /// Copies dropped items into a folder (folder slots). Shares placement, chip and undo with actions.
    public func copy(_ files: [URL], into folder: URL) async throws -> JobResult {
        try Self.checkWritable(folder)
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for f in files {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: f, to: work.appendingPathComponent(f.lastPathComponent))
        }
        let staged = try Self.validatedOutputs(work, step: .script("copy"))
        let placed = try OutputPlacer.place(staged, into: folder)
        var prints: [String: String] = [:]
        for o in placed { prints[o.path] = try Fingerprint.sha256(o) }
        return JobResult(actionName: L("Copy to %@", folder.lastPathComponent), outputs: placed, fingerprints: prints,
                         inputBytes: Self.totalSize(files), outputBytes: Self.totalSize(placed), message: nil)
    }

    private func runStep(_ step: Step, action: ActionManifest, input: JobInput, outDir: URL) async throws {
        switch step {
        case .builtin(let name, let arg):
            let ctx = StepContext(outDir: outDir, shrinkTargetBytes: shrinkTargetKB * 1024)
            try await BuiltinSteps.produce(name, arg: arg, input: input, ctx: ctx)
        case .script(let command):
            try await runScript(command, action: action, input: input, outDir: outDir)
        }
    }

    private func runScript(_ command: String, action: ActionManifest, input: JobInput, outDir: URL) async throws {
        let dir = action.directory ?? outDir
        var env = [
            "SHAKEN_OUTPUT": outDir.path,
            "SHAKEN_KIND": input.kindName,
            "SHAKEN_ACTION_DIR": dir.path,
        ]
        if case .text(let t) = input { env["SHAKEN_TEXT"] = t }
        let exe: String, args: [String]
        if command.hasPrefix("./") {
            let script = dir.appendingPathComponent(String(command.dropFirst(2))).standardizedFileURL
            // Scripts must live inside the action's folder.
            guard script.path.hasPrefix(dir.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: script.path) else {
                throw ShakenError.invalidManifest(L("Script “%@” not found", command))
            }
            if FileManager.default.isExecutableFile(atPath: script.path) {
                exe = script.path; args = input.scriptArguments
            } else {
                exe = "/bin/sh"; args = [script.path] + input.scriptArguments
            }
        } else {
            // Inline command: arguments are available as "$@".
            exe = "/bin/sh"; args = ["-c", command, action.name] + input.scriptArguments
        }
        let r = try await Subprocess.run(exe, args, env: env, cwd: dir)
        if r.status != 0 {
            var msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.count > 600 { msg = "…" + msg.suffix(600) }
            if msg.isEmpty { msg = L("“%@” stopped with exit code %@", action.displayName, String(r.status)) }
            throw ShakenError.scriptFailed(name: action.displayName, message: msg)
        }
    }

    /// Checks results before they are moved anywhere real: no symlinks, no empty files.
    static func validatedOutputs(_ dir: URL, step: Step) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if items.isEmpty { throw ShakenError.stepProducedNothing(step.label) }
        for u in items {
            let v = try u.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if v.isSymbolicLink == true { throw ShakenError.other(L("Step “%@” produced a symbolic link, which isn't allowed", step.label)) }
            if v.isRegularFile == true && (v.fileSize ?? 0) == 0 { throw ShakenError.other(L("Step “%@” produced an empty file “%@”", step.label, u.lastPathComponent)) }
        }
        return items
    }

    static func checkWritable(_ dir: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isWritableFile(atPath: dir.path) else {
            throw ShakenError.destinationNotWritable(dir.path)
        }
    }

    public static func totalSize(_ urls: [URL]) -> Int64 {
        urls.reduce(0) { sum, u in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return sum }
            if !isDir.boolValue { return sum + Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var t: Int64 = 0
            if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            return sum + t
        }
    }

    // MARK: undo

    /// Moves a job's results to the Trash. Refuses (and touches nothing) if any of
    /// them changed after creation. Originals are never touched.
    public static func undo(_ result: JobResult, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        for o in result.outputs {
            guard FileManager.default.fileExists(atPath: o.path) else { throw ShakenError.outputMissing(o.lastPathComponent) }
            guard try Fingerprint.sha256(o) == result.fingerprints[o.path] else { throw ShakenError.outputChanged(o.lastPathComponent) }
        }
        for o in result.outputs { try trash(o) }
    }
}
