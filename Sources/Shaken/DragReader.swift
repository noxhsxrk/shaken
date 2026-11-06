import AppKit
import ShakenCore
import UniformTypeIdentifiers

/// Reads what is being dragged (R4): files, folders, file promises (Photos,
/// Mail, Safari), image data, links and text.
enum DragReader {
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
    ]

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string] + imageTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Cheap read for the wheel, done while the mouse is still down.
    static func preview(_ pb: NSPasteboard) -> DragPayload {
        let files = fileURLs(pb)
        if !files.isEmpty { return DragPayload(files.map(DragItem.file)) }

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            return DragPayload(promises.map { r in
                let t = r.fileTypes.first.flatMap { UTType($0) }
                return DragItem.promise(types: r.fileTypes, name: t?.localizedDescription ?? "")
            })
        }
        if let t = pb.availableType(from: imageTypes) {
            return DragPayload([DragItem.promise(types: [UTType(t.rawValue)?.identifier ?? UTType.image.identifier], name: L("Image"))])
        }
        if let link = webURL(pb) { return DragPayload([.link(link)]) }
        if let s = pb.string(forType: .string), !s.isEmpty {
            if let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), !s.contains(" ") {
                return DragPayload([.link(u)])
            }
            return DragPayload([.text(s)])
        }
        return DragPayload([])
    }

    /// After the drop: turns promises and raw image data into real files in the inbox.
    static func materialize(_ pb: NSPasteboard, completion: @escaping (Result<JobInput, Error>) -> Void) {
        let files = fileURLs(pb)
        if !files.isEmpty { return completion(.success(.files(files))) }

        let inboxDir = ShakenPaths.inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            do { try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true) } catch { return completion(.failure(error)) }
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            let group = DispatchGroup()
            let lock = NSLock()
            var received: [URL] = []
            var firstError: Error?
            for r in promises {
                group.enter()
                var left = false
                r.receivePromisedFiles(atDestination: inboxDir, options: [:], operationQueue: queue) { url, error in
                    lock.lock()
                    if let error { firstError = firstError ?? error } else { received.append(url) }
                    let shouldLeave = !left
                    left = true
                    lock.unlock()
                    if shouldLeave { group.leave() }
                }
            }
            DispatchQueue.global().async {
                let timedOut = group.wait(timeout: .now() + 60) == .timedOut
                DispatchQueue.main.async {
                    if !received.isEmpty { completion(.success(.files(received.sorted { $0.path < $1.path }))) }
                    else if let firstError { completion(.failure(firstError)) }
                    else { completion(.failure(ShakenError.other(timedOut ? L("The app you dragged from didn't deliver the file in time") : L("Nothing was received")))) }
                }
            }
            return
        }

        if let t = pb.availableType(from: imageTypes), let data = pb.data(forType: t) {
            let ext = UTType(t.rawValue)?.preferredFilenameExtension ?? "png"
            do {
                try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
                let url = inboxDir.appendingPathComponent(L("Image") + "." + (ext == "jpeg" ? "jpg" : ext))
                try data.write(to: url)
                return completion(.success(.files([url])))
            } catch { return completion(.failure(error)) }
        }

        switch preview(pb).items.first?.kind {
        case .link?: if let u = preview(pb).items.first?.url { return completion(.success(.link(u))) }
        case .text?: if let s = pb.string(forType: .string) { return completion(.success(.text(s))) }
        default: break
        }
        completion(.failure(ShakenError.other(L("Shaken can't read what was dropped"))))
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func webURL(_ pb: NSPasteboard) -> URL? {
        let urls = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        return urls.first { !$0.isFileURL && $0.scheme != nil }
    }
}
