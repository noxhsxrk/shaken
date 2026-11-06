import AppKit
import ServiceManagement
import ShakenCore

/// The menu bar item, its menu, and housekeeping at launch.
extension AppController {
    // MARK: menu bar

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Brand.menuBarImage()
        statusItem.button?.toolTip = "Shaken"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: L("Open Wheel"), action: #selector(menuOpenWheel), keyEquivalent: "")
        open.target = self
        if store.settings.hotKey.keyCode != nil { open.title += "   " + store.settings.hotKey.display }
        menu.addItem(open)

        shelf.pruneMissing()
        let shelfItem = NSMenuItem(title: L("Shelf · %@", String(shelf.items.count)), action: shelf.isEmpty ? nil : #selector(menuOpenWheel), keyEquivalent: "")
        shelfItem.target = self
        menu.addItem(shelfItem)
        if !shelf.isEmpty {
            let clear = NSMenuItem(title: L("Clear Shelf"), action: #selector(clearShelf), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        let pause = NSMenuItem(title: L("Pause Shake Detection"), action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = monitor.isPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())

        for (title, sel) in [(L("Settings…"), #selector(openSettings)), (L("Open Actions Folder"), #selector(openActionsFolder))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: title == L("Settings…") ? "," : "")
            item.target = self
            menu.addItem(item)
        }

        // Help: welcome, updates, diagnostics, and the trace recorder for tuning the gesture.
        let help = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, sel) in [(L("Show Welcome…"), #selector(showWelcome)),
                             (L("Check for Updates…"), #selector(checkForUpdates)),
                             (L("Copy Diagnostics"), #selector(copyDiagnostics)),
                             (L("Report a Problem…"), #selector(reportProblem))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let traces = NSMenuItem(title: L("Record Gesture Traces"), action: nil, keyEquivalent: "")
        let traceMenu = NSMenu()
        let modes: [(String, TraceRecorder.Mode)] = [
            (L("Off"), .off), (L("Shakes · mouse"), .mouseShake), (L("Shakes · trackpad"), .trackpadShake),
            (L("Normal drags · mouse"), .mouseDrag), (L("Normal drags · trackpad"), .trackpadDrag),
        ]
        for (title, mode) in modes {
            let i = NSMenuItem(title: title, action: #selector(setTraceMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = mode.rawValue
            i.state = monitor.recorder.mode == mode ? .on : .off
            traceMenu.addItem(i)
        }
        traceMenu.addItem(.separator())
        let show = NSMenuItem(title: L("Show Traces Folder"), action: #selector(showTraces), keyEquivalent: "")
        show.target = self
        traceMenu.addItem(show)
        traces.submenu = traceMenu
        sub.addItem(traces)
        help.submenu = sub
        menu.addItem(help)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Shaken"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindowController(app: self) }
        welcomeWindow?.show()
    }

    // MARK: updates

    /// At most once a day, and only if the user left it on.
    func checkForUpdatesInBackground() {
        guard store.settings.checkForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { @MainActor in
            UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
            do {
                if let r = try await UpdateCheck.latest(newerThan: currentVersion) { offerUpdate(r) }
            } catch {
                Log.info("update check failed: \(error.localizedDescription)")   // quiet in the background
            }
        }
    }

    /// Help › Check for Updates and Settings › Check Now: if there's a newer version, install it
    /// straight away and relaunch. Progress shows in the chip.
    @objc func checkForUpdates() {
        Task { @MainActor in
            do {
                if let r = try await UpdateCheck.latest(newerThan: currentVersion) {
                    installUpdate(r)
                } else {
                    let a = NSAlert()
                    a.messageText = L("Shaken is up to date")
                    a.informativeText = L("You have version %@.", currentVersion)
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// The daily background check asks first, since it wasn't the user's idea.
    func offerUpdate(_ r: UpdateCheck.Release) {
        let a = NSAlert()
        a.messageText = L("Shaken %@ is available", r.version)
        a.informativeText = L("You have %@. Shaken can install it now and reopen itself.", currentVersion)
        a.addButton(withTitle: L("Install and Relaunch"))
        a.addButton(withTitle: L("Later"))
        a.addButton(withTitle: L("What's New"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: installUpdate(r)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    /// Downloads, verifies and swaps in the new version, then relaunches. If that can't be done
    /// (no DMG on the release, the app isn't in a writable folder), opens the release page instead.
    func installUpdate(_ r: UpdateCheck.Release) {
        guard let dmg = r.dmg, let id = Bundle.main.bundleIdentifier, Bundle.main.bundleURL.pathExtension == "app" else {
            NSWorkspace.shared.open(r.page)
            return
        }
        let anchor = NSPoint(x: NSScreen.main.map { $0.visibleFrame.maxX - 200 } ?? 800,
                             y: NSScreen.main.map { $0.visibleFrame.maxY - 60 } ?? 600)
        chip.show(.running(L("Updating to %@", r.version)), at: anchor)
        updateEscape()
        Log.info("installing update \(r.version)")
        let bundle = Bundle.main.bundleURL
        Task { @MainActor in
            do {
                let app = try await Updater.install(dmg: dmg, expectedSHA256: r.sha256, replacing: bundle, bundleID: id)
                Log.info("update installed, relaunching")
                Self.relaunch(app)
            } catch {
                self.fail(error)
                let a = NSAlert()
                a.messageText = L("The update couldn't be installed")
                a.informativeText = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    + "\n\n" + L("You can download it from GitHub instead.")
                a.addButton(withTitle: L("Open Download Page"))
                a.addButton(withTitle: L("Cancel"))
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
            }
        }
    }

    /// Starts the new copy once this one has quit.
    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "relaunch",
                       String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc func copyDiagnostics() {
        let text = Diagnostics.report(settings: store.settings, actions: registry.actions.count, shelfItems: shelf.items.count)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func reportProblem() {
        copyDiagnostics()
        if let u = URL(string: "https://github.com/noxhsxrk/shaken/issues/new?template=bug.yml") { NSWorkspace.shared.open(u) }
    }

    @objc func menuOpenWheel() {
        // Let the menu close first so the wheel isn't dismissed by its click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openWheelWithoutDrag(at: NSEvent.mouseLocation) }
    }

    @objc func togglePause() { monitor.isPaused.toggle() }

    @objc func clearShelf() { shelf.clear() }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }

    @objc func openActionsFolder() {
        try? FileManager.default.createDirectory(at: ShakenPaths.actions, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ShakenPaths.actions)
    }

    @objc func setTraceMode(_ sender: NSMenuItem) {
        monitor.recorder.mode = TraceRecorder.Mode(rawValue: sender.representedObject as? String ?? "off") ?? .off
    }

    @objc func showTraces() {
        try? FileManager.default.createDirectory(at: ShakenPaths.traces, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ShakenPaths.traces)
    }

    // MARK: housekeeping

    func cleanInbox() {
        try? FileManager.default.removeItem(at: ShakenPaths.inbox)
        try? FileManager.default.createDirectory(at: ShakenPaths.inbox, withIntermediateDirectories: true)
    }

    /// First launch: copy the example actions bundled in the app so there's something to edit.
    func installSampleActionsIfEmpty() {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: ShakenPaths.actions.path))?.filter({ !$0.hasPrefix(".") }).isEmpty ?? true,
              let examples = Bundle.main.resourceURL?.appendingPathComponent("Examples"),
              let items = try? fm.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil) else { return }
        let marker = ShakenPaths.support.appendingPathComponent(".examples-installed")
        guard !fm.fileExists(atPath: marker.path) else { return }
        for item in items { try? fm.copyItem(at: item, to: ShakenPaths.actions.appendingPathComponent(item.lastPathComponent)) }
        fm.createFile(atPath: marker.path, contents: nil)
        registry.reload()
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSAlert(error: error).runModal() }
        }
    }
}
