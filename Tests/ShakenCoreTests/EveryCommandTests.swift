import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShakenCore

/// Runs the built-in commands the other suites don't, end to end through the real runner, and
/// checks each result is a real file of the right kind. Commands that only open another app
/// (Open in Preview, Open link) are left to the hand checklist.
struct EveryCommandTests {
    func type(of url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    func pixelSize(_ url: URL) -> (Int, Int) {
        let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func convertsToPNGAndHEIC() async throws {
        let s = try Sandbox()
        let jpg = try s.image("photo.jpg", type: .jpeg)
        let png = try await s.runner.run(builtin("builtin.to-png"), input: .files([jpg]))
        #expect(png.outputs.map(\.lastPathComponent) == ["photo.png"])
        #expect(type(of: png.outputs[0]) == UTType.png.identifier)
        let heic = try await s.runner.run(builtin("builtin.to-heic"), input: .files([jpg]))
        #expect(heic.outputs.map(\.pathExtension) == ["heic"])
        #expect(type(of: heic.outputs[0]) == UTType.heic.identifier)
    }

    @Test func resizesToFixedSizes() async throws {
        let s = try Sandbox()
        let big = try s.image("big.png", size: 2400)
        let r1920 = try await s.runner.run(builtin("builtin.resize-1920"), input: .files([big]))
        #expect(max(pixelSize(r1920.outputs[0]).0, pixelSize(r1920.outputs[0]).1) == 1920)
        let r1080 = try await s.runner.run(builtin("builtin.resize-1080"), input: .files([big]))
        #expect(max(pixelSize(r1080.outputs[0]).0, pixelSize(r1080.outputs[0]).1) == 1080)
        // The original is untouched.
        #expect(pixelSize(big).0 == 2400)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/cwebp")
                   || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/cwebp")))
    func convertsToWebP() async throws {
        let s = try Sandbox()
        let png = try s.image("photo.png", size: 128)
        let action = builtin("builtin.to-webp")
        #expect(action.missingRequirements().isEmpty)
        let r = try await s.runner.run(action, input: .files([png]))
        #expect(r.outputs.map(\.pathExtension) == ["webp"])
        let head = try Data(contentsOf: r.outputs[0]).prefix(12)
        #expect(String(decoding: head.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: head.suffix(4), as: UTF8.self) == "WEBP")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
                   && FileManager.default.fileExists(atPath: "/Library/User Pictures/Animals/Parrot.heic")))
    func removesTheBackgroundOfARealPhoto() async throws {
        let s = try Sandbox()
        let photo = s.src.appendingPathComponent("Parrot.heic")
        // The system copy is a relative symlink; copy the file it points to.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic").resolvingSymlinksInPath(), to: photo)
        let r = try await s.runner.run(builtin("builtin.remove-background"), input: .files([photo]))
        #expect(r.outputs.count == 1)
        #expect(type(of: r.outputs[0]) == UTType.png.identifier)
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!, 0, nil)!
        #expect([.premultipliedLast, .premultipliedFirst, .last, .first].contains(img.alphaInfo))
    }

    @Test func savesTextAsAFile() async throws {
        let s = try Sandbox()
        let r = try await s.runner.run(builtin("builtin.save-text"), input: .text("Hello from Shaken"))
        #expect(r.outputs.count == 1 && r.outputs[0].pathExtension == "txt")
        #expect(try String(contentsOf: r.outputs[0], encoding: .utf8).contains("Hello from Shaken"))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func extractsAudioFromAVideoWithSound() async throws {
        let s = try Sandbox()
        let movie = s.src.appendingPathComponent("talk.mov")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-f", "lavfi", "-i", "color=c=red:s=320x240:d=1",
                       "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", movie.path]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let r = try await s.runner.run(builtin("builtin.extract-audio"), input: .files([movie]))
        #expect(r.outputs.map(\.pathExtension) == ["m4a"])
        let tracks = try await AVURLAsset(url: r.outputs[0]).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHAKEN_NETWORK_TESTS"] != nil))
    func downloadsALink() async throws {
        let s = try Sandbox()
        let r = try await s.runner.run(builtin("builtin.download"), input: .link(URL(string: "https://www.apple.com/robots.txt")!))
        #expect(r.outputs.count == 1)
        #expect(r.outputs[0].deletingLastPathComponent().path == s.downloads.path)
        #expect(((try? Data(contentsOf: r.outputs[0]))?.count ?? 0) > 0)
    }
}

/// The commands that put text on the clipboard, one after another (they share it), leaving
/// whatever was on it before back in place.
@Suite(.serialized) struct ClipboardCommandTests {
    @Test func everyCopyCommandPutsTheRightText() async throws {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        defer {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        let s = try Sandbox()
        let a = try s.image("a.png"), b = try s.image("b.png")

        _ = try await s.runner.run(builtin("builtin.copy-names"), input: .files([a, b]))
        #expect(pb.string(forType: .string)?.contains("a.png") == true)
        #expect(pb.string(forType: .string)?.contains("b.png") == true)

        _ = try await s.runner.run(builtin("builtin.copy-path"), input: .files([a]))
        #expect(pb.string(forType: .string) == a.path)

        _ = try await s.runner.run(builtin("builtin.checksum"), input: .files([a]))
        #expect(pb.string(forType: .string)?.range(of: "[0-9a-f]{64}", options: .regularExpression) != nil)

        _ = try await s.runner.run(builtin("builtin.copy-text"), input: .text("dragged words"))
        #expect(pb.string(forType: .string) == "dragged words")

        _ = try await s.runner.run(builtin("builtin.copy-link"), input: .link(URL(string: "https://example.com/page")!))
        #expect(pb.string(forType: .string) == "https://example.com/page")

        // Copy text from image: words in a picture end up on the clipboard.
        let img = s.src.appendingPathComponent("words.png")
        let size = NSSize(width: 900, height: 200)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("Shaken reads this" as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: img)
        _ = try await s.runner.run(builtin("builtin.copy-ocr"), input: .files([img]))
        #expect(pb.string(forType: .string)?.localizedCaseInsensitiveContains("Shaken reads this") == true)
    }
}
