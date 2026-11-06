import Foundation

/// Built-in actions are written in the very same `action.toml` format as
/// community actions and go through the same parser — no special shortcuts.
/// Order here is the default order the wheel suggests them in.
enum BuiltinActions {
    static let manifests: [(id: String, toml: String)] = [
        ("builtin.to-jpg", """
        name = "Convert to JPG"
        icon = "glyph:Convert"
        accepts = ["public.heic", "public.heif", "public.png"]
        max = 1
        steps = ["convert:jpg"]
        """),
        ("builtin.shrink", """
        name = "Shrink below size limit"
        icon = "glyph:Compress"
        accepts = ["public.heic", "public.heif", "public.png", "public.jpeg"]
        max = 1
        steps = ["shrink"]
        """),
        ("builtin.strip-metadata", """
        name = "Remove metadata"
        icon = "glyph:Metadata"
        accepts = ["public.image"]
        max = 1
        steps = ["strip-metadata"]
        """),
        ("builtin.to-pdf", """
        name = "Make PDF"
        icon = "doc.richtext"
        accepts = ["public.jpeg"]
        max = 1
        steps = ["to-pdf"]
        """),
        ("builtin.split-pdf", """
        name = "Split pages"
        icon = "rectangle.split.3x1"
        accepts = ["com.adobe.pdf"]
        max = 1
        steps = ["split-pdf"]
        """),
        ("builtin.open-preview", """
        name = "Open in Preview"
        icon = "glyph:Preview"
        accepts = ["public.image", "com.adobe.pdf"]
        max = 1
        steps = ["open-with:com.apple.Preview"]
        """),
        ("builtin.zip", """
        name = "Compress to ZIP"
        icon = "glyph:Compress"
        accepts = ["public.item"]
        single_accepts = ["public.folder"]
        steps = ["zip"]
        """),
        ("builtin.merge-pdf", """
        name = "Merge into PDF"
        icon = "doc.on.doc"
        accepts = ["public.image", "com.adobe.pdf"]
        min = 2
        steps = ["merge-pdf"]
        """),
        ("builtin.copy-names", """
        name = "Copy name"
        icon = "glyph:CopyName"
        accepts = ["public.item"]
        steps = ["copy-names"]
        """),
        ("builtin.open-link", """
        name = "Open link"
        icon = "glyph:Link"
        accepts = ["shaken.link"]
        max = 1
        steps = ["open-url"]
        """),
        ("builtin.copy-link", """
        name = "Copy link"
        icon = "glyph:Link"
        accepts = ["shaken.link"]
        steps = ["copy-text"]
        """),
        ("builtin.qr", """
        name = "Make QR code"
        icon = "qrcode"
        accepts = ["shaken.link"]
        max = 1
        steps = ["qr"]
        """),
        ("builtin.save-text", """
        name = "Save as .txt"
        icon = "doc.text"
        accepts = ["shaken.text"]
        max = 1
        steps = ["save-text"]
        """),
        ("builtin.copy-text", """
        name = "Copy text"
        icon = "doc.on.clipboard"
        accepts = ["shaken.text"]
        steps = ["copy-text"]
        """),
        ("builtin.resize-1920", """
        name = "Resize to 1920 px"
        icon = "arrow.up.left.and.down.right.magnifyingglass"
        accepts = ["public.image"]
        steps = ["resize:1920"]
        """),
        ("builtin.resize-half", """
        name = "Resize to 50%"
        icon = "square.resize.down"
        accepts = ["public.image"]
        steps = ["resize:50%"]
        """),
        ("builtin.resize-1080", """
        name = "Resize to 1080 px"
        icon = "rectangle.compress.vertical"
        accepts = ["public.image"]
        steps = ["resize:1080"]
        """),
        ("builtin.to-avif", """
        name = "Convert to AVIF"
        icon = "glyph:Convert"
        accepts = ["public.image"]
        steps = ["convert:avif"]
        """),
        ("builtin.to-webp", """
        name = "Convert to WebP"
        icon = "glyph:Convert"
        accepts = ["public.image"]
        requires = ["cwebp"]
        install = "brew install webp"
        run = "for f in \\"$@\\"; do b=$(basename \\"${f%.*}\\"); cwebp -quiet -q 82 -metadata icc \\"$f\\" -o \\"$SHAKEN_OUTPUT/$b.webp\\" || exit 1; done"
        """),
        ("builtin.compress-pdf", """
        name = "Compress PDF"
        icon = "glyph:Compress"
        accepts = ["com.adobe.pdf"]
        steps = ["compress-pdf"]
        """),
        ("builtin.rename", """
        name = "Rename in bulk"
        icon = "character.cursor.ibeam"
        accepts = ["public.item"]
        min = 2
        steps = ["rename"]
        """),
    ]
}

public struct LoadProblem: Equatable {
    public var path: String
    public var message: String
}

public final class ActionRegistry {
    public private(set) var actions: [ActionManifest] = []
    public private(set) var problems: [LoadProblem] = []

    public let userActionsDir: URL
    public let packsDir: URL

    public init(userActionsDir: URL = ShakenPaths.actions, packsDir: URL = ShakenPaths.packs) {
        self.userActionsDir = userActionsDir
        self.packsDir = packsDir
        reload()
    }

    public static func builtins() -> [ActionManifest] {
        BuiltinActions.manifests.map { entry in
            // A failure here is a programming error caught by the test suite.
            try! ActionManifest.parse(toml: entry.toml, id: entry.id, directory: nil, source: .builtin)
        }
    }

    public func action(id: String) -> ActionManifest? { actions.first { $0.id == id } }

    public func reload() {
        var list = Self.builtins()
        var issues: [LoadProblem] = []
        let fm = FileManager.default

        for dir in Self.subdirectories(userActionsDir) {
            load(dir, id: "local.\(dir.lastPathComponent)", source: .local, into: &list, issues: &issues)
        }
        for pack in Self.subdirectories(packsDir) {
            let name = pack.lastPathComponent
            if fm.fileExists(atPath: pack.appendingPathComponent("action.toml").path) {
                load(pack, id: "pack.\(name)", source: .pack(name), into: &list, issues: &issues)
            }
            for dir in Self.subdirectories(pack) where fm.fileExists(atPath: dir.appendingPathComponent("action.toml").path) {
                load(dir, id: "pack.\(name).\(dir.lastPathComponent)", source: .pack(name), into: &list, issues: &issues)
            }
        }
        actions = list
        problems = issues
    }

    private func load(_ dir: URL, id: String, source: ActionManifest.Source, into list: inout [ActionManifest], issues: inout [LoadProblem]) {
        let file = dir.appendingPathComponent("action.toml")
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            var m = try ActionManifest.parse(toml: text, id: id, directory: dir, source: source)
            // Never let a custom action pretend to be built in or collide with another one.
            if m.id.hasPrefix("builtin.") || list.contains(where: { $0.id == m.id }) { m.id = id }
            if list.contains(where: { $0.id == m.id }) {
                issues.append(LoadProblem(path: file.path, message: L("Duplicate action id “%@”", m.id)))
                return
            }
            list.append(m)
        } catch {
            issues.append(LoadProblem(path: file.path, message: error.localizedDescription))
        }
    }

    static func subdirectories(_ url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum ShakenPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shaken", isDirectory: true)
    }
    public static var actions: URL { support.appendingPathComponent("Actions", isDirectory: true) }
    public static var packs: URL { support.appendingPathComponent("Packs", isDirectory: true) }
    public static var traces: URL { support.appendingPathComponent("Traces", isDirectory: true) }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var shelf: URL { support.appendingPathComponent("shelf.json") }
    /// Shelved promises and image data; unlike the inbox, kept across launches.
    public static var shelfFiles: URL { support.appendingPathComponent("Shelf", isDirectory: true) }
    public static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
    /// Received file promises and dropped image data live here; cleared at launch.
    public static var inbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shaken/Inbox", isDirectory: true)
    }
    public static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    public static func ensure() {
        for d in [support, actions, packs, inbox, shelfFiles] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}
