import AppKit
import Carbon.HIToolbox

/// System-wide hot keys through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission. Esc is registered only while the wheel or chip is up.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32? {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x5348_4B4E), id: id) // 'SHKN'
        let status = RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id else { return }
        if let r = refs[id] { UnregisterEventHotKey(r) }
        refs[id] = nil
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Holds Esc only while something of ours is on screen, so other apps keep their Esc.
final class EscapeKey {
    private var id: UInt32?
    var handler: (() -> Void)?

    var isActive: Bool { id != nil }

    func activate() {
        guard id == nil else { return }
        id = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.handler?() }
    }

    func deactivate() {
        HotKeyCenter.shared.unregister(id)
        id = nil
    }
}

/// Keys that drive a wheel opened without dragging. Registered only while it's open,
/// so the arrows and Return belong to other apps the rest of the time.
final class WheelKeys {
    enum Key {
        case left, right, up, down, enter, back, nextWheel, previousWheel, slot(Int)
        var isNext: Bool { if case .nextWheel = self { return true } else { return false } }
    }

    private var ids: [UInt32] = []
    var handler: ((Key) -> Void)?

    func activate() {
        guard ids.isEmpty else { return }
        let cmd = UInt32(cmdKey)
        var table: [(Int, UInt32, Key)] = [
            (kVK_LeftArrow, 0, .left), (kVK_RightArrow, 0, .right), (kVK_UpArrow, 0, .up), (kVK_DownArrow, 0, .down),
            (kVK_Return, 0, .enter), (kVK_ANSI_KeypadEnter, 0, .enter), (kVK_Space, 0, .enter),
            (kVK_Delete, 0, .back),
            (kVK_RightArrow, cmd, .nextWheel), (kVK_LeftArrow, cmd, .previousWheel),
            (kVK_Tab, 0, .nextWheel), (kVK_Tab, UInt32(shiftKey), .previousWheel),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        for (i, k) in digits.enumerated() { table.append((k, 0, .slot(i))) }
        for (code, mods, key) in table {
            if let id = HotKeyCenter.shared.register(keyCode: UInt32(code), modifiers: mods, handler: { [weak self] in self?.handler?(key) }) {
                ids.append(id)
            }
        }
    }

    func deactivate() {
        ids.forEach { HotKeyCenter.shared.unregister($0) }
        ids = []
    }
}
