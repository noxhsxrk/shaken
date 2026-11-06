import Foundation
import UniformTypeIdentifiers

/// One thing being dragged, as read from the drag pasteboard *before* the drop.
public struct DragItem: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder, promise, link, text }

    public var kind: Kind
    /// file/folder: the file URL. link: the web URL.
    public var url: URL?
    public var text: String?
    /// Content types (UTIs). For promises these come from NSFilePromiseReceiver.fileTypes.
    public var types: [String]
    public var displayName: String

    public init(kind: Kind, url: URL? = nil, text: String? = nil, types: [String], displayName: String) {
        self.kind = kind; self.url = url; self.text = text; self.types = types; self.displayName = displayName
    }

    public static func file(_ url: URL) -> DragItem {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
        if isDir {
            return DragItem(kind: .folder, url: url, types: [UTType.folder.identifier], displayName: url.lastPathComponent)
        }
        let t = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
        return DragItem(kind: .file, url: url, types: [t.identifier], displayName: url.lastPathComponent)
    }

    public static func promise(types: [String], name: String = "") -> DragItem {
        DragItem(kind: .promise, types: types.isEmpty ? [UTType.data.identifier] : types, displayName: name)
    }

    public static func link(_ url: URL) -> DragItem {
        DragItem(kind: .link, url: url, types: [Pseudo.link], displayName: url.host ?? url.absoluteString)
    }

    public static func text(_ s: String) -> DragItem {
        let firstLine = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return DragItem(kind: .text, text: s, types: [Pseudo.text], displayName: String(firstLine.prefix(40)))
    }

    /// Does this item satisfy one `accepts` entry of a manifest?
    public func conforms(to accept: String) -> Bool {
        switch kind {
        case .link: return accept == Pseudo.link || accept == Pseudo.any
        case .text: return accept == Pseudo.text || accept == Pseudo.any
        case .file, .folder, .promise:
            if accept == Pseudo.any { return true }
            if accept == Pseudo.link || accept == Pseudo.text { return false }
            guard let want = UTType(accept) else { return types.contains(accept) }
            return types.contains { t in UTType(t).map { $0.conforms(to: want) } ?? (t == accept) }
        }
    }
}

/// Pseudo type identifiers for things that are not files.
public enum Pseudo {
    public static let link = "shaken.link"
    public static let text = "shaken.text"
    public static let any = "shaken.any"
}

public struct DragPayload: Equatable, Sendable {
    public var items: [DragItem]
    public init(_ items: [DragItem]) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }

    /// Short summary for the middle of the wheel.
    public var summary: String {
        if items.count == 1 { return items[0].displayName.isEmpty ? L("1 item") : items[0].displayName }
        return L("%@ items", String(items.count))
    }

    public var kindKey: KindKey { KindKey.of(self) }
}

/// The groups users can reorder/hide actions for (R5), matching the PRD table.
public enum KindKey: String, Codable, CaseIterable, Sendable {
    case image, jpeg, pdf, multiple, folder, link, text, file, none

    public static func of(_ p: DragPayload) -> KindKey {
        guard let first = p.items.first else { return .none }
        if p.items.count > 1 { return .multiple }
        switch first.kind {
        case .folder: return .folder
        case .link: return .link
        case .text: return .text
        case .file, .promise:
            // JPGs share the images list: a separate list was easy to miss. (Commands that
            // don't fit a JPG, like Convert to JPG, are skipped for it automatically.)
            if first.conforms(to: UTType.image.identifier) { return .image }
            if first.conforms(to: UTType.pdf.identifier) { return .pdf }
            return .file
        }
    }

    public var title: String {
        switch self {
        case .image: return L("Image (JPG, PNG, HEIC…)")
        case .jpeg: return L("JPG (old)")
        case .pdf: return L("PDF")
        case .multiple: return L("Several items")
        case .folder: return L("Folder")
        case .link: return L("Link")
        case .text: return L("Text")
        case .file: return L("Other file")
        case .none: return L("Nothing dragged")
        }
    }
}
