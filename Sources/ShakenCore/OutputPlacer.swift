import Foundation

/// File-writing rules from the PRD:
/// - results go next to the original, under a free name, never overwriting;
/// - no source folder (promise, link, text) or sources in different folders → Downloads;
/// - work happens in a temp folder; files are moved in only on success.
public enum OutputPlacer {
    public static func destination(for inputs: [URL], inbox: URL = ShakenPaths.inbox, downloads: URL = ShakenPaths.downloads) -> URL {
        let parents = Set(inputs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let only = parents.first else { return downloads }
        let inboxPath = inbox.standardizedFileURL.path
        if only == inboxPath || only.hasPrefix(inboxPath + "/") { return downloads }
        return URL(fileURLWithPath: only, isDirectory: true)
    }

    /// "name.ext", "name 2.ext", "name 3.ext", …
    public static func candidateName(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        return ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
    }

    /// Moves every staged file into `dir`. All or nothing: on failure, already
    /// moved files are removed again and the error is rethrown.
    public static func place(_ staged: [URL], into dir: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir.path) else {
            throw ShakenError.destinationNotWritable(dir.path)
        }
        var placed: [URL] = []
        do {
            for file in staged {
                var attempt = 1
                while true {
                    let target = dir.appendingPathComponent(candidateName(file.lastPathComponent, attempt: attempt))
                    do {
                        // moveItem refuses to replace an existing file, so a name taken
                        // between our check and the move can never be overwritten.
                        try fm.moveItem(at: file, to: target)
                        placed.append(target)
                        break
                    } catch CocoaError.fileWriteFileExists {
                        attempt += 1
                        if attempt > 999 { throw ShakenError.other(L("No free name for “%@”", file.lastPathComponent)) }
                    } catch let e as CocoaError where e.code == .fileWriteNoPermission || e.code == .fileWriteVolumeReadOnly {
                        throw ShakenError.destinationNotWritable(dir.path)
                    }
                }
            }
        } catch {
            for p in placed { try? fm.removeItem(at: p) }
            throw error
        }
        return placed
    }
}
