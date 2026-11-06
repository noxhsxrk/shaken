import Foundation
import CryptoKit

public enum Fingerprint {
    /// SHA-256 of a file, streamed. Directories hash their sorted contents.
    public static func sha256(_ url: URL) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ShakenError.outputMissing(url.lastPathComponent)
        }
        if isDir.boolValue {
            var h = SHA256()
            for (rel, sum) in try tree(url).sorted(by: { $0.key < $1.key }) {
                h.update(data: Data("\(rel)\0\(sum)\n".utf8))
            }
            return hex(h.finalize())
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return hex(h.finalize())
    }

    /// relative path → SHA-256 for every file under `root`, skipping `.git`.
    public static func tree(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return out }
        for case let u as URL in e {
            if u.lastPathComponent == ".git" { e.skipDescendants(); continue }
            let path = u.standardizedFileURL.path
            let rel = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : u.lastPathComponent
            let v = try u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v.isSymbolicLink == true {
                // Hash the link target, so retargeting a link also needs re-approval.
                let dest = (try? fm.destinationOfSymbolicLink(atPath: u.path)) ?? ""
                out[rel] = "link:" + hex(SHA256.hash(data: Data(dest.utf8)))
                continue
            }
            if v.isDirectory == true { continue }
            out[rel] = try sha256(u)
        }
        return out
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
