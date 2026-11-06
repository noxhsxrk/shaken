import Foundation

/// Looks at the latest GitHub release and says whether it's newer than this build.
public enum UpdateCheck {
    public static let releasesAPI = URL(string: "https://api.github.com/repos/noxhsxrk/shaken/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/noxhsxrk/shaken/releases/latest")!

    public struct Release: Equatable, Sendable {
        public var version: String
        public var page: URL
        public var notes: String
    }

    /// "v0.10.1" > "0.9" — numeric, part by part; a missing part counts as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first
                .map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page, notes: obj["body"] as? String ?? "")
    }

    /// The latest release if it's newer than `current`, nil if up to date. Throws on network errors.
    public static func latest(newerThan current: String) async throws -> Release? {
        var req = URLRequest(url: releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Shaken", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShakenError.other(L("Couldn't reach GitHub to check for updates"))
        }
        guard let r = parse(data) else { return nil }
        return isNewer(r.version, than: current) ? r : nil
    }
}
