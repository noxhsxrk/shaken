import AppKit
import ShakenCore

/// Watches the mouse with global monitors only (no Accessibility permission).
/// A shake during a drag opens the wheel only when the drag pasteboard changed
/// since mouse-down — i.e. something is being dragged, not a window or a selection.
final class DragMonitor {
    var onShake: ((NSPoint) -> Void)?
    var onEmptyShake: ((NSPoint) -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    var isPaused = false
    let recorder = TraceRecorder()

    var settings: ShakenSettings {
        didSet {
            dragDetector.config = .sensitivity(settings.gesture.sensitivity)
            moveDetector.config = .sensitivity(settings.gesture.sensitivity)
        }
    }

    private var monitors: [Any] = []
    private var dragDetector: ShakeDetector
    private var moveDetector: ShakeDetector
    private var startChangeCount = 0
    private var ignoreThisDrag = false

    init(settings: ShakenSettings) {
        self.settings = settings
        dragDetector = ShakeDetector(config: .sensitivity(settings.gesture.sensitivity))
        moveDetector = ShakeDetector(config: .sensitivity(settings.gesture.sensitivity))
    }

    func start() {
        stop()
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] e in self?.dragged(e) }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
        add(.mouseMoved) { [weak self] e in self?.moved(e) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
    }

    /// Drags that start in Shaken's own windows (the chip, the shelf tray) never reach the
    /// global monitors, so their dragging sessions report positions here instead.
    func ownDragBegan() {
        dragDetector.reset()
    }

    func ownDragMoved(to p: NSPoint) {
        guard !isPaused, modifierSatisfied() else { return }
        if dragDetector.add(t: ProcessInfo.processInfo.systemUptime, x: p.x, y: p.y) { onShake?(p) }
    }

    private func mouseDown() {
        let p = NSEvent.mouseLocation
        startChangeCount = NSPasteboard(name: .drag).changeCount
        dragDetector.reset()
        ignoreThisDrag = isPaused || isExcluded(appUnder: p)
        recorder.begin()
        onMouseDown?(p)
    }

    private func mouseUp() {
        dragDetector.reset()
        recorder.end()
        onMouseUp?()
    }

    private func dragged(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        recorder.add(t: e.timestamp, p: p)
        guard !ignoreThisDrag, modifierSatisfied() else { return }
        guard dragDetector.add(t: e.timestamp, x: p.x, y: p.y) else { return }
        guard NSPasteboard(name: .drag).changeCount != startChangeCount else { return }
        onShake?(p)
    }

    private func moved(_ e: NSEvent) {
        // Cheap early exit: this fires for every mouse move on the system.
        guard settings.gesture.optionShakeWithoutDrag, !isPaused,
              NSEvent.modifierFlags.contains(.option), NSEvent.pressedMouseButtons == 0 else { return }
        let p = NSEvent.mouseLocation
        if moveDetector.add(t: e.timestamp, x: p.x, y: p.y) { onEmptyShake?(p) }
    }

    private func modifierSatisfied() -> Bool {
        let f = NSEvent.modifierFlags
        switch settings.gesture.modifier {
        case .none: return true
        case .option: return f.contains(.option)
        case .shift: return f.contains(.shift)
        case .control: return f.contains(.control)
        case .command: return f.contains(.command)
        }
    }

    /// Finds the app owning the window under the pointer (the drag source).
    private func isExcluded(appUnder p: NSPoint) -> Bool {
        guard !settings.excludedApps.isEmpty else { return false }
        let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        var pid: pid_t?
        if n > 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(n)) as? [[String: Any]] {
            pid = info.first?[kCGWindowOwnerPID as String] as? pid_t
        }
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        guard let id = app?.bundleIdentifier else { return false }
        return settings.excludedApps.contains(id)
    }
}

/// Records pointer paths of real drags so they can be added to the test fixtures.
final class TraceRecorder {
    enum Mode: String { case off, mouseShake, trackpadShake, mouseDrag, trackpadDrag }
    var mode: Mode = .off
    private var samples: [[Double]] = []
    private var t0: TimeInterval?

    func begin() { samples = []; t0 = nil }

    func add(t: TimeInterval, p: NSPoint) {
        guard mode != .off else { return }
        if t0 == nil { t0 = t }
        samples.append([t - (t0 ?? t), Double(p.x), Double(p.y)])
    }

    func end() {
        guard mode != .off, samples.count >= 10 else { return }
        let device = (mode == .mouseShake || mode == .mouseDrag) ? "mouse" : "trackpad"
        let trace = GestureTrace(device: device, note: "recorded \(Date())",
                                 expectShake: mode == .mouseShake || mode == .trackpadShake, samples: samples)
        try? FileManager.default.createDirectory(at: ShakenPaths.traces, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = ShakenPaths.traces.appendingPathComponent("real-\(mode.rawValue)-\(stamp).json")
        if let data = try? JSONEncoder().encode(trace) { try? data.write(to: url) }
        samples = []
    }
}
