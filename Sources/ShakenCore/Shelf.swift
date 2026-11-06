import Foundation

/// Something parked on the shelf. Files are kept by reference (nothing is copied);
/// file promises and dropped image data are saved into `ShakenPaths.shelfFiles` first.
public struct ShelfItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, link, text }

    public var id: String
    public var kind: Kind
    /// file: path · link: URL string · text: the text
    public var value: String
    public var added: Date

    public init(id: String = UUID().uuidString, kind: Kind, value: String, added: Date = Date()) {
        self.id = id; self.kind = kind; self.value = value; self.added = added
    }

    public var fileURL: URL? { kind == .file ? URL(fileURLWithPath: value) : nil }

    public var dragItem: DragItem? {
        switch kind {
        case .file: return fileURL.map(DragItem.file)
        case .link: return URL(string: value).map(DragItem.link)
        case .text: return .text(value)
        }
    }

    public var title: String {
        switch kind {
        case .file: return URL(fileURLWithPath: value).lastPathComponent
        case .link: return URL(string: value)?.host ?? value
        case .text: return String((value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value).prefix(40))
        }
    }
}

/// Holds dragged things until you need them, persisted across launches.
public final class ShelfStore {
    public static let maxItems = 60

    public let url: URL
    public let filesDir: URL
    public private(set) var items: [ShelfItem] = []
    public var onChange: (() -> Void)?

    public init(url: URL = ShakenPaths.shelf, filesDir: URL = ShakenPaths.shelfFiles) {
        self.url = url
        self.filesDir = filesDir
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = decoded
        }
        pruneMissing()
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Adds what was dropped. Files already on the shelf aren't added twice.
    public func add(_ input: JobInput) {
        var new: [ShelfItem]
        switch input {
        case .files(let urls): new = urls.map { ShelfItem(kind: .file, value: $0.standardizedFileURL.path) }
        case .link(let u): new = [ShelfItem(kind: .link, value: u.absoluteString)]
        case .text(let t): new = [ShelfItem(kind: .text, value: t)]
        }
        new = new.filter { n in !items.contains { $0.kind == n.kind && $0.value == n.value } }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        if items.count > Self.maxItems {
            let dropped = items.prefix(items.count - Self.maxItems)
            items.removeFirst(dropped.count)
        }
        changed()
    }

    public func remove(_ ids: [String]) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        items.removeAll { ids.contains($0.id) }
        changed()
    }

    public func clear() { remove(items.map(\.id)) }

    /// Forget files that were moved or deleted since they were shelved.
    public func pruneMissing() {
        let before = items.count
        items.removeAll { $0.kind == .file && !FileManager.default.fileExists(atPath: $0.value) }
        if items.count != before { changed() }
    }

    public var payload: DragPayload { DragPayload(items.compactMap(\.dragItem)) }

    /// What commands receive when run on the shelf: the files if there are any,
    /// otherwise a single link or text.
    public var jobInput: JobInput? { Self.input(for: items) }

    public static func input(for items: [ShelfItem]) -> JobInput? {
        let files = items.compactMap(\.fileURL)
        if !files.isEmpty { return .files(files) }
        if let l = items.first(where: { $0.kind == .link }), let u = URL(string: l.value) { return .link(u) }
        if let t = items.first(where: { $0.kind == .text }) { return .text(t.value) }
        return nil
    }

    /// Deletes files Shaken saved for the shelf (promises, image data) that no item points
    /// to any more. Done at launch rather than on removal, because an app you dragged an
    /// item into (a browser upload, say) may read the file a while after the drop.
    /// Shelved files that live elsewhere are never touched.
    public func cleanOrphans() {
        let fm = FileManager.default
        let root = filesDir.standardizedFileURL.path + "/"
        let used = Set(items.compactMap { $0.fileURL?.standardizedFileURL.path }
            .filter { $0.hasPrefix(root) }
            .map { String($0.dropFirst(root.count).split(separator: "/").first ?? "") })
        for name in (try? fm.contentsOfDirectory(atPath: filesDir.path)) ?? [] where !used.contains(name) {
            try? fm.removeItem(at: filesDir.appendingPathComponent(name))
        }
    }

    private func changed() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
        onChange?()
    }
}
