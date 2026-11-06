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
