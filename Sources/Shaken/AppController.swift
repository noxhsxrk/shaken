import AppKit
import ServiceManagement
import ShakenCore

/// Wires the pipeline: gesture → drag reader → resolver → wheel → job runner → chip.
final class AppController: NSObject, WheelDelegate, ChipDelegate, NSMenuDelegate {
    let store = SettingsStore()
    let registry = ActionRegistry()
    let packs = PackManager()
    lazy var runner = JobRunner(shrinkTargetKB: store.settings.shrinkTargetKB)
    lazy var monitor = DragMonitor(settings: store.settings)
    let wheel = WheelController()
    let chip = ChipController()
    let escape = EscapeKey()

    private var statusItem: NSStatusItem!
    private var hotKeyID: UInt32?
    private var job: Task<Void, Never>?
    private var lastResult: JobResult?
    private var settingsWindow: SettingsWindowController?

    /// Layout is computed once per drag so slots never move mid-drag (R5).
    private var cachedLayout: (changeCount: Int, slots: [ResolvedSlot], summary: String)?

    func start() {
        ShakenPaths.ensure()
        cleanInbox()
        wheel.delegate = self
        chip.delegate = self
        escape.handler = { [weak self] in self?.escapePressed() }

        store.onChange = { [weak self] s in self?.settingsChanged(s) }
        monitor.onShake = { [weak self] p in self?.openWheelForDrag(at: p) }
        monitor.onEmptyShake = { [weak self] p in self?.openWheelWithoutDrag(at: p) }
        monitor.onMouseDown = { [weak self] p in self?.globalMouseDown(p) }
        monitor.start()

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
            let slots = ActionResolver.layout(payload: payload, actions: registry.actions, settings: store.settings)
            layout = (pb.changeCount, slots, payload.summary)
            cachedLayout = layout
        }
        chip.close()
        lastResult = nil
        wheel.show(at: p, slots: layout.1, summary: layout.2, mode: .drag)
        escape.activate()
    }

    /// Hot key, menu bar or ⌥ + shake (R2). Actions work on what's on the clipboard.
    func openWheelWithoutDrag(at p: NSPoint) {
        if wheel.isVisible { closeWheel(); return }
        let payload = DragReader.preview(NSPasteboard.general)
        let slots = ActionResolver.layout(payload: payload, actions: registry.actions, settings: store.settings)
        let summary = payload.isEmpty ? L("Shaken") : L("Clipboard: %@", payload.summary)
        chip.close()
        wheel.show(at: p, slots: slots, summary: summary, mode: .click)
        escape.activate()
    }

    func closeWheel() {
        wheel.close()
        updateEscape()
    }

    func wheelShouldClose() { closeWheel() }

    private func updateEscape() {
        if wheel.isVisible || chip.isVisible || job != nil { escape.activate() } else { escape.deactivate() }
    }

    private func escapePressed() {
        if let job {
            job.cancel()
        } else if wheel.isVisible {
            closeWheel()
        } else if chip.isVisible {
            chipClose()
        } else {
            escape.deactivate()
        }
    }

    private func globalMouseDown(_ p: NSPoint) {
        if wheel.isVisible && wheel.mode == .click && !NSMouseInRect(p, wheel.frame, false) { closeWheel() }
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

    func wheel(didClick slot: ResolvedSlot, at point: NSPoint) {
        closeWheel()
        switch slot.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: slot.target), configuration: .init())
        case .web:
            if let u = URL(string: slot.target.replacingOccurrences(of: "{query}", with: "")) { NSWorkspace.shared.open(u) }
        case .folder:
            NSWorkspace.shared.open(URL(fileURLWithPath: slot.target))
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
                    if let m = r.message { self.chip.show(.info(m)) } else { self.chipClose() }
                } else {
                    self.chip.show(.done(r))
                }
            } catch is CancellationError {
                self?.job = nil
                self?.chip.show(.info(L("Cancelled")))
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

    // MARK: chip

    func chipUndo() {
        guard let r = lastResult else { return }
        do {
            try JobRunner.undo(r)
            lastResult = nil
            chip.show(.info(L("Moved to Trash")))
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
