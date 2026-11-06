import Foundation
import Testing
@testable import ShakenCore

@Suite(.serialized) struct UpdaterTests {
    /// A tiny app bundle with an identifier and a marker file.
    func fakeApp(_ dir: URL, id: String, marker: String) throws -> URL {
        let app = dir.appendingPathComponent("Shaken.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Shaken"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try marker.write(to: contents.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        return app
    }

    func makeDMG(from folder: URL, to dmg: URL) async throws {
        let r = try await Subprocess.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", folder.path, "-volname", "Shaken", "-format", "UDZO", dmg.path])
        #expect(r.status == 0, "\(r.stderr)")
    }

    @Test func replacesTheAppInPlace() async throws {
        let s = try Sandbox()
        let installed = try fakeApp(s.src, id: "com.noxhsxrk.shaken", marker: "old")
        let newDir = s.root.appendingPathComponent("new")
        _ = try fakeApp(newDir, id: "com.noxhsxrk.shaken", marker: "new")
        let dmg = s.root.appendingPathComponent("Shaken.dmg")
        try await makeDMG(from: newDir, to: dmg)
        let trash = s.root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let out = try await Updater.install(dmg: dmg, expectedSHA256: try Fingerprint.sha256(dmg), replacing: installed,
                                            bundleID: "com.noxhsxrk.shaken", trashFolder: trash)
        #expect(out == installed)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: trash.appendingPathComponent("Shaken.app/Contents/marker.txt"), encoding: .utf8) == "old")
        // No staging copies left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: s.src.path).filter { $0.contains("update") }
        #expect(left.isEmpty)
    }

    @Test func refusesABadChecksumAndLeavesTheAppAlone() async throws {
        let s = try Sandbox()
        let installed = try fakeApp(s.src, id: "com.noxhsxrk.shaken", marker: "old")
        let newDir = s.root.appendingPathComponent("new")
        _ = try fakeApp(newDir, id: "com.noxhsxrk.shaken", marker: "new")
        let dmg = s.root.appendingPathComponent("Shaken.dmg")
        try await makeDMG(from: newDir, to: dmg)
        await #expect(throws: ShakenError.self) {
            _ = try await Updater.install(dmg: dmg, expectedSHA256: String(repeating: "0", count: 64), replacing: installed,
                                          bundleID: "com.noxhsxrk.shaken", trashFolder: s.root)
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) == "old")
    }

    @Test func refusesAnotherApp() async throws {
        let s = try Sandbox()
        let installed = try fakeApp(s.src, id: "com.noxhsxrk.shaken", marker: "old")
        let newDir = s.root.appendingPathComponent("new")
        _ = try fakeApp(newDir, id: "com.example.other", marker: "new")
        let dmg = s.root.appendingPathComponent("Other.dmg")
        try await makeDMG(from: newDir, to: dmg)
        await #expect(throws: ShakenError.self) {
            _ = try await Updater.install(dmg: dmg, expectedSHA256: nil, replacing: installed, bundleID: "com.noxhsxrk.shaken", trashFolder: s.root)
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) == "old")
    }

    @Test func readsTheDMGAndChecksumFromARelease() {
        let json = #"{"tag_name":"v0.3.0","html_url":"https://github.com/noxhsxrk/shaken/releases/tag/v0.3.0","draft":false,"prerelease":false,"body":"Notes\n\nSHA-256: `2DB39666DE43E469F729108C4EF52A0BBC5A1DE9C0B75DE1E34280DD67037156`","assets":[{"name":"Shaken-0.3.0.dmg","browser_download_url":"https://github.com/noxhsxrk/shaken/releases/download/v0.3.0/Shaken-0.3.0.dmg"}]}"#
        let r = UpdateCheck.parse(Data(json.utf8))
        #expect(r?.dmg?.lastPathComponent == "Shaken-0.3.0.dmg")
        #expect(r?.sha256 == "2db39666de43e469f729108c4ef52a0bbc5a1de9c0b75de1e34280dd67037156")
    }
}
