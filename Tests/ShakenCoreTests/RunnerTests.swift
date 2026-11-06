import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShakenCore

final class Sandbox {
    let root: URL
    let src: URL
    let downloads: URL
    let inbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shaken-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        src = root.appendingPathComponent("src")
        downloads = root.appendingPathComponent("Downloads")
        inbox = root.appendingPathComponent("Inbox")
        for d in [src, downloads, inbox] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var runner: JobRunner { JobRunner(shrinkTargetKB: 1024, inbox: inbox, downloads: downloads) }

    func image(_ name: String, type: UTType = .png, size: Int = 64, in dir: URL? = nil, noise: Bool = false) throws -> URL {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if noise {
            var g = SystemRandomNumberGenerator()
            for _ in 0..<(size * size / 4) {
                ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &g), green: .random(in: 0...1, using: &g), blue: .random(in: 0...1, using: &g), alpha: 1))
                ctx.fill(CGRect(x: Int.random(in: 0..<size), y: Int.random(in: 0..<size), width: 2, height: 2))
            }
        }
        let url = (dir ?? src).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 13.7, kCGImagePropertyGPSLatitudeRef: "N"]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, gps as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    func action(_ toml: String, files: [String: String] = [:], name: String = "custom") throws -> ActionManifest {
        let dir = root.appendingPathComponent("actions/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try toml.write(to: dir.appendingPathComponent("action.toml"), atomically: true, encoding: .utf8)
        for (f, body) in files {
            let u = dir.appendingPathComponent(f)
            try body.write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        return try ActionManifest.parse(toml: toml, id: "local.\(name)", directory: dir, source: .local)
    }

    func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
}

func builtin(_ id: String) -> ActionManifest { ActionRegistry.builtins().first { $0.id == id }! }

struct PlacementTests {
    @Test func destinationRules() throws {
        let s = try Sandbox()
        let a = s.src.appendingPathComponent("a.png"), b = s.src.appendingPathComponent("b.png")
        #expect(OutputPlacer.destination(for: [a, b], inbox: s.inbox, downloads: s.downloads).path == s.src.path)
        #expect(OutputPlacer.destination(for: [a, s.root.appendingPathComponent("c.png")], inbox: s.inbox, downloads: s.downloads) == s.downloads)
        #expect(OutputPlacer.destination(for: [], inbox: s.inbox, downloads: s.downloads) == s.downloads)
        #expect(OutputPlacer.destination(for: [s.inbox.appendingPathComponent("x/p.heic")], inbox: s.inbox, downloads: s.downloads) == s.downloads)
    }

    @Test func neverOverwrites() throws {
        let s = try Sandbox()
        try "old".write(to: s.src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "old2".write(to: s.src.appendingPathComponent("a 2.txt"), atomically: true, encoding: .utf8)
        let staged = s.root.appendingPathComponent("a.txt")
        try "new".write(to: staged, atomically: true, encoding: .utf8)
        let placed = try OutputPlacer.place([staged], into: s.src)
        #expect(placed.map(\.lastPathComponent) == ["a 3.txt"])
        #expect(try String(contentsOf: s.src.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
    }

    @Test func unwritableFolderGivesClearError() async throws {
        let s = try Sandbox()
        let ro = s.root.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        let png = try s.image("x.png", in: ro)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        await #expect(throws: ShakenError.destinationNotWritable(ro.path)) {
            try await s.runner.run(builtin("builtin.to-jpg"), input: .files([png]))
        }
    }
}

struct BuiltinActionTests {
    @Test func pngToJpgNextToOriginal() async throws {
        let s = try Sandbox()
        let png = try s.image("photo.png")
        let r = try await s.runner.run(builtin("builtin.to-jpg"), input: .files([png]))
        #expect(r.outputs.map(\.lastPathComponent) == ["photo.jpg"])
        #expect(r.outputs[0].deletingLastPathComponent().path == s.src.path)
        #expect(s.listing(s.src) == ["photo.jpg", "photo.png"])
        // Running again never overwrites.
        let r2 = try await s.runner.run(builtin("builtin.to-jpg"), input: .files([png]))
        #expect(r2.outputs.map(\.lastPathComponent) == ["photo 2.jpg"])
    }

    @Test func heicToJpg() async throws {
        let s = try Sandbox()
        let heic = try s.image("IMG_0001.HEIC", type: .heic, size: 512)
        let start = Date()
        let r = try await s.runner.run(builtin("builtin.to-jpg"), input: .files([heic]))
        #expect(Date().timeIntervalSince(start) < 1)
        let src = CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!
        #expect(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier)
    }

    @Test func promiseInboxGoesToDownloads() async throws {
        let s = try Sandbox()
        let png = try s.image("web.png", in: s.inbox)
        let r = try await s.runner.run(builtin("builtin.to-jpg"), input: .files([png]))
        #expect(r.outputs[0].deletingLastPathComponent().path == s.downloads.path)
    }

    @Test func stripRemovesGPS() async throws {
        let s = try Sandbox()
        let jpg = try s.image("gps.jpg", type: .jpeg)
        let before = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(jpg as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect(before[kCGImagePropertyGPSDictionary] != nil)
        let r = try await s.runner.run(builtin("builtin.strip-metadata"), input: .files([jpg]))
        let after = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect(r.outputs[0].lastPathComponent == "gps-clean.jpg")
    }

    @Test func shrinkGetsUnderTarget() async throws {
        let s = try Sandbox()
        let png = try s.image("big.png", size: 1600, noise: true)
        let runner = JobRunner(shrinkTargetKB: 100, inbox: s.inbox, downloads: s.downloads)
        let r = try await runner.run(builtin("builtin.shrink"), input: .files([png]))
        #expect(r.outputBytes <= 100 * 1024)
        #expect(r.outputBytes < r.inputBytes)
    }

    @Test func pdfMakeMergeSplit() async throws {
        let s = try Sandbox()
        let a = try s.image("a.jpg", type: .jpeg), b = try s.image("b.png")
        let one = try await s.runner.run(builtin("builtin.to-pdf"), input: .files([a]))
        #expect(one.outputs.map(\.lastPathComponent) == ["a.pdf"])
        let merged = try await s.runner.run(builtin("builtin.merge-pdf"), input: .files([one.outputs[0], b, a]))
        #expect(merged.outputs.map(\.lastPathComponent) == ["Merged.pdf"])
        let split = try await s.runner.run(builtin("builtin.split-pdf"), input: .files([merged.outputs[0]]))
        #expect(split.outputs.map(\.lastPathComponent) == ["Merged-p1.pdf", "Merged-p2.pdf", "Merged-p3.pdf"])
    }

    @Test func zipFolderAndMany() async throws {
        let s = try Sandbox()
        let folder = s.src.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try s.image("in.png", in: folder)
        let r = try await s.runner.run(builtin("builtin.zip"), input: .files([folder]))
        #expect(r.outputs.map(\.lastPathComponent) == ["Folder.zip"])
        let many = try await s.runner.run(builtin("builtin.zip"), input: .files([folder, try s.image("x.png")]))
        #expect(many.outputs.map(\.lastPathComponent) == ["Archive.zip"])
    }

    @Test func linkAndTextGoToDownloads() async throws {
        let s = try Sandbox()
        let qr = try await s.runner.run(builtin("builtin.qr"), input: .link(URL(string: "https://example.com/x")!))
        #expect(qr.outputs.map(\.lastPathComponent) == ["QR example.com.png"])
        #expect(qr.outputs[0].deletingLastPathComponent().path == s.downloads.path)
        let txt = try await s.runner.run(builtin("builtin.save-text"), input: .text("Hello: world/today\nsecond"))
        #expect(txt.outputs.map(\.lastPathComponent) == ["Hello- world-today.txt"])
    }

    @Test func damagedImageGivesClearErrorAndNoLeftovers() async throws {
        let s = try Sandbox()
        let bad = s.src.appendingPathComponent("broken.heic")
        try Data("not an image".utf8).write(to: bad)
        await #expect(throws: ShakenError.unreadableImage("broken.heic")) {
            try await s.runner.run(builtin("builtin.to-jpg"), input: .files([bad]))
        }
        #expect(s.listing(s.src) == ["broken.heic"])
    }
}

struct ScriptActionTests {
    @Test func fiveLineScriptAction() async throws {
        let s = try Sandbox()
        let a = try s.action("""
        name = "Upper"
        accepts = ["public.plain-text"]
        run = "./upper.sh"
        """, files: ["upper.sh": """
        #!/bin/sh
        for f in "$@"; do
          tr a-z A-Z < "$f" > "$SHAKEN_OUTPUT/$(basename "$f" .txt)-upper.txt"
        done
        """])
        let f = s.src.appendingPathComponent("note.txt")
        try "hi".write(to: f, atomically: true, encoding: .utf8)
        let r = try await s.runner.run(a, input: .files([f]))
        #expect(r.outputs.map(\.lastPathComponent) == ["note-upper.txt"])
        #expect(try String(contentsOf: r.outputs[0], encoding: .utf8) == "HI")
    }

    @Test func stepsChainBuiltinsAndScripts() async throws {
        let s = try Sandbox()
        let a = try s.action("""
        name = "Web"
        steps = ["resize:32", "strip-metadata", "./rename.sh"]
        """, files: ["rename.sh": "#!/bin/sh\nfor f in \"$@\"; do cp \"$f\" \"$SHAKEN_OUTPUT/web-$(basename \"$f\")\"; done\n"])
        let r = try await s.runner.run(a, input: .files([try s.image("p.png", size: 100)]))
        #expect(r.outputs.map(\.lastPathComponent) == ["web-p-32-clean.png"])
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 32)
    }

    @Test func inlineRunGetsArguments() async throws {
        let s = try Sandbox()
        let a = try s.action(#"""
        name = "Echo"
        accepts = ["shaken.text"]
        run = 'printf "%s" "$1" > "$SHAKEN_OUTPUT/out.txt"'
        """#)
        let r = try await s.runner.run(a, input: .text("สวัสดี"))
        #expect(try String(contentsOf: r.outputs[0], encoding: .utf8) == "สวัสดี")
    }

    @Test func stderrBecomesTheErrorAndNothingIsLeft() async throws {
        let s = try Sandbox()
        let a = try s.action(#"""
        name = "Fail"
        run = 'echo partial > "$SHAKEN_OUTPUT/partial.txt"; echo "cwebp: bad input" >&2; exit 3'
        """#)
        let png = try s.image("p.png")
        await #expect(throws: ShakenError.scriptFailed(name: "Fail", message: "cwebp: bad input")) {
            try await s.runner.run(a, input: .files([png]))
        }
        #expect(s.listing(s.src) == ["p.png"])
    }

    @Test func emptyOutputIsAnError() async throws {
        let s = try Sandbox()
        let a = try s.action(#"name = "Nothing"\#nrun = "true""#)
        await #expect(throws: ShakenError.stepProducedNothing("true")) {
            try await s.runner.run(a, input: .files([try s.image("p.png")]))
        }
    }

    @Test func missingToolShowsInstallHintInsteadOfRunning() async throws {
        let s = try Sandbox()
        let a = try s.action(#"""
        name = "Needs"
        requires = ["cwebp-not-installed-zz"]
        run = 'touch "$SHAKEN_OUTPUT/ran"'
        """#)
        await #expect(throws: ShakenError.missingRequirement(tool: "cwebp-not-installed-zz", hint: "brew install cwebp-not-installed-zz")) {
            try await s.runner.run(a, input: .files([try s.image("p.png")]))
        }
        #expect(s.listing(s.src) == ["p.png"])
    }

    @Test func cancelStopsWithinASecondAndCleansUp() async throws {
        let s = try Sandbox()
        // The script starts a child that would keep writing; the whole group must die.
        let a = try s.action(#"""
        name = "Slow"
        run = '(while true; do echo x >> "$SHAKEN_OUTPUT/partial.txt"; sleep 0.05; done) & trap "" TERM; sleep 30'
        """#)
        let png = try s.image("p.png")
        let runner = s.runner
        let task = Task { try await runner.run(a, input: .files([png])) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(start) < 1)
        if case .success = result { Issue.record("should have been cancelled") }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(s.listing(s.src) == ["p.png"])
    }
}

struct UndoTests {
    @Test func undoTrashesOnlyResults() async throws {
        let s = try Sandbox()
        let png = try s.image("photo.png")
        let r = try await s.runner.run(builtin("builtin.to-jpg"), input: .files([png]))
        var trashed: [URL] = []
        try JobRunner.undo(r) { trashed.append($0); try FileManager.default.removeItem(at: $0) }
        #expect(trashed == r.outputs)
        #expect(s.listing(s.src) == ["photo.png"])
    }

    @Test func undoRefusesWhenAResultWasEdited() async throws {
        let s = try Sandbox()
        let r = try await s.runner.run(builtin("builtin.save-text"), input: .text("abc"))
        try "abd".write(to: r.outputs[0], atomically: true, encoding: .utf8)
        #expect(throws: ShakenError.outputChanged("abc.txt")) {
            try JobRunner.undo(r) { _ in Issue.record("must not trash") }
        }
        #expect(FileManager.default.fileExists(atPath: r.outputs[0].path))
    }

    @Test func folderSlotCopyIsUndoable() async throws {
        let s = try Sandbox()
        let png = try s.image("photo.png")
        let target = s.root.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let r = try await s.runner.copy([png], into: target)
        #expect(s.listing(target) == ["photo.png"])
        try JobRunner.undo(r) { try FileManager.default.removeItem(at: $0) }
        #expect(s.listing(target) == [])
        #expect(s.listing(s.src) == ["photo.png"])
    }
}

struct PackTests {
    func makeRepo(_ s: Sandbox) throws -> URL {
        let repo = s.root.appendingPathComponent("remote/my-pack")
        let act = repo.appendingPathComponent("hello")
        try FileManager.default.createDirectory(at: act, withIntermediateDirectories: true)
        try "name = \"Hello\"\nrun = \"./hello.sh\"\n".write(to: act.appendingPathComponent("action.toml"), atomically: true, encoding: .utf8)
        // If installing ever ran code, this marker would appear.
        try "#!/bin/sh\ntouch \(s.root.path)/RAN\necho hi > \"$SHAKEN_OUTPUT/hi.txt\"\n".write(to: act.appendingPathComponent("hello.sh"), atomically: true, encoding: .utf8)
        let git = "/usr/bin/git"
        for args in [["init", "-q"], ["add", "."], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = args
            p.currentDirectoryURL = repo
            try p.run(); p.waitUntilExit()
        }
        return repo
    }

    @Test func installApproveTamperUninstall() async throws {
        let s = try Sandbox()
        let repo = try makeRepo(s)
        let packs = s.root.appendingPathComponent("Packs")
        let pm = PackManager(packsDir: packs)
        let pack = try await pm.install("file://\(repo.path)")
        #expect(pack.name == "my-pack")
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent("RAN").path))

        let reg = ActionRegistry(userActionsDir: s.root.appendingPathComponent("none"), packsDir: packs)
        let action = try #require(reg.action(id: "pack.my-pack.hello"))
        var settings = ShakenSettings()
        #expect(!PackManager.isApproved(action, settings: settings))

        settings.approvals[action.id] = try PackManager.fingerprint(of: action)
        #expect(PackManager.isApproved(action, settings: settings))

        // One changed byte requires approval again.
        let script = action.directory!.appendingPathComponent("hello.sh")
        var bytes = try Data(contentsOf: script)
        bytes[bytes.count - 2] ^= 0x01
        try bytes.write(to: script)
        #expect(!PackManager.isApproved(action, settings: settings))

        // A new file also counts.
        settings.approvals[action.id] = try PackManager.fingerprint(of: action)
        try "x".write(to: action.directory!.appendingPathComponent("extra.sh"), atomically: true, encoding: .utf8)
        #expect(!PackManager.isApproved(action, settings: settings))

        await #expect(throws: ShakenError.self) { try await pm.install("file://\(repo.path)") }
        try pm.uninstall(pack)
        #expect(pm.packs().isEmpty)
    }

    @Test func rejectsOptionLikeURLs() async {
        let pm = PackManager(packsDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await #expect(throws: ShakenError.self) { try await pm.install("--upload-pack=touch /tmp/x") }
        await #expect(throws: ShakenError.self) { try await pm.install("ext::sh -c touch% /tmp/pwned") }
    }

    @Test func packNames() {
        #expect(PackManager.packName(for: "https://github.com/a/shaken-actions.git") == "shaken-actions")
        #expect(PackManager.packName(for: "git@github.com:a/b.git/") == "b")
        #expect(PackManager.packName(for: "https://x/..") == "pack")
    }
}

struct ExampleActionTests {
    static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Examples")
    }

    @Test func examplesLoadWithoutProblems() {
        let reg = ActionRegistry(userActionsDir: Self.examples, packsDir: URL(fileURLWithPath: "/nonexistent"))
        #expect(reg.problems.isEmpty, "\(reg.problems)")
        #expect(reg.action(id: "local.web-ready")?.steps.count == 3)
        #expect(reg.action(id: "local.rotate") != nil)
        #expect(reg.action(id: "local.webloc") != nil)
    }

    @Test func rotateAndWeblocRun() async throws {
        let s = try Sandbox()
        let reg = ActionRegistry(userActionsDir: Self.examples, packsDir: URL(fileURLWithPath: "/nonexistent"))
        let rot = try await s.runner.run(try #require(reg.action(id: "local.rotate")), input: .files([try s.image("p.png")]))
        #expect(rot.outputs.map(\.lastPathComponent) == ["p-rotated.png"])
        let wl = try await s.runner.run(try #require(reg.action(id: "local.webloc")), input: .link(URL(string: "https://example.com/a?b=1&c=2")!))
        #expect(wl.outputs.map(\.lastPathComponent) == ["example.com.webloc"])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: wl.outputs[0]), format: nil) as? [String: String]
        #expect(plist?["URL"] == "https://example.com/a?b=1&c=2")
    }

    @Test func webReadyRunsWhenCwebpIsInstalled() async throws {
        let s = try Sandbox()
        let reg = ActionRegistry(userActionsDir: Self.examples, packsDir: URL(fileURLWithPath: "/nonexistent"))
        let a = try #require(reg.action(id: "local.web-ready"))
        guard a.missingRequirements().isEmpty else { return }
        let r = try await s.runner.run(a, input: .files([try s.image("photo.png", size: 2400)]))
        #expect(r.outputs.map(\.lastPathComponent) == ["photo.webp"])
    }
}
