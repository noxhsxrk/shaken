import Foundation

/// Installs a release in place: download the DMG, check its SHA-256, copy the app out of it,
/// and swap it for the running bundle. The old copy goes to the Trash, so nothing is lost if
/// something looks wrong afterwards. Relaunching is left to the app.
public enum Updater {
    public enum Step: Sendable { case downloading, verifying, installing }

    /// - Parameters:
    ///   - bundle: the app to replace (normally `Bundle.main.bundleURL`).
    ///   - bundleID: the new app must have this identifier.
    /// - Returns: where the new app now is (same path as `bundle`).
    ///   - trashFolder: where the old copy goes; nil means the Trash (tests pass a folder).
    public static func install(dmg: URL, expectedSHA256: String?, replacing bundle: URL, bundleID: String,
                               trashFolder: URL? = nil,
                               progress: @Sendable (Step) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let parent = bundle.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw ShakenError.other(L("Shaken can't write to %@. Move it to Applications, or update by hand.", parent.path))
        }
        let work = fm.temporaryDirectory.appendingPathComponent("shaken-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download.
        progress(.downloading)
        let file: URL
        if dmg.isFileURL {
            file = dmg
        } else {
            let (tmp, response) = try await URLSession.shared.download(from: dmg)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ShakenError.other(L("Couldn't download the update")) }
            file = work.appendingPathComponent("update.dmg")
            try fm.moveItem(at: tmp, to: file)
        }
        try Task.checkCancellation()

        // 2. Verify.
        progress(.verifying)
        if let expected = expectedSHA256?.lowercased() {
            guard try Fingerprint.sha256(file) == expected else {
                throw ShakenError.other(L("The downloaded update doesn't match its checksum, so it wasn't installed"))
            }
        }

        // 3. Copy the app out of the disk image next to the current one.
        progress(.installing)
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        // hdiutil sometimes answers "Resource temporarily unavailable" when another image is
        // being mounted at the same moment; a short retry gets past it.
        var attach = try await Subprocess.run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        for _ in 0..<4 where attach.status != 0 {
            try await Task.sleep(nanoseconds: 700_000_000)
            attach = try await Subprocess.run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        }
        guard attach.status == 0 else { throw ShakenError.other(L("Couldn't open the update: %@", attach.stderr)) }
        let staged = parent.appendingPathComponent(".\(bundle.deletingPathExtension().lastPathComponent)-update-\(UUID().uuidString).app")
        do {
            let apps = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            guard let app = apps.first else { throw ShakenError.other(L("The update has no app inside")) }
            let id = Bundle(url: app)?.bundleIdentifier
            guard id == bundleID else { throw ShakenError.other(L("The update is for a different app (%@)", id ?? "?")) }
            let copy = try await Subprocess.run("/usr/bin/ditto", [app.path, staged.path])
            guard copy.status == 0 else { throw ShakenError.other(L("Couldn't copy the update: %@", copy.stderr)) }
        } catch {
            _ = try? await Subprocess.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: staged)
            throw error
        }
        _ = try? await Subprocess.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        // 4. Swap: old copy to the Trash, new copy into its place. Put the old one back on failure.
        var trashed: URL?
        do {
            if let trashFolder {
                let dest = trashFolder.appendingPathComponent(bundle.lastPathComponent)
                try fm.moveItem(at: bundle, to: dest)
                trashed = dest
            } else {
                var out: NSURL?
                try fm.trashItem(at: bundle, resultingItemURL: &out)
                trashed = out as URL?
            }
            try fm.moveItem(at: staged, to: bundle)
        } catch {
            if let t = trashed, !fm.fileExists(atPath: bundle.path) { try? fm.moveItem(at: t, to: bundle) }
            try? fm.removeItem(at: staged)
            throw error
        }
        return bundle
    }
}
