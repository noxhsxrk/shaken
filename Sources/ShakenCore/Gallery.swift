import Foundation

/// The list of shared wheels and command packs shown in Settings › Gallery.
/// It's a JSON file in the Shaken repository, so adding to it is a pull request.
public struct GalleryIndex: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var description: String
        public var author: String
        /// https link to a .shakenwheel file, or a Git URL for a pack.
        public var url: String
        /// SF Symbol shown next to it.
        public var icon: String?
    }

    public var version: Int
    public var wheels: [Entry]
    public var packs: [Entry]

    public static let url = URL(string: "https://shaken.noxhsxrk.com/gallery/index.json")!
    public static let submitPage = URL(string: "https://github.com/noxhsxrk/shaken/tree/main/gallery")!

    /// Parses the index, dropping entries whose links aren't https (wheels) or a valid Git URL (packs).
    public static func parse(_ data: Data) throws -> GalleryIndex {
        guard var g = try? JSONDecoder().decode(GalleryIndex.self, from: data) else {
            throw ShakenError.other(L("The gallery list couldn't be read"))
        }
        guard g.version <= 1 else { throw ShakenError.other(L("This gallery needs a newer version of Shaken")) }
        g.wheels = g.wheels.filter { URL(string: $0.url)?.scheme == "https" }
        g.packs = g.packs.filter { $0.url.hasPrefix("https://") && (try? PackManager.validateURL($0.url)) != nil }
        return g
    }

    public static func fetch() async throws -> GalleryIndex {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShakenError.other(L("The gallery isn't reachable right now"))
        }
        return try parse(data)
    }
}
