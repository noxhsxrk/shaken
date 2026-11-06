import AppKit
import AVFoundation
import Foundation
import Testing
@testable import ShakenCore

@Suite struct MoreStepsTests {
    /// An image with big black text on white.
    func textImage(_ s: Sandbox, _ text: String) throws -> URL {
        let size = NSSize(width: 900, height: 240)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 40, y: 70))
        NSGraphicsContext.restoreGraphicsState()
        let url = s.src.appendingPathComponent("note.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func extractsTextFromAnImage() async throws {
        let s = try Sandbox()
        let img = try textImage(s, "Hello Shaken 42")
        let r = try await s.runner.run(builtin("builtin.ocr"), input: .files([img]))
        #expect(r.outputs.map(\.lastPathComponent) == ["note.txt"])
        let text = try String(contentsOf: r.outputs[0], encoding: .utf8)
        #expect(text.localizedCaseInsensitiveContains("Shaken"))
        #expect(text.contains("42"))
    }

    @Test func blankImagesHaveNoText() async throws {
        let s = try Sandbox()
        let png = try s.image("blank.png", size: 200)
        await #expect(throws: ShakenError.self) { _ = try await s.runner.run(builtin("builtin.ocr"), input: .files([png])) }
    }

    @Test func rotatesAQuarterTurn() async throws {
        let s = try Sandbox()
        let src = s.src.appendingPathComponent("wide.png")
        let ctx = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: src)
        let r = try await s.runner.run(builtin("builtin.rotate-right"), input: .files([src]))
        #expect(r.outputs.map(\.lastPathComponent) == ["wide (right).png"])
        let out = CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 300)
    }

    @Test func compressesAVideo() async throws {
        let s = try Sandbox()
        let movie = s.src.appendingPathComponent("clip.mov")
        try await writeMovie(movie, width: 1920, height: 1080, frames: 12)
        let r = try await s.runner.run(builtin("builtin.compress-video"), input: .files([movie]))
        #expect(r.outputs.map(\.lastPathComponent) == ["clip (720p).mp4"])
        let track = try await AVURLAsset(url: r.outputs[0]).loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        #expect((size?.width ?? 9999) <= 1280)
    }

    @Test func silentVideoHasNoAudioToExtract() async throws {
        let s = try Sandbox()
        let movie = s.src.appendingPathComponent("quiet.mov")
        try await writeMovie(movie, width: 320, height: 240, frames: 6)
        await #expect(throws: ShakenError.self) { _ = try await s.runner.run(builtin("builtin.extract-audio"), input: .files([movie])) }
    }

    @Test func checksumLines() throws {
        let s = try Sandbox()
        let a = s.src.appendingPathComponent("a.txt")
        try "abc".write(to: a, atomically: true, encoding: .utf8)
        #expect(try MoreSteps.checksums([a]) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a.txt")
    }

    @Test func downloadNames() {
        let u = URL(string: "https://example.com/files/report")!
        #expect(MoreSteps.downloadName(suggested: "Report 2026.pdf", url: u, mime: nil) == "Report 2026.pdf")
        #expect(MoreSteps.downloadName(suggested: nil, url: u, mime: "application/pdf") == "report.pdf")
        #expect(MoreSteps.downloadName(suggested: "../../etc/passwd", url: u, mime: nil) == "-..-etc-passwd")
        #expect(MoreSteps.downloadName(suggested: "", url: URL(string: "https://example.com/")!, mime: "image/png") == "download.png")
    }

    /// A few frames of solid colour as H.264.
    func writeMovie(_ url: URL, width: Int, height: Int, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buf)
            CVPixelBufferLockBaseAddress(buf!, [])
            memset(CVPixelBufferGetBaseAddress(buf!), Int32(i * 20 % 255), CVPixelBufferGetDataSize(buf!))
            CVPixelBufferUnlockBaseAddress(buf!, [])
            adaptor.append(buf!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 12))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}

@Suite struct RenamePatternTests {
    let file = URL(fileURLWithPath: "/tmp/IMG_0412.HEIC")
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone.current, year: 2026, month: 11, day: 6).date!

    @Test func tokens() {
        #expect(RenamePattern.apply("Trip {n}", file: file, index: 0, total: 5, date: date) == "Trip 01")
        #expect(RenamePattern.apply("{n:3} {name}", file: file, index: 6, total: 9, date: date) == "007 IMG_0412")
        #expect(RenamePattern.apply("{date} {name}", file: file, index: 0, total: 1, date: date) == "2026-11-06 IMG_0412")
        #expect(RenamePattern.apply("{date:yyyyMMdd}-{n}", file: file, index: 1, total: 120, date: date) == "20261106-002")
        #expect(RenamePattern.apply("{name} ({ext})", file: file, index: 0, total: 1, date: date) == "IMG_0412 (HEIC)")
        #expect(RenamePattern.apply("{unknown} {", file: file, index: 0, total: 1, date: date) == "{unknown} {")
        #expect(RenamePattern.apply("a/b:c", file: file, index: 0, total: 1, date: date) == "a-b-c")
    }

    @Test func distinct() {
        #expect(RenamePattern.isDistinct("{date} {n}"))
        #expect(!RenamePattern.isDistinct("{date}"))
    }

    @Test func renameWithAPatternAndUndo() async throws {
        let s = try Sandbox()
        let a = try s.image("b.png"), b = try s.image("a.png")
        let r = try s.runner.rename([a, b], base: "Shot {n:3}")
        #expect(r.outputs.map(\.lastPathComponent) == ["Shot 001.png", "Shot 002.png"])
        try JobRunner.undo(r)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test func clashingNamesGetANumber() throws {
        let s = try Sandbox()
        let a = try s.image("x.png"), b = try s.image("y.png")
        let r = try s.runner.rename([a, b], base: "{date:yyyy}")   // same name for both
        let names = r.outputs.map(\.lastPathComponent)
        #expect(Set(names).count == 2)
        #expect(names[1].hasSuffix(" 2.png"))
    }
}
