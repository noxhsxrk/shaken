import AppKit
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What a step works on. After the first file-producing step it is always `.files`.
public enum JobInput: Equatable, Sendable {
    case files([URL])
    case text(String)
    case link(URL)

    public var files: [URL] { if case .files(let f) = self { return f }; return [] }

    var scriptArguments: [String] {
        switch self {
        case .files(let f): return f.map(\.path)
        case .text(let t): return [t]
        case .link(let u): return [u.absoluteString]
        }
    }

    var kindName: String {
        switch self { case .files: return "files"; case .text: return "text"; case .link: return "link" }
    }
}

struct StepContext {
    var outDir: URL
    var shrinkTargetBytes: Int
}

/// Built-in Swift steps. Each writes its results into `ctx.outDir` and checks
/// for cancellation between files.
enum BuiltinSteps {
    static func produce(_ name: String, arg: String?, input: JobInput, ctx: StepContext) async throws {
        switch name {
        case "convert": try forEachFile(input, name) { try convert($0, to: arg ?? "jpg", ctx) }
        case "resize":
            if let a = arg, a.hasSuffix("%"), let pct = Double(a.dropLast()), pct > 0, pct < 100 {
                try forEachFile(input, name) { try resize($0, scale: pct / 100, ctx) }
            } else {
                guard let px = arg.flatMap(Int.init), px > 0 else { throw ShakenError.invalidManifest(L("resize needs a size, e.g. resize:1920 or resize:50%")) }
                try forEachFile(input, name) { try resize($0, maxPixel: px, ctx) }
            }
        case "compress-pdf": try forEachFile(input, name) { try compressPDF($0, ctx) }
        case "ocr": try forEachFile(input, name) { try MoreSteps.ocr($0, ctx) }
        case "remove-background": try forEachFile(input, name) { try MoreSteps.removeBackground($0, ctx) }
        case "rotate":
            guard let deg = arg.flatMap(Int.init) else { throw ShakenError.invalidManifest(L("rotate takes 90, -90 or 180")) }
            try forEachFile(input, name) { try MoreSteps.rotate($0, degrees: deg, ctx) }
        case "compress-video":
            guard case .files(let f) = input else { throw ShakenError.unsupportedInput(name) }
            for u in f { try Task.checkCancellation(); try await MoreSteps.compressVideo(u, ctx) }
        case "extract-audio":
            guard case .files(let f) = input else { throw ShakenError.unsupportedInput(name) }
            for u in f { try Task.checkCancellation(); try await MoreSteps.extractAudio(u, ctx) }
        case "download": try await MoreSteps.download(input, ctx)
        case "shrink":
            let target = arg.flatMap(Int.init).map { $0 * 1024 } ?? ctx.shrinkTargetBytes
            try forEachFile(input, name) { try shrink($0, targetBytes: target, ctx) }
        case "strip-metadata": try forEachFile(input, name) { try strip($0, ctx) }
        case "to-pdf": try forEachFile(input, name) { try toPDF($0, ctx) }
        case "split-pdf": try forEachFile(input, name) { try splitPDF($0, ctx) }
        case "merge-pdf": try mergePDF(input.files, ctx)
        case "zip": try await zip(input.files, ctx)
        case "qr": try qr(input, ctx)
        case "save-text": try saveText(input, ctx)
        default: throw ShakenError.invalidManifest(L("Unknown step “%@”. Scripts must start with ./", name))
        }
    }

    @MainActor
    static func effect(_ name: String, arg: String?, input: JobInput) async throws -> String? {
        switch name {
        case "open-with":
            let id = arg ?? "com.apple.Preview"
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                throw ShakenError.other(L("App “%@” isn't installed", id))
            }
            let urls: [URL]
            switch input { case .files(let f): urls = f; case .link(let u): urls = [u]; case .text: throw ShakenError.unsupportedInput(L("Text")) }
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return nil
        case "copy-names":
            let names = input.files.map(\.lastPathComponent)
            copy(names.joined(separator: "\n"))
            return L("Copied")
        case "copy-text":
            switch input {
            case .text(let t): copy(t)
            case .link(let u): copy(u.absoluteString)
            case .files(let f): copy(f.map(\.path).joined(separator: "\n"))
            }
            return L("Copied")
        case "open-url":
            guard case .link(let u) = input else { throw ShakenError.unsupportedInput(L("Not a link")) }
            NSWorkspace.shared.open(u)
            return nil
        case "copy-contents":
            // The text of text files (e.g. what "ocr" just wrote), joined.
            let texts = input.files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            guard !texts.isEmpty else { throw ShakenError.unsupportedInput(name) }
            copy(texts.joined(separator: "\n\n"))
            return L("Copied")
        case "copy-path":
            copy(input.files.map(\.path).joined(separator: "\n"))
            return L("Copied")
        case "copy-checksum":
            copy(try MoreSteps.checksums(input.files))
            return L("Copied")
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting(input.files)
            return nil
        default:
            throw ShakenError.invalidManifest(L("Unknown step “%@”. Scripts must start with ./", name))
        }
    }

    @MainActor static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: helpers

    static func forEachFile(_ input: JobInput, _ step: String, _ body: (URL) throws -> Void) throws {
        guard case .files(let files) = input, !files.isEmpty else { throw ShakenError.unsupportedInput(step) }
        for f in files {
            try Task.checkCancellation()
            try body(f)
        }
    }

    static func base(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    static func source(_ url: URL) throws -> (CGImageSource, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              CGImageSourceGetStatus(src) == .statusComplete
        else { throw ShakenError.unreadableImage(url.lastPathComponent) }
        return (src, CGImageSourceGetPrimaryImageIndex(src))
    }

    /// Fully decoded image with EXIF orientation applied to the pixels.
    static func orientedImage(_ src: CGImageSource, _ index: Int, maxPixel: Int? = nil, name: String) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? Swift.max(w, h, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else {
            throw ShakenError.unreadableImage(name)
        }
        return img
    }

    static func outputType(for input: URL) -> (UTType, String) {
        let t = (try? input.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: input.pathExtension)
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        if let t, writable.contains(t.identifier), [UTType.jpeg, .png, .heic, .heif, .tiff].contains(t) {
            return (t, input.pathExtension.isEmpty ? (t.preferredFilenameExtension ?? "img") : input.pathExtension)
        }
        return (.jpeg, "jpg")
    }

    static func write(_ img: CGImage, to url: URL, type: UTType, quality: Double? = 0.9, properties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ShakenError.other(L("Can't write %@", type.preferredFilenameExtension ?? type.identifier))
        }
        var p = properties
        if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ShakenError.other(L("Can't write “%@”", url.lastPathComponent)) }
    }

    static func encode(_ img: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var p: [CFString: Any] = [:]
        if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func scaled(_ img: CGImage, by f: Double) -> CGImage? {
        if f >= 0.999 { return img }
        let w = Swift.max(1, Int(Double(img.width) * f)), h = Swift.max(1, Int(Double(img.height) * f))
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs.model == .rgb ? cs : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: image steps

    static func convert(_ url: URL, to fmt: String, _ ctx: StepContext) throws {
        let type: UTType
        switch fmt.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "png": type = .png
        case "heic": type = .heic
        case "tiff", "tif": type = .tiff
        case "avif":
            type = UTType("public.avif") ?? .heic
            let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
            guard writable.contains(type.identifier) else { throw ShakenError.other(L("This version of macOS can't write AVIF")) }
        default: throw ShakenError.invalidManifest(L("convert supports jpg, png, heic, avif, tiff"))
        }
        let (src, idx) = try source(url)
        let ext = type == .jpeg ? "jpg" : (type.preferredFilenameExtension ?? fmt)
        let out = ctx.outDir.appendingPathComponent("\(base(url)).\(ext)")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ShakenError.other(L("Can't write %@", ext))
        }
        // Copies pixels and metadata (incl. orientation) in one pass — the fast path for the demo.
        var opts: [CFString: Any] = [:]
        if type == .jpeg || type == .heic { opts[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        if type.identifier == "public.avif" { opts[kCGImageDestinationLossyCompressionQuality] = 0.75 }
        CGImageDestinationAddImageFromSource(dest, src, idx, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ShakenError.unreadableImage(url.lastPathComponent) }
    }

    static func resize(_ url: URL, maxPixel: Int, _ ctx: StepContext) throws {
        let (src, idx) = try source(url)
        let img = try orientedImage(src, idx, maxPixel: maxPixel, name: url.lastPathComponent)
        var props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { props[k] = nil }
        let (type, ext) = outputType(for: url)
        try write(img, to: ctx.outDir.appendingPathComponent("\(base(url))-\(maxPixel).\(ext)"), type: type, properties: props)
    }

    /// Scales by a fraction of the original size ("resize:50%").
    static func resize(_ url: URL, scale: Double, _ ctx: StepContext) throws {
        let (src, idx) = try source(url)
        let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(w, h) > 0 else { throw ShakenError.unreadableImage(url.lastPathComponent) }
        let px = max(1, Int((Double(max(w, h)) * scale).rounded()))
        let tmp = StepContext(outDir: ctx.outDir, shrinkTargetBytes: ctx.shrinkTargetBytes)
        try resize(url, maxPixel: px, tmp)
        // Name it by the percentage rather than the pixel size.
        let (_, ext) = outputType(for: url)
        let made = ctx.outDir.appendingPathComponent("\(base(url))-\(px).\(ext)")
        let pct = Int((scale * 100).rounded())
        try FileManager.default.moveItem(at: made, to: ctx.outDir.appendingPathComponent("\(base(url))-\(pct)%.\(ext)"))
    }

    /// Rewrites a PDF with images recompressed as JPEG and downsampled for the screen.
    /// Keeps the original if that wouldn't make it smaller.
    static func compressPDF(_ url: URL, _ ctx: StepContext) throws {
        guard let doc = PDFDocument(url: url) else { throw ShakenError.unreadablePDF(url.lastPathComponent) }
        let out = ctx.outDir.appendingPathComponent("\(base(url)) (compressed).pdf")
        var opts: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            opts[.saveImagesAsJPEGOption] = true
            opts[.optimizeImagesForScreenOption] = true
        } else {
            throw ShakenError.other(L("Compressing PDFs needs macOS 13.4 or later"))
        }
        guard doc.write(to: out, withOptions: opts) else { throw ShakenError.other(L("Can't write %@", out.lastPathComponent)) }
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after == 0 || after >= before {
            try? FileManager.default.removeItem(at: out)
            throw ShakenError.nothingToDo(L("“%@” is already as small as it gets", url.lastPathComponent))
        }
    }

    static func strip(_ url: URL, _ ctx: StepContext) throws {
        let (src, idx) = try source(url)
        let img = try orientedImage(src, idx, name: url.lastPathComponent)
        let (type, ext) = outputType(for: url)
        // Writing a bare CGImage with no property dictionary drops EXIF, GPS, IPTC and XMP.
        try write(img, to: ctx.outDir.appendingPathComponent("\(base(url))-clean.\(ext)"), type: type, quality: type == .png ? nil : 0.92)
    }

    static func shrink(_ url: URL, targetBytes: Int, _ ctx: StepContext) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        let (src, idx) = try source(url)
        let isJPEG = UTType(filenameExtension: url.pathExtension)?.conforms(to: .jpeg) ?? false
        if isJPEG && size <= targetBytes {
            throw ShakenError.nothingToDo(L("Already smaller than %@", ByteCountFormatter.string(fromByteCount: Int64(targetBytes), countStyle: .file)))
        }
        let full = try orientedImage(src, idx, name: url.lastPathComponent)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(full.alphaInfo)
        let keepPNG = hasAlpha && (UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) ?? false)
        let type: UTType = keepPNG ? .png : .jpeg
        let qualities: [Double?] = keepPNG ? [nil] : [0.82, 0.68, 0.52]
        for scale in [1.0, 0.85, 0.7, 0.55, 0.42, 0.3, 0.2, 0.12, 0.06] {
            try Task.checkCancellation()
            guard let img = scaled(full, by: scale) else { continue }
            for q in qualities {
                if let data = encode(img, type: type, quality: q), data.count <= targetBytes {
                    try data.write(to: ctx.outDir.appendingPathComponent("\(base(url))-small.\(keepPNG ? "png" : "jpg")"))
                    return
                }
            }
        }
        throw ShakenError.other(L("Couldn't get “%@” under the size limit", url.lastPathComponent))
    }

    // MARK: PDF

    /// One-page PDF data for an image, sized from its DPI (72 if unknown).
    static func pdfData(forImage url: URL) throws -> Data {
        let (src, idx) = try source(url)
        let img = try orientedImage(src, idx, name: url.lastPathComponent)
        let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        var box = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / dpi, height: Double(img.height) * 72 / dpi)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ShakenError.other("PDF") }
        pdf.beginPDFPage(nil)
        pdf.draw(img, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return data as Data
    }

    static func toPDF(_ url: URL, _ ctx: StepContext) throws {
        try pdfData(forImage: url).write(to: ctx.outDir.appendingPathComponent("\(base(url)).pdf"))
    }

    static func splitPDF(_ url: URL, _ ctx: StepContext) throws {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw ShakenError.unreadablePDF(url.lastPathComponent) }
        if doc.isLocked { throw ShakenError.unreadablePDF(url.lastPathComponent) }
        guard doc.pageCount > 1 else { throw ShakenError.nothingToDo(L("This PDF has only one page")) }
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let one = PDFDocument()
            one.insert(page, at: 0)
            let n = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
            guard one.write(to: ctx.outDir.appendingPathComponent("\(base(url))-p\(n).pdf")) else {
                throw ShakenError.other(L("Can't write “%@”", url.lastPathComponent))
            }
        }
    }

    static func mergePDF(_ files: [URL], _ ctx: StepContext) throws {
        guard files.count >= 1 else { throw ShakenError.unsupportedInput("merge-pdf") }
        let out = PDFDocument()
        for f in files {
            try Task.checkCancellation()
            let t = UTType(filenameExtension: f.pathExtension)
            let doc: PDFDocument?
            if t?.conforms(to: .pdf) == true {
                doc = PDFDocument(url: f)
                if doc == nil || doc!.isLocked { throw ShakenError.unreadablePDF(f.lastPathComponent) }
            } else if t?.conforms(to: .image) == true {
                doc = PDFDocument(data: try pdfData(forImage: f))
            } else {
                throw ShakenError.unsupportedInput(f.lastPathComponent)
            }
            guard let d = doc else { continue }
            for i in 0..<d.pageCount {
                if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
            }
        }
        guard out.write(to: ctx.outDir.appendingPathComponent(L("Merged") + ".pdf")) else {
            throw ShakenError.other(L("Can't write “%@”", "PDF"))
        }
    }

    // MARK: other

    static func zip(_ files: [URL], _ ctx: StepContext) async throws {
        guard !files.isEmpty else { throw ShakenError.unsupportedInput("zip") }
        let fm = FileManager.default
        if files.count == 1 {
            let out = ctx.outDir.appendingPathComponent("\(files[0].lastPathComponent).zip")
            try await ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", files[0].path, out.path])
            return
        }
        // Stage clones (instant on APFS) so items from different folders sit side by side.
        let staging = ctx.outDir.deletingLastPathComponent().appendingPathComponent("zip-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for f in files {
            try Task.checkCancellation()
            var attempt = 1
            while fm.fileExists(atPath: staging.appendingPathComponent(OutputPlacer.candidateName(f.lastPathComponent, attempt: attempt)).path) { attempt += 1 }
            try fm.copyItem(at: f, to: staging.appendingPathComponent(OutputPlacer.candidateName(f.lastPathComponent, attempt: attempt)))
        }
        let out = ctx.outDir.appendingPathComponent(L("Archive") + ".zip")
        try await ditto(["-c", "-k", "--sequesterRsrc", staging.path, out.path])
    }

    static func ditto(_ args: [String]) async throws {
        let r = try await Subprocess.run("/usr/bin/ditto", args)
        if r.status != 0 { throw ShakenError.scriptFailed(name: "ditto", message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func qr(_ input: JobInput, _ ctx: StepContext) throws {
        let message: String, name: String
        switch input {
        case .link(let u): message = u.absoluteString; name = "QR \(u.host ?? "link")"
        case .text(let t): message = t; name = "QR"
        case .files: throw ShakenError.unsupportedInput("qr")
        }
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { throw ShakenError.other("QR") }
        f.setValue(Data(message.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let small = f.outputImage else { throw ShakenError.other(L("Text is too long for a QR code")) }
        let factor = Swift.max(1, (1024 / small.extent.width).rounded(.down))
        let big = small.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cg = CIContext().createCGImage(big, from: big.extent) else { throw ShakenError.other("QR") }
        try write(cg, to: ctx.outDir.appendingPathComponent(sanitize(name) + ".png"), type: .png, quality: nil)
    }

    static func saveText(_ input: JobInput, _ ctx: StepContext) throws {
        let text: String
        switch input {
        case .text(let t): text = t
        case .link(let u): text = u.absoluteString
        case .files: throw ShakenError.unsupportedInput("save-text")
        }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var name = sanitize(String(first.prefix(40)))
        if name.isEmpty { name = L("Text") }
        try text.write(to: ctx.outDir.appendingPathComponent(name + ".txt"), atomically: false, encoding: .utf8)
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters).union(.newlines)
        var out = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        return out
    }
}
