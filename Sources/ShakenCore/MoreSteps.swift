import AVFoundation
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Built-in steps added in 0.3: text recognition, background removal, rotation, video and audio,
/// and downloading a linked file. Each writes its results into `ctx.outDir`, like the others.
enum MoreSteps {
    // MARK: text recognition

    /// Writes the text found in each image (or each page of a PDF) to "<name>.txt".
    static func ocr(_ url: URL, _ ctx: StepContext) throws {
        var pages: [CGImage] = []
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url) else { throw ShakenError.unreadablePDF(url.lastPathComponent) }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let w = Int(box.width * scale), h = Int(box.height * scale)
                guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                c.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: c)
                if let img = c.makeImage() { pages.append(img) }
            }
        } else {
            let (src, idx) = try BuiltinSteps.source(url)
            pages = [try BuiltinSteps.orientedImage(src, idx, name: url.lastPathComponent)]
        }
        var text: [String] = []
        for img in pages {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
            try VNImageRequestHandler(cgImage: img).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            text.append(lines.joined(separator: "\n"))
        }
        let all = text.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !all.isEmpty else { throw ShakenError.nothingToDo(L("No text found in “%@”", url.lastPathComponent)) }
        try all.write(to: ctx.outDir.appendingPathComponent("\(BuiltinSteps.base(url)).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: background removal

    /// Cuts the main subject out onto a transparent background: "<name> (cutout).png". macOS 14+.
    static func removeBackground(_ url: URL, _ ctx: StepContext) throws {
        guard #available(macOS 14.0, *) else { throw ShakenError.other(L("Removing backgrounds needs macOS 14 or later")) }
        let (src, idx) = try BuiltinSteps.source(url)
        let img = try BuiltinSteps.orientedImage(src, idx, name: url.lastPathComponent)
        let handler = VNImageRequestHandler(cgImage: img)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ShakenError.nothingToDo(L("Couldn't find a subject in “%@”", url.lastPathComponent))
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw ShakenError.unreadableImage(url.lastPathComponent) }
        try BuiltinSteps.write(cg, to: ctx.outDir.appendingPathComponent("\(BuiltinSteps.base(url)) (cutout).png"), type: .png, quality: nil)
    }

    // MARK: rotation

    /// Rotates by 90, -90 or 180 degrees (positive = clockwise), keeping the format.
    static func rotate(_ url: URL, degrees: Int, _ ctx: StepContext) throws {
        guard [90, -90, 180, 270].contains(degrees) else { throw ShakenError.invalidManifest(L("rotate takes 90, -90 or 180")) }
        let (src, idx) = try BuiltinSteps.source(url)
        let img = try BuiltinSteps.orientedImage(src, idx, name: url.lastPathComponent)
        let quarter = degrees == 180 ? false : true
        let w = quarter ? img.height : img.width, h = quarter ? img.width : img.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShakenError.unreadableImage(url.lastPathComponent) }
        c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        c.rotate(by: -CGFloat(degrees) * .pi / 180)   // CoreGraphics turns anticlockwise for positive angles
        c.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
        guard let out = c.makeImage() else { throw ShakenError.unreadableImage(url.lastPathComponent) }
        var props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        props[kCGImagePropertyOrientation] = 1
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { props[k] = nil }
        let (type, ext) = BuiltinSteps.outputType(for: url)
        let suffix = degrees == 90 ? "right" : (degrees == 180 ? "180" : "left")
        try BuiltinSteps.write(out, to: ctx.outDir.appendingPathComponent("\(BuiltinSteps.base(url)) (\(suffix)).\(ext)"), type: type, properties: props)
    }

    // MARK: video and audio

    /// Re-encodes a video as H.264 MP4 at most 1280×720: "<name> (720p).mp4".
    static func compressVideo(_ url: URL, _ ctx: StepContext) async throws {
        try await export(url, preset: AVAssetExportPreset1280x720, type: .mp4,
                         to: ctx.outDir.appendingPathComponent("\(BuiltinSteps.base(url)) (720p).mp4"))
    }

    /// Saves a video's sound as AAC: "<name>.m4a".
    static func extractAudio(_ url: URL, _ ctx: StepContext) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !audio.isEmpty else { throw ShakenError.nothingToDo(L("“%@” has no sound", url.lastPathComponent)) }
        try await export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: ctx.outDir.appendingPathComponent("\(BuiltinSteps.base(url)).m4a"))
    }

    private static func export(_ url: URL, preset: String, type: AVFileType, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ShakenError.other(L("Can't convert “%@”", url.lastPathComponent))
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw ShakenError.other(session.error?.localizedDescription ?? L("Can't convert “%@”", url.lastPathComponent))
        }
    }

    // MARK: links

    /// Downloads the file a link points to, named as the server suggests.
    static func download(_ input: JobInput, _ ctx: StepContext) async throws {
        guard case .link(let link) = input, ["http", "https"].contains(link.scheme?.lowercased() ?? "") else {
            throw ShakenError.unsupportedInput(L("Text"))
        }
        let (tmp, response) = try await URLSession.shared.download(from: link)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ShakenError.other(L("The server didn't send the file"))
        }
        let name = downloadName(suggested: response.suggestedFilename, url: link, mime: response.mimeType)
        try FileManager.default.moveItem(at: tmp, to: ctx.outDir.appendingPathComponent(name))
    }

    /// A safe file name for a download: the server's name, else the link's last part, with an extension.
    static func downloadName(suggested: String?, url: URL, mime: String?) -> String {
        var name = (suggested?.isEmpty == false ? suggested! : url.lastPathComponent)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty || name == "-" { name = "download" }
        if (name as NSString).pathExtension.isEmpty, let ext = mime.flatMap({ UTType(mimeType: $0)?.preferredFilenameExtension }) {
            name += "." + ext
        }
        return String(name.prefix(200))
    }

    // MARK: checksum

    /// "sha256  name" lines for each file.
    static func checksums(_ files: [URL]) throws -> String {
        try files.map { "\(try Fingerprint.sha256($0))  \($0.lastPathComponent)" }.joined(separator: "\n")
    }
}

/// Patterns for "Rename in bulk": {name}, {n}, {n:3}, {date}, {date:yyyyMMdd}, {ext} and plain text.
public enum RenamePattern {
    /// Builds a new file name (without extension) for `file`, the `index`-th (0-based) of `total`.
    public static func apply(_ pattern: String, file: URL, index: Int, total: Int, date: Date) -> String {
        let width = max(2, String(total).count)
        var out = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; rest = ""; break }
            let token = rest[rest.index(after: open)..<close]
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let key = parts.first?.lowercased() ?? ""
            let arg = parts.count > 1 ? parts[1] : nil
            switch key {
            case "name": out += file.deletingPathExtension().lastPathComponent
            case "n":
                let w = arg.flatMap(Int.init).map { min(max($0, 1), 6) } ?? width
                out += String(format: "%0\(w)d", index + 1)
            case "date":
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = arg ?? "yyyy-MM-dd"
                out += f.string(from: date)
            case "ext": out += file.pathExtension
            default: out += "{" + token + "}"
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let cleaned = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// True if the pattern has a counter or the file's own name, so every result can differ.
    public static func isDistinct(_ pattern: String) -> Bool {
        let p = pattern.lowercased()
        return p.contains("{n") || p.contains("{name}")
    }

    /// The date used for {date}: when the photo was taken if the file says so, else when it was created.
    public static func date(of file: URL) -> Date {
        if let src = CGImageSourceCreateWithURL(file as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        let v = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return v?.creationDate ?? v?.contentModificationDate ?? Date()
    }
}
