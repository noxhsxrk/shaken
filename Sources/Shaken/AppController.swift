import AppKit
import ServiceManagement
import ShakenCore

/// Wires the pipeline: gesture → drag reader → resolver → wheel → job runner → chip.
final class AppController: NSObject, WheelDelegate, ChipDelegate, ShelfTrayDelegate, NSMenuDelegate {
    let store = SettingsStore()
    let registry = ActionRegistry()
    let packs = PackManager()
    let shelf = ShelfStore()
    let tray = ShelfTrayController()
    lazy var runner = JobRunner(shrinkTargetKB: store.settings.shrinkTargetKB)
    lazy var monitor = DragMonitor(settings: store.settings)
    let wheel = WheelController()
    let chip = ChipController()
    let escape = EscapeKey()
    let wheelKeys = WheelKeys()

    /// Wheels to flip through with ⌘← / ⌘→ when opened without dragging.
    /// `slots == nil` is the page of running apps.
    private struct WheelPage { var name: String; var slots: [Slot]? }
    private var pages: [WheelPage] = []
    private var pageIndex = 0
    private var clickPayload = DragPayload([])
    private var clickActions: [ActionManifest] = []

    private var statusItem: NSStatusItem!
    private var hotKeyID: UInt32?
    private var job: Task<Void, Never>?
    private var lastResult: JobResult?
    private var settingsWindow: SettingsWindowController?

    /// What commands clicked on a wheel opened without dragging work on.
    private enum ClickSource { case shelf, clipboard }
    private var clickSource: ClickSource = .clipboard

    /// Bundle ids, most recently active first (for the app switcher). Shaken itself is left out.
    private var recentApps: [String] = []

    /// Layout is computed once per drag so slots never move mid-drag (R5).
    private var cachedLayout: (changeCount: Int, slots: [ResolvedSlot], summary: String)?

    func start() {
        ShakenPaths.ensure()
        cleanInbox()
        shelf.cleanOrphans()
        wheel.delegate = self
        chip.delegate = self
        tray.delegate = self
        escape.handler = { [weak self] in self?.escapePressed() }
        wheelKeys.handler = { [weak self] k in self?.wheelKey(k) }

        store.onChange = { [weak self] s in self?.settingsChanged(s) }
        monitor.onShake = { [weak self] p in self?.openWheelForDrag(at: p) }
        monitor.onEmptyShake = { [weak self] p in self?.openWheelWithoutDrag(at: p) }
        monitor.onMouseDown = { [weak self] p in self?.globalMouseDown(p) }
        monitor.start()

        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { recentApps = [front] }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            self?.recentApps.removeAll { $0 == id }
            self?.recentApps.insert(id, at: 0)
        }

        setUpStatusItem()
        registerHotKey()
        installSampleActionsIfEmpty()
    }

    // MARK: settings

    private func settingsChanged(_ s: ShakenSettings) {
        monitor.settings = s
        runner.shrinkTargetKB = s.shrinkTargetKB
        cachedLayout = nil
        registerHotKey()
    }

    private func registerHotKey() {
        HotKeyCenter.shared.unregister(hotKeyID)
        hotKeyID = nil
        let hk = store.settings.hotKey
        if let code = hk.keyCode {
            hotKeyID = HotKeyCenter.shared.register(keyCode: code, modifiers: hk.modifiers) { [weak self] in
                self?.openWheelWithoutDrag(at: NSEvent.mouseLocation)
            }
        }
    }

    // MARK: opening the wheel

    func openWheelForDrag(at p: NSPoint) {
        guard !wheel.isVisible else { return }
        let pb = NSPasteboard(name: .drag)
        let layout: (Int, [ResolvedSlot], String)
        if let c = cachedLayout, c.changeCount == pb.changeCount {
            layout = c
        } else {
            let payload = DragReader.preview(pb)
            guard !payload.isEmpty else { return }
            let slots = fillSwitchers(ActionResolver.layout(payload: payload, actions: registry.actions, settings: store.settings),
                                      canDrop: payload.items.contains { [.file, .folder, .promise].contains($0.kind) })
            layout = (pb.changeCount, slots, payload.summary)
            cachedLayout = layout
        }
        chip.close()
        lastResult = nil
        wheel.show(at: p, slots: layout.1, summary: layout.2, mode: .drag, shelfCount: shelf.items.count)
        escape.activate()
    }

    /// Hot key, menu bar or ⌥ + shake (R2). Commands work on the shelf if it has
    /// anything, otherwise on the clipboard; leftover slots become handy folders.
    func openWheelWithoutDrag(at p: NSPoint) {
        if wheel.isVisible { closeWheel(); return }
        shelf.pruneMissing()
        let payload: DragPayload
        let summary: String
        if !shelf.isEmpty {
            clickSource = .shelf
            payload = shelf.payload
            summary = L("Shelf · %@", String(shelf.items.count))
        } else {
            clickSource = .clipboard
            payload = DragReader.preview(NSPasteboard.general)
            summary = payload.isEmpty ? L("Shaken") : L("Clipboard: %@", payload.summary)
        }
        // The clipboard already holds this text, so "Copy text" / "Copy link" would do nothing.
        let actions = clickSource == .clipboard ? registry.actions.filter { !$0.onlyCopiesText } : registry.actions
        clickPayload = payload
        clickActions = actions
        clickSummary = summary
        // Pages: the main wheel, each app's wheel, then running apps. Start on the front app's own wheel.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appWheels = store.settings.appWheels.sorted { $0.value.name < $1.value.name }
        pages = [WheelPage(name: L("Main"), slots: store.settings.slots)]
            + appWheels.map { WheelPage(name: $0.value.name, slots: $0.value.slots) }
            + [WheelPage(name: L("Running apps"), slots: nil)]
        pageIndex = appWheels.firstIndex { $0.key == front }.map { $0 + 1 } ?? 0
        let slots = layoutPage(pageIndex)
        chip.close()
        wheel.show(at: p, slots: slots, summary: summary, mode: .click, shelfCount: shelf.items.count, page: pageLabel)
        if clickSource == .shelf { tray.show(items: shelf.items, below: wheel.frame) }
        escape.activate()
        wheelKeys.activate()
    }

    private var pageLabel: WheelPageInfo? {
        pages.count > 1 ? WheelPageInfo(name: pages[pageIndex].name, index: pageIndex, count: pages.count) : nil
    }
    private var clickSummary = ""

    private func layoutPage(_ i: Int) -> [ResolvedSlot] {
        guard let slots = pages[i].slots else {
            var apps = fillSwitchers([ResolvedSlot(id: "running", kind: .switcher, title: "", icon: "", target: "")], canDrop: false)[0].children
            while apps.count < ShakenSettings.slotCount {
                apps.append(ResolvedSlot(id: "running-empty-\(apps.count)", kind: .empty, title: "", icon: "", target: "", enabled: false))
            }
            return apps
        }
        return fillSwitchers(ActionResolver.layout(payload: clickPayload, actions: clickActions, settings: store.settings,
                                                   fallbacks: ActionResolver.defaultFallbacks(), slots: slots),
                             canDrop: false)
    }

    private func wheelKey(_ k: WheelKeys.Key) {
        guard wheel.isVisible, wheel.mode == .click else { return }
        switch k {
        case .nextWheel, .previousWheel:
            guard pages.count > 1 else { return }
            pageIndex = (pageIndex + (k.isNext ? 1 : -1) + pages.count) % pages.count
            wheel.replace(slots: layoutPage(pageIndex), summary: clickSummary, shelfCount: shelf.items.count, page: pageLabel)
        default:
            wheel.key(k)
        }
    }

    /// The switcher's ring: up to six recently used apps, not counting the one in front.
    private func fillSwitchers(_ slots: [ResolvedSlot], canDrop: Bool) -> [ResolvedSlot] {
        guard slots.contains(where: { $0.kind == .switcher }) else { return slots }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleURL != nil
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let rank = Dictionary(recentApps.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let apps = running
            .filter { $0.bundleIdentifier != front || canDrop }
            .sorted { (rank[$0.bundleIdentifier ?? ""] ?? Int.max) < (rank[$1.bundleIdentifier ?? ""] ?? Int.max) }
            .prefix(ShakenSettings.maxChildren)
        let children = apps.map { a in
            ResolvedSlot(id: "switch-\(a.processIdentifier)", kind: .app, title: a.localizedName ?? "", icon: a.bundleURL!.path,
                         target: a.bundleURL!.path, actionID: nil, enabled: true, note: nil, children: [])
        }
        return slots.map { s in
            guard s.kind == .switcher else { return s }
            var r = s
            r.children = children
            r.enabled = s.enabled && !children.isEmpty
            return r
        }
    }

    func closeWheel() {
        wheelKeys.deactivate()
        wheel.close()
        tray.close()
        updateEscape()
    }

    func wheelShouldClose() { closeWheel() }

    func wheelSwipe(next: Bool) { wheelKey(next ? .nextWheel : .previousWheel) }

    private func updateEscape() {
        if wheel.isVisible || chip.isVisible || tray.isVisible || job != nil { escape.activate() } else { escape.deactivate() }
    }

    private func escapePressed() {
        if let job {
            job.cancel()
        } else if wheel.isVisible {
            closeWheel()
        } else if chip.isVisible {
            chipClose()
        } else if tray.isVisible {
            tray.close()
            updateEscape()
        } else {
            escape.deactivate()
        }
    }

    private func globalMouseDown(_ p: NSPoint) {
        if wheel.isVisible && wheel.mode == .click && !NSMouseInRect(p, wheel.frame, false)
            && !(tray.isVisible && NSMouseInRect(p, tray.frame, false)) { closeWheel() }
        if chip.isVisible && job == nil && !NSMouseInRect(p, chip.frame, false) { chipClose() }
        if !wheel.isVisible { cachedLayout = nil }
    }

    // MARK: performing a slot

    func wheel(didDrop slot: ResolvedSlot, pasteboard: NSPasteboard, at point: NSPoint) {
        closeWheel()
        cachedLayout = nil
        chip.show(.running(slot.title), at: point)
        updateEscape()
        DragReader.materialize(pasteboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let input): self.perform(slot, input: input, at: point)
            case .failure(let e): self.fail(e)
            }
        }
    }

    func wheel(didDropOnShelf pasteboard: NSPasteboard, at point: NSPoint) {
        closeWheel()
        cachedLayout = nil
        DragReader.materialize(pasteboard, into: ShakenPaths.shelfFiles) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let input):
                self.shelf.add(input)
                self.updateEscape()
            case .failure(let e):
                self.fail(e)
            }
        }
    }

    func wheel(didClick slot: ResolvedSlot, at point: NSPoint) {
        closeWheel()
        // On the shelf: commands, apps and folders take the shelved items.
        if clickSource == .shelf, [.action, .app, .folder, .shortcut, .shell, .applescript].contains(slot.kind), let input = shelf.jobInput {
            chip.show(.running(slot.title), at: point)
            updateEscape()
            perform(slot, input: input, at: point)
            return
        }
        switch slot.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: slot.target), configuration: .init())
        case .web:
            if let u = URL(string: slot.target.replacingOccurrences(of: "{query}", with: "")) { NSWorkspace.shared.open(u) }
        case .folder, .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: slot.target))
        case .shortcut:
            chip.show(.running(slot.title), at: point)
            updateEscape()
            runShortcut(slot, input: nil)
        case .snippet, .keys:
            guard Typing.ensureTrusted() else { return fail(Typing.notTrustedError) }
            // Let the wheel close so the front app has the keyboard again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.typeSlot(slot) }
        case .shell, .applescript:
            chip.show(.running(slot.title), at: point)
            updateEscape()
            runScript(slot, input: nil)
        case .system:
            guard let c = SystemControl(rawValue: slot.target) else { return }
            Task { @MainActor in
                // Let the wheel close first so key presses reach the app in front.
                try? await Task.sleep(nanoseconds: 80_000_000)
                do { try await SystemActions.perform(c) } catch { self.fail(error) }
            }
        case .workflow:
            runWorkflow(slot.children, at: point)
        case .action:
            chip.show(.running(slot.title), at: point)
            updateEscape()
            DragReader.materialize(NSPasteboard.general) { [weak self] result in
                switch result {
                case .success(let input): self?.perform(slot, input: input, at: point)
                case .failure(let e): self?.fail(e)
                }
            }
        default:
            break
        }
    }

    private func perform(_ slot: ResolvedSlot, input: JobInput, at point: NSPoint) {
        switch slot.kind {
        case .action:
            guard let id = slot.actionID ?? Optional(slot.target), let action = registry.action(id: id) else {
                return fail(ShakenError.other(L("Action not found")))
            }
            if PackManager.needsApproval(action) && !PackManager.isApproved(action, settings: store.settings) {
                chip.close()
                guard ApprovalDialog.ask(for: action) else { updateEscape(); return }
                approve(action)
                chip.show(.running(slot.title), at: point)
            }
            run(label: action.displayName) { try await $0.run(action, input: input) }

        case .folder:
            let folder = URL(fileURLWithPath: slot.target)
            guard !input.files.isEmpty else { return fail(ShakenError.unsupportedInput(L("Only files can be copied to a folder"))) }
            run(label: slot.title) { try await $0.copy(input.files, into: folder) }

        case .app:
            let app = URL(fileURLWithPath: slot.target)
            let urls: [URL]
            switch input {
            case .files(let f): urls = f
            case .link(let u): urls = [u]
            case .text: return fail(ShakenError.unsupportedInput(L("Text")))
            }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, error in
                DispatchQueue.main.async { if let error { self.fail(error) } else { self.chipClose() } }
            }

        case .shortcut:
            runShortcut(slot, input: input)

        case .shell, .applescript:
            runScript(slot, input: input)

        case .web:
            var target = slot.target
            let query: String
            switch input {
            case .text(let t): query = t
            case .link(let u): query = u.absoluteString
            case .files(let f): query = f.map(\.lastPathComponent).joined(separator: " ")
            }
            target = target.replacingOccurrences(of: "{query}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? "")
            guard let u = URL(string: target) else { return fail(ShakenError.other(L("Invalid web address"))) }
            NSWorkspace.shared.open(u)
            chipClose()

        default:
            chipClose()
        }
    }

    private func runShortcut(_ slot: ResolvedSlot, input: JobInput?) {
        job?.cancel()
        job = Task { @MainActor [weak self] in
            do {
                try await Shortcuts.run(slot.target, input: input)
                self?.job = nil
                self?.chipClose()
            } catch is CancellationError {
                self?.job = nil
                self?.chipClose()
            } catch {
                self?.fail(error)
            }
            self?.updateEscape()
        }
        updateEscape()
    }

    /// "Run now" in Settings: does what clicking the slot on a wheel opened without dragging does.
    func runFromSettings(_ slot: Slot) {
        guard let r = ActionResolver.layout(payload: DragPayload([]), actions: registry.actions, settings: store.settings,
                                            slots: [slot]).first, r.enabled else { return }
        clickSource = .clipboard
        let p = NSEvent.mouseLocation
        if r.kind == .switcher, let first = fillSwitchers([r], canDrop: false).first?.children.first {
            return wheel(didClick: first, at: p)
        }
        wheel(didClick: r, at: p)
    }

    private func runScript(_ slot: ResolvedSlot, input: JobInput?) {
        job?.cancel()
        job = Task { @MainActor [weak self] in
            do {
                try await InlineScript.run(slot.target, language: slot.kind == .shell ? .shell : .applescript, input: input)
                self?.job = nil
                self?.chipClose()
            } catch is CancellationError {
                self?.job = nil
                self?.chipClose()
            } catch {
                self?.fail(error)
            }
            self?.updateEscape()
        }
        updateEscape()
    }

    private func typeSlot(_ slot: ResolvedSlot) {
        switch slot.kind {
        case .snippet: Typing.paste(slot.target)
        case .keys: if let k = KeyCombo(slot.target) { Typing.press(k) }
        default: break
        }
    }

    /// Runs a workflow's steps in order, pausing so apps can open before the next step.
    private func runWorkflow(_ steps: [ResolvedSlot], at point: NSPoint) {
        let needsTyping = steps.contains { [.snippet, .keys].contains($0.kind)
            || ($0.kind == .system && SystemControl(rawValue: $0.target)?.needsAccessibility == true) }
        if needsTyping && !Typing.ensureTrusted() {
            return fail(Typing.notTrustedError)
        }
        job?.cancel()
        job = Task { @MainActor [weak self] in
            for step in steps {
                guard let self, !Task.isCancelled else { break }
                switch step.kind {
                case .app:
                    let cfg = NSWorkspace.OpenConfiguration()
                    _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: step.target), configuration: cfg)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                case .web:
                    if let u = URL(string: step.target.replacingOccurrences(of: "{query}", with: "")) { NSWorkspace.shared.open(u) }
                case .folder, .file:
                    NSWorkspace.shared.open(URL(fileURLWithPath: step.target))
                case .shortcut:
                    do { try await Shortcuts.run(step.target) } catch { self.fail(error); return }
                case .snippet, .keys:
                    self.typeSlot(step)
                case .shell, .applescript:
                    do { try await InlineScript.run(step.target, language: step.kind == .shell ? .shell : .applescript) }
                    catch { self.fail(error); return }
                case .system:
                    if let c = SystemControl(rawValue: step.target) {
                        do { try await SystemActions.perform(c) } catch { self.fail(error); return }
                    }
                case .delay:
                    try? await Task.sleep(nanoseconds: UInt64((Double(step.target) ?? 0.5) * 1_000_000_000))
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.job = nil
            self?.updateEscape()
        }
        updateEscape()
    }

    func approve(_ action: ActionManifest) {
        if let fp = try? PackManager.fingerprint(of: action) {
            store.update { $0.approvals[action.id] = fp }
        }
    }

    private func run(label: String, _ work: @escaping (JobRunner) async throws -> JobResult) {
        job?.cancel()
        let runner = self.runner
        job = Task { @MainActor [weak self] in
            do {
                let r = try await work(runner)
                guard let self else { return }
                self.job = nil
                self.lastResult = r
                if r.outputs.isEmpty {
                    self.chipClose()
                } else {
                    self.chip.show(.done(r))
                }
            } catch is CancellationError {
                self?.job = nil
                self?.chipClose()
            } catch {
                self?.job = nil
                self?.fail(error)
            }
            self?.updateEscape()
        }
        updateEscape()
    }

    private func fail(_ error: Error) {
        job = nil
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        chip.show(.failed(msg))
        updateEscape()
    }

    // MARK: shelf tray

    func shelfTrayDragBegan() {
        // Get the wheel out of the way so the drop target underneath is reachable.
        wheel.close()
    }

    func shelfTrayDragEnded(ids: [String], delivered: Bool) {
        // Once something has been put somewhere, it leaves the shelf.
        if delivered { shelf.remove(ids) }
        tray.close()
        updateEscape()
    }

    func shelfTrayRemove(_ ids: [String]) {
        if ids.isEmpty { shelf.clear() } else { shelf.remove(ids) }
        if shelf.isEmpty { closeWheel() } else { tray.show(items: shelf.items, below: wheel.frame) }
    }

    // MARK: chip

    func chipUndo() {
        guard let r = lastResult else { return }
        do {
            try JobRunner.undo(r)
            lastResult = nil
            chipClose()
        } catch {
            fail(error)
        }
    }

    func chipClose() {
        chip.close()
        updateEscape()
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.wave", accessibilityDescription: "Shaken")
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

        // Developer tool: record real pointer traces for the gesture test suite.
        let traces = NSMenuItem(title: L("Record Gesture Traces"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let modes: [(String, TraceRecorder.Mode)] = [
            (L("Off"), .off), (L("Shakes · mouse"), .mouseShake), (L("Shakes · trackpad"), .trackpadShake),
            (L("Normal drags · mouse"), .mouseDrag), (L("Normal drags · trackpad"), .trackpadDrag),
        ]
        for (title, mode) in modes {
            let i = NSMenuItem(title: title, action: #selector(setTraceMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = mode.rawValue
            i.state = monitor.recorder.mode == mode ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let show = NSMenuItem(title: L("Show Traces Folder"), action: #selector(showTraces), keyEquivalent: "")
        show.target = self
        sub.addItem(show)
        traces.submenu = sub
        menu.addItem(traces)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Shaken"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func menuOpenWheel() {
        // Let the menu close first so the wheel isn't dismissed by its click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openWheelWithoutDrag(at: NSEvent.mouseLocation) }
    }

    @objc private func togglePause() { monitor.isPaused.toggle() }

    @objc private func clearShelf() { shelf.clear() }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }

    @objc private func openActionsFolder() {
        try? FileManager.default.createDirectory(at: ShakenPaths.actions, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ShakenPaths.actions)
    }

    @objc private func setTraceMode(_ sender: NSMenuItem) {
        monitor.recorder.mode = TraceRecorder.Mode(rawValue: sender.representedObject as? String ?? "off") ?? .off
    }

    @objc private func showTraces() {
        try? FileManager.default.createDirectory(at: ShakenPaths.traces, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ShakenPaths.traces)
    }

    // MARK: housekeeping

    private func cleanInbox() {
        try? FileManager.default.removeItem(at: ShakenPaths.inbox)
        try? FileManager.default.createDirectory(at: ShakenPaths.inbox, withIntermediateDirectories: true)
    }

    /// First launch: copy the example actions bundled in the app so there's something to edit.
    private func installSampleActionsIfEmpty() {
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
