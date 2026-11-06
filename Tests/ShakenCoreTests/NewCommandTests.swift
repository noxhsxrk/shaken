import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import ShakenCore

@Suite struct NewCommandTests {
    @Test func avifWhenSupported() async throws {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains("public.avif") else { return }
        let s = try Sandbox()
        let png = try s.image("p.png", size: 200, noise: true)
        let r = try await s.runner.run(builtin("builtin.to-avif"), input: .files([png]))
        #expect(r.outputs.map(\.lastPathComponent) == ["p.avif"])
    }

    @Test func resizeByPercent() async throws {
        let s = try Sandbox()
        let png = try s.image("p.png", size: 400)
        let r = try await s.runner.run(builtin("builtin.resize-half"), input: .files([png]))
        #expect(r.outputs.map(\.lastPathComponent) == ["p-50%.png"])
        let src = CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 200)
    }

    @Test func compressPDFShrinksImageHeavyFiles() async throws {
        let s = try Sandbox()
        // A smooth, photo-like 3000 px image stored losslessly: what scanners and Preview often produce.
        let side = 3000
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<60 {
            ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: (i * 397) % side, y: (i * 613) % side, width: 900, height: 700))
        }
        let pdf = s.src.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 612)
        let pctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        pctx.beginPDFPage(nil)
        pctx.draw(ctx.makeImage()!, in: box)
        pctx.endPDFPage()
        pctx.closePDF()
        let r = try await s.runner.run(builtin("builtin.compress-pdf"), input: .files([pdf]))
        #expect(r.outputs.map(\.lastPathComponent) == ["scan (compressed).pdf"])
        #expect(r.outputBytes < r.inputBytes)
    }

    @Test func renameInBulkAndUndo() async throws {
        let s = try Sandbox()
        let a = try s.image("IMG_9.png"), b = try s.image("IMG_10.png"), c = try s.image("Trip 02.png")
        let action = builtin("builtin.rename")
        #expect(action.asksForName)
        let r = try await s.runner.run(action.withRenameBase("Trip"), input: .files([a, b, c]))
        // "Trip 02" is one of the files being renamed, so the numbers don't skip.
        #expect(r.outputs.map(\.lastPathComponent) == ["Trip 01.png", "Trip 02.png", "Trip 03.png"])
        #expect(!FileManager.default.fileExists(atPath: a.path))
        try JobRunner.undo(r)
        for f in [a, b, c] { #expect(FileManager.default.fileExists(atPath: f.path)) }
    }

    @Test func renameNeverOverwritesOtherFiles() throws {
        let s = try Sandbox()
        _ = try s.image("Trip 01.png")      // not part of the batch
        let a = try s.image("x.png")
        let r = try s.runner.rename([a], base: "Trip")
        #expect(r.outputs.map(\.lastPathComponent) == ["Trip 02.png"])
        #expect(FileManager.default.fileExists(atPath: s.src.appendingPathComponent("Trip 01.png").path))
    }
}

@Suite struct SlotResultTests {
    @Test func scriptOutputBecomesAResult() async throws {
        let s = try Sandbox()
        let a = try s.image("a.png")
        let r = try await s.runner.runSlot("Note", input: .files([a])) { out in
            try await InlineScript.run("echo hi > \"$SHAKEN_OUTPUT/$(basename \"$1\" .png).txt\"", language: .shell, input: .files([a]), output: out)
        }
        #expect(r.outputs.map(\.lastPathComponent) == ["a.txt"])
        #expect(r.outputs[0].deletingLastPathComponent().path == s.src.path)   // next to the input
        try JobRunner.undo(r, trash: { try FileManager.default.removeItem(at: $0) })
        #expect(!FileManager.default.fileExists(atPath: r.outputs[0].path))
    }

    @Test func scriptWithoutOutputHasNoResult() async throws {
        let s = try Sandbox()
        let r = try await s.runner.runSlot("Quiet", input: nil) { out in
            try await InlineScript.run("true", language: .shell, output: out)
        }
        #expect(r.outputs.isEmpty)
    }

    @Test func sniffsShortcutOutput() throws {
        let s = try Sandbox()
        let f = s.root.appendingPathComponent("raw")
        try Data("%PDF-1.7".utf8).write(to: f)
        #expect(Shortcuts.sniffExtension(f) == "pdf")
        try Data("hello".utf8).write(to: f)
        #expect(Shortcuts.sniffExtension(f) == "txt")
    }
}

@Suite struct GalleryTests {
    @Test func bundledIndexAndWheelsAreValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let index = try GalleryIndex.parse(Data(contentsOf: root.appendingPathComponent("gallery/index.json")))
        #expect(!index.wheels.isEmpty)
        for e in index.wheels {
            let file = root.appendingPathComponent("gallery/wheels/\(e.id).shakenwheel")
            let preset = try WheelPreset.decode(Data(contentsOf: file))
            #expect(e.url.hasSuffix("/gallery/wheels/\(e.id).shakenwheel"))
            // Every slot in a gallery wheel must be complete.
            for s in preset.slots where s.kind != .empty { #expect(ActionResolver.incomplete(s) == nil, "\(e.id): \(s.kind) \(s.target)") }
        }
    }

    @Test func dropsUnsafeLinks() throws {
        let json = #"{"version":1,"wheels":[{"id":"a","name":"A","description":"","author":"x","url":"http://x/a.shakenwheel"}],"packs":[{"id":"p","name":"P","description":"","author":"x","url":"file:///tmp/p"}]}"#
        let g = try GalleryIndex.parse(Data(json.utf8))
        #expect(g.wheels.isEmpty && g.packs.isEmpty)
    }
}
