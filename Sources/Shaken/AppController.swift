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
    struct WheelPage { var name: String; var slots: [Slot]? }
    var pages: [WheelPage] = []
    var pageIndex = 0
    var clickPayload = DragPayload([])
    var clickActions: [ActionManifest] = []

    var statusItem: NSStatusItem!
    var hotKeyID: UInt32?
    var wheelHotKeyIDs: [UInt32] = []
    var hotKeysSuspended = false
    /// Display strings of shortcuts that couldn't be registered (already taken elsewhere).
    var failedHotKeys: Set<String> = []
    var job: Task<Void, Never>?
    var lastResult: JobResult?
    var settingsWindow: SettingsWindowController?

    /// What commands clicked on a wheel opened without dragging work on.
    enum ClickSource { case shelf, clipboard }
    var clickSource: ClickSource = .clipboard

    /// Bundle ids, most recently active first (for the app switcher). Shaken itself is left out.
    var recentApps: [String] = []

    /// Layout is computed once per drag so slots never move mid-drag (R5).
    var cachedLayout: (changeCount: Int, slots: [ResolvedSlot], summary: String)?

    static let welcomeShownKey = "welcomeShown"
    static let lastUpdateCheckKey = "lastUpdateCheck"
    var welcomeWindow: WelcomeWindowController?

    func start() {
        ShakenPaths.ensure()
        cleanInbox()
        shelf.cleanOrphans()
        wheel.delegate = self
        chip.delegate = self
        tray.delegate = self
        chip.ownDrag = monitor
        tray.ownDrag = monitor
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
        Log.info("started \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
        if !UserDefaults.standard.bool(forKey: Self.welcomeShownKey) { showWelcome() }
        checkForUpdatesInBackground()
    }

    // MARK: settings

    func settingsChanged(_ s: ShakenSettings) {
        monitor.settings = s
        runner.shrinkTargetKB = s.shrinkTargetKB
        cachedLayout = nil
        registerHotKey()
    }

    /// Registers the main shortcut and each wheel's own shortcut. A combination another app
    /// already holds can't be registered; Settings shows that from `failedHotKeys`.
    func registerHotKey() {
        HotKeyCenter.shared.unregister(hotKeyID)
        hotKeyID = nil
        wheelHotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        wheelHotKeyIDs = []
        failedHotKeys = []
        guard !hotKeysSuspended else { return }
        let hk = store.settings.hotKey
        if let code = hk.keyCode {
            hotKeyID = HotKeyCenter.shared.register(keyCode: code, modifiers: hk.modifiers) { [weak self] in
                self?.openWheelWithoutDrag(at: NSEvent.mouseLocation)
            }
            if hotKeyID == nil { failedHotKeys.insert(hk.display); Log.error("couldn't register shortcut \(hk.display)") }
        }
        for w in store.settings.wheels {
            guard let code = w.hotKey.keyCode else { continue }
            let id = w.id
            if let r = HotKeyCenter.shared.register(keyCode: code, modifiers: w.hotKey.modifiers, handler: { [weak self] in
                self?.openWheelWithoutDrag(at: NSEvent.mouseLocation, wheelID: id)
            }) {
                wheelHotKeyIDs.append(r)
            } else {
                failedHotKeys.insert(w.hotKey.display)
                Log.error("couldn't register shortcut \(w.hotKey.display)")
            }
        }
    }

    /// While Settings records a new shortcut, ours are released so pressing them is recorded, not run.
    func suspendHotKeys(_ suspend: Bool) {
        hotKeysSuspended = suspend
        registerHotKey()
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
    /// - Parameter wheelID: open on this extra wheel instead of the main or front app's one.
    func openWheelWithoutDrag(at p: NSPoint, wheelID: String? = nil) {
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
        // Pages: the main wheel, your extra wheels, each app's wheel, then running apps. Start on the front app's own wheel.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appWheels = store.settings.appWheels.sorted { $0.value.name < $1.value.name }
        let extra = store.settings.wheels
        pages = [WheelPage(name: L("Main"), slots: store.settings.slots)]
            + extra.map { WheelPage(name: $0.name, slots: $0.slots) }
            + appWheels.map { WheelPage(name: $0.value.name, slots: $0.value.slots) }
            + [WheelPage(name: L("Running apps"), slots: nil)]
        if let wheelID, let i = extra.firstIndex(where: { $0.id == wheelID }) {
            pageIndex = i + 1
        } else {
            pageIndex = appWheels.firstIndex { $0.key == front }.map { $0 + 1 + extra.count } ?? 0
        }
        let slots = layoutPage(pageIndex)
        chip.close()
        wheel.show(at: p, slots: slots, summary: summary, mode: .click, shelfCount: shelf.items.count, page: pageLabel)
        if clickSource == .shelf { tray.show(items: shelf.items, below: wheel.frame) }
        escape.activate()
        wheelKeys.activate()
    }

    var pageLabel: WheelPageInfo? {
        pages.count > 1 ? WheelPageInfo(name: pages[pageIndex].name, index: pageIndex, count: pages.count) : nil
    }
    var clickSummary = ""

    func layoutPage(_ i: Int) -> [ResolvedSlot] {
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

    func wheelKey(_ k: WheelKeys.Key) {
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
    func fillSwitchers(_ slots: [ResolvedSlot], canDrop: Bool) -> [ResolvedSlot] {
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

    func updateEscape() {
        if wheel.isVisible || chip.isVisible || tray.isVisible || job != nil { escape.activate() } else { escape.deactivate() }
    }

    func escapePressed() {
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

    func globalMouseDown(_ p: NSPoint) {
        if wheel.isVisible && wheel.mode == .click && !NSMouseInRect(p, wheel.frame, false)
            && !(tray.isVisible && NSMouseInRect(p, tray.frame, false)) { closeWheel() }
        if chip.isVisible && job == nil && !NSMouseInRect(p, chip.frame, false) { chipClose() }
        if !wheel.isVisible { cachedLayout = nil }
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

}
