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
    /// For "Rename in bulk": the original location of each output, so undo can rename back.
    public var renamedFrom: [String: URL] = [:]
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
            if case .builtin("rename", let arg) = step {
                // Renames in place; the app asks for the name and passes it as the argument.
                return try rename(current.files, base: arg ?? "")
            }
            if case .builtin(let name, let arg) = step {
                message = try await BuiltinSteps.effect(name, arg: arg, input: current)
            }
        }

        var prints: [String: String] = [:]
        for o in outputs { prints[o.path] = try Fingerprint.sha256(o) }
        return JobResult(actionName: action.displayName, outputs: outputs, fingerprints: prints,
                         inputBytes: inBytes, outputBytes: Self.totalSize(outputs), message: message)
    }

    /// Runs a Shortcut or inline script slot. Files it leaves in the output folder are placed like
    /// a command's results (next to the input, or in Downloads), so they get the chip and undo.
    public func runSlot(_ title: String, input: JobInput?, _ body: (URL) async throws -> Void) async throws -> JobResult {
        let dest = OutputPlacer.destination(for: input?.files ?? [], inbox: inbox, downloads: downloads)
        try Self.checkWritable(dest)
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try await body(work)
        try Task.checkCancellation()
        let made = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard !made.isEmpty else {
            return JobResult(actionName: title, outputs: [], fingerprints: [:], inputBytes: 0, outputBytes: 0, message: nil)
        }
        let staged = try Self.validatedOutputs(work, step: .script(title))
        let placed = try OutputPlacer.place(staged, into: dest)
        var prints: [String: String] = [:]
        for o in placed { prints[o.path] = try Fingerprint.sha256(o) }
        return JobResult(actionName: title, outputs: placed, fingerprints: prints,
                         inputBytes: Self.totalSize(input?.files ?? []), outputBytes: Self.totalSize(placed), message: nil)
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
        if !result.renamedFrom.isEmpty {
            // Renames go back to their old names; nothing is trashed. Old names held by this batch's
            // own outputs are fine (they swap); anything else in the way stops the undo.
            let fm = FileManager.default
            let ours = Set(result.outputs.map(\.standardizedFileURL.path))
            for o in result.outputs {
                guard let old = result.renamedFrom[o.path] else { continue }
                if fm.fileExists(atPath: old.path) && !ours.contains(old.standardizedFileURL.path) {
                    throw ShakenError.other(L("“%@” exists again, so it wasn't renamed back", old.lastPathComponent))
                }
            }
            var parked: [(temp: URL, old: URL)] = []
            for o in result.outputs {
                guard let old = result.renamedFrom[o.path] else { continue }
                let temp = o.deletingLastPathComponent().appendingPathComponent(".shaken-rename-\(UUID().uuidString)")
                try fm.moveItem(at: o, to: temp)
                parked.append((temp, old))
            }
            for p in parked { try fm.moveItem(at: p.temp, to: p.old) }
            return
        }
        for o in result.outputs { try trash(o) }
    }

    /// Renames files in place. `base` is a pattern such as "{date} {name}" or "Trip {n:3}"; plain text
    /// becomes "<text> 01", "<text> 02"… in the order given.
    /// Never overwrites: a taken name gets the next free one. Undo renames them back.
    public func rename(_ files: [URL], base rawBase: String) throws -> JobResult {
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !base.isEmpty else { throw ShakenError.other(L("Enter a name")) }
        guard !files.isEmpty else { throw ShakenError.unsupportedInput(L("Text")) }
        let fm = FileManager.default
        var outputs: [URL] = []
        var from: [String: URL] = [:]
        var prints: [String: String] = [:]
        // Dates for {date} are read before anything moves.
        let dates = files.map(RenamePattern.date(of:))
        // Phase 1: move every file to a temporary name, so names held by files in this batch are free.
        var parked: [(original: URL, temp: URL)] = []
        do {
            for f in files {
                try Task.checkCancellation()
                let temp = f.deletingLastPathComponent().appendingPathComponent(".shaken-rename-\(UUID().uuidString)")
                try fm.moveItem(at: f, to: temp)
                parked.append((f, temp))
            }
        } catch {
            for p in parked.reversed() { try? fm.moveItem(at: p.temp, to: p.original) }
            throw error
        }
        // Phase 2: build each new name from the pattern. A name that's taken (by a file outside the
        // batch, or because the pattern gives two files the same name) gets " 2", " 3"… added.
        let pattern = base.contains("{") ? base : base + " {n}"
        let counts = pattern.lowercased().contains("{n")
        var skip = 0   // counter numbers already taken by files outside the batch
        for (i, p) in parked.enumerated() {
            let dir = p.original.deletingLastPathComponent()
            let ext = p.original.pathExtension
            func name(_ stem: String) -> URL { dir.appendingPathComponent(stem + (ext.isEmpty ? "" : "." + ext)) }
            var stem = RenamePattern.apply(pattern, file: p.original, index: i + skip, total: parked.count, date: dates[i])
            var target = name(stem)
            // With a counter, a taken name moves on to the next number; otherwise add " 2", " 3"…
            while counts && fm.fileExists(atPath: target.path) && skip < 10_000 {
                skip += 1
                stem = RenamePattern.apply(pattern, file: p.original, index: i + skip, total: parked.count, date: dates[i])
                target = name(stem)
            }
            var k = 2
            while fm.fileExists(atPath: target.path) {
                target = name("\(stem) \(k)")
                k += 1
            }
            do { try fm.moveItem(at: p.temp, to: target) } catch {
                try? fm.moveItem(at: p.temp, to: p.original)
                throw error
            }
            outputs.append(target)
            if target.standardizedFileURL.path != p.original.standardizedFileURL.path { from[target.path] = p.original }
        }
        for o in outputs { prints[o.path] = try Fingerprint.sha256(o) }
        var r = JobResult(actionName: L("Rename in bulk"), outputs: outputs, fingerprints: prints,
                          inputBytes: Self.totalSize(outputs), outputBytes: Self.totalSize(outputs), message: nil)
        r.renamedFrom = from
        return r
    }
}
