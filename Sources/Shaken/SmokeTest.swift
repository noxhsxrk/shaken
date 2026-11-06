import AppKit
import ShakenCore

/// Dev aid: `scripts/smoke.sh` (or `SHAKEN_SMOKE=1 SHAKEN_SUPPORT_DIR=<empty folder> Shaken`) drives the
/// real app objects through the main flows and prints PASS or FAIL for each check: drop on the
/// wheel, the chip and undo, the shelf, right-click to change a slot, switching wheels, glass
/// color and Settings. It exits 0 only if every check passes.
///
/// It never calls `start()`, so no menu bar item, hot key or mouse monitor is installed, and with
/// `SHAKEN_SUPPORT_DIR` set it never touches your own settings, shelf or commands. Undo moves the
/// one file it made to the Trash, as it does in the app.
enum SmokeTest {
    @MainActor static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["SHAKEN_SMOKE"] != nil else { return }
        guard env["SHAKEN_SUPPORT_DIR"] != nil else {
            print("Set SHAKEN_SUPPORT_DIR to an empty folder, so your own settings are left alone.")
            exit(2)
        }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "(\(detail))")
            if !ok { failures += 1 }
        }
        @discardableResult func wait(_ seconds: Double = 5, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return done()
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let app = AppController()
        Brand.look = { [store = app.store] in (store.settings.glassTint, store.settings.glassTintHex, store.settings.glassTintStrength) }
        let work = ShakenPaths.support.appendingPathComponent("Work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func png(_ name: String) -> URL {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 0, width: 200, height: 200).fill()
            NSGraphicsContext.restoreGraphicsState()
            let url = work.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            return url
        }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let centre = NSPoint(x: screen.midX, y: screen.midY)

        // 1. Drag a PNG and shake: image commands; drop on Convert to JPG; the chip; undo.
        let photo = png("Photo.png")
        let drag = NSPasteboard(name: .drag)
        drag.clearContents()
        drag.writeObjects([photo as NSURL])
        app.openWheelForDrag(at: centre)
        check("drag: the wheel opens", app.wheel.isVisible)
        let dragSlots = app.cachedLayout?.slots ?? []
        let toJPG = dragSlots.first { $0.actionID == "builtin.to-jpg" }
        check("drag: image commands are offered", toJPG != nil, dragSlots.compactMap(\.actionID).joined(separator: ", "))
        check("drag: remembers the kind for Settings", app.lastKind == .image)
        if let toJPG {
            app.wheel(didDrop: toJPG, pasteboard: drag, at: centre)
            check("drop: the wheel closes", !app.wheel.isVisible)
            let done = wait { app.lastResult != nil }
            let out = app.lastResult?.outputs.first
            check("drop: a JPG appears next to the original", done && out?.lastPathComponent == "Photo.jpg"
                  && out.map { FileManager.default.fileExists(atPath: $0.path) } == true, out?.path ?? "no result")
            check("chip: shows the result", app.chip.isVisible)
            app.chipUndo()
            check("undo: the JPG goes to the Trash", out.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
            check("undo: the original stays", FileManager.default.fileExists(atPath: photo.path))
        }
        app.chipClose()

        // 2. The shelf: two items, then the wheel without dragging.
        app.shelf.add(.files([png("A.png"), png("B.png")]))
        app.openWheelWithoutDrag(at: centre)
        check("shelf: the wheel opens on the shelf", app.wheel.isVisible && app.clickSource == .shelf)
        check("shelf: the tray shows", app.tray.isVisible)
        check("shelf: two items count as Several items", app.lastKind == .multiple)

        // 3. Clicking a command on the shelf wheel runs it on the shelved items.
        if let zip = app.layoutPage(app.pageIndex).first(where: { $0.actionID == "builtin.zip" }) {
            app.lastResult = nil
            app.wheel(didClick: zip, at: centre)
            let done = wait { app.lastResult != nil }
            check("shelf: Compress to ZIP makes one archive", done && app.lastResult?.outputs.map(\.pathExtension) == ["zip"])
        } else {
            check("shelf: Compress to ZIP is on the wheel", false)
        }
        app.chipClose()

        app.openWheelWithoutDrag(at: centre)
        if !app.wheel.isVisible { app.openWheelWithoutDrag(at: centre) }

        // 4. Right-click slot 1: the menu says the kind; picking a command changes only that slot.
        let before = app.layoutPage(app.pageIndex).map(\.actionID)
        if let menu = app.slotMenu(forSlotAt: 0) {
            check("right-click: the menu names the kind", menu.items.contains { $0.title.contains(KindKey.multiple.title) })
            check("right-click: the current command is ticked", menu.items.contains { $0.state == .on })
            let pick = menu.items.firstIndex {
                $0 is ClosureMenuItem && $0.state == .off && $0.attributedTitle?.string.contains(L("Slot %@", "")) != true
                    && !$0.title.hasPrefix(L("Edit Wheels in Settings…"))
            }
            check("right-click: offers a command that isn't on the wheel", pick != nil)
            if let pick {
                let title = menu.items[pick].title
                menu.performActionForItem(at: pick)
                let after = app.layoutPage(app.pageIndex)
                check("right-click: slot 1 now shows it", after.first?.title == title, after.first?.title ?? "")
                check("right-click: the other slots stay put", Array(after.map(\.actionID).dropFirst()) == Array(before.dropFirst()))
                check("right-click: the choice is saved", app.store.settings.kindPreferences[KindKey.multiple.rawValue] != nil)
            }
        } else {
            check("right-click: a menu opens", false)
        }

        // 5. Switching wheels: the next wheel, and no turning layers left behind.
        app.store.update { $0.wheels.append(NamedWheel(name: "Second")) }
        app.closeWheel()
        app.openWheelWithoutDrag(at: centre)
        let first = app.pageIndex
        app.wheelKey(.nextWheel)
        check("switch: ⌘→ goes to the next wheel", app.pageIndex == (first + 1) % app.pages.count)
        wait(1.2)
        check("switch: the turn finishes cleanly", app.wheel.leftoverTurnLayers == 0, "\(app.wheel.leftoverTurnLayers) left")
        app.wheelKey(.previousWheel)
        wait(1.2)
        check("switch: ⌘← comes back", app.pageIndex == first)
        app.closeWheel()
        check("close: the wheel and tray close", !app.wheel.isVisible && !app.tray.isVisible)

        // 6. Glass color follows the setting.
        app.store.update { $0.glassTint = .custom; $0.glassTintHex = "#00FF00" }
        let custom = Brand.accent.usingColorSpace(.sRGB)
        check("glass: a custom color is used", (custom?.greenComponent ?? 0) > 0.99 && (custom?.redComponent ?? 1) < 0.01)
        app.store.update { $0.glassTint = .system }
        check("glass: Mac accent color is used", Brand.accent.usingColorSpace(.sRGB) == NSColor.controlAccentColor.usingColorSpace(.sRGB))

        // 7. Settings opens.
        app.openSettings()
        wait(0.5)
        check("settings: the window opens", app.settingsWindow?.window?.isVisible == true)
        app.settingsWindow?.window?.close()

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
