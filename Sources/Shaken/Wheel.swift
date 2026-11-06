import AppKit
import ShakenCore

/// A borderless panel that never activates Shaken, so the app being dragged
/// from keeps focus and the drag carries on normally when the wheel closes.
class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum WheelMode { case drag, click }

protocol WheelDelegate: AnyObject {
    func wheel(didDrop slot: ResolvedSlot, pasteboard: NSPasteboard, at point: NSPoint)
    func wheel(didClick slot: ResolvedSlot, at point: NSPoint)
    func wheelShouldClose()
}

final class WheelController {
    static let diameter: CGFloat = 340

    weak var delegate: WheelDelegate?
    private let panel = FloatingPanel(size: NSSize(width: diameter, height: diameter))
    private let view: WheelView
    private var poll: Timer?
    private(set) var mode: WheelMode = .drag
    private var openedAt = Date.distantPast

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        let size = NSSize(width: Self.diameter, height: Self.diameter)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = NSImage(size: size, flipped: false) { r in
            NSBezierPath(ovalIn: r).fill(); return true
        }
        view = WheelView(frame: effect.bounds)
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        panel.contentView = effect
        view.controller = self
    }

    func show(at point: NSPoint, slots: [ResolvedSlot], summary: String, mode: WheelMode) {
        self.mode = mode
        view.configure(slots: slots, summary: summary, mode: mode)
        var origin = NSPoint(x: point.x - Self.diameter / 2, y: point.y - Self.diameter / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX), f.maxX - Self.diameter)
            origin.y = min(max(origin.y, f.minY), f.maxY - Self.diameter)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        openedAt = Date()
        poll?.invalidate()
        if mode == .drag {
            // Other apps keep the mouse during a drag, so we check its state ourselves.
            poll = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func close() {
        poll?.invalidate()
        poll = nil
        panel.orderOut(nil)
        view.reset()
    }

    /// Short grace period: the pointer is still moving from the shake when the wheel appears.
    var inGrace: Bool { Date().timeIntervalSince(openedAt) < 0.35 }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            // Dropped somewhere. Give performDragOperation a moment to run first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if self?.isVisible == true { self?.delegate?.wheelShouldClose() }
            }
            poll?.invalidate()
            return
        }
        if !inGrace && pointerOutside() { delegate?.wheelShouldClose() }
    }

    func pointerOutside() -> Bool {
        let p = NSEvent.mouseLocation
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return hypot(p.x - c.x, p.y - c.y) > Self.diameter / 2 + 2
    }

    fileprivate func dropped(_ slot: ResolvedSlot, _ pb: NSPasteboard) {
        delegate?.wheel(didDrop: slot, pasteboard: pb, at: NSEvent.mouseLocation)
    }

    fileprivate func clicked(_ slot: ResolvedSlot) {
        delegate?.wheel(didClick: slot, at: NSEvent.mouseLocation)
    }

    fileprivate func exited() {
        if !inGrace { delegate?.wheelShouldClose() }
    }
}

final class WheelView: NSView {
    weak var controller: WheelController?

    private var top: [ResolvedSlot] = []
    private var submenu: ResolvedSlot?
    private var summary = ""
    private var mode: WheelMode = .drag
    private var hovered: Int?          // -1 = centre
    private var dwellIndex: Int?
    private var dwellStart = Date()

    private let innerRadius: CGFloat = 52
    private var ring: [ResolvedSlot] { submenu?.children ?? top }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DragReader.acceptedTypes)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(slots: [ResolvedSlot], summary: String, mode: WheelMode) {
        top = slots
        self.summary = summary
        self.mode = mode
        submenu = nil
        hovered = nil
        needsDisplay = true
    }

    func reset() { submenu = nil; hovered = nil; dwellIndex = nil }

    // MARK: geometry

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var outerRadius: CGFloat { min(bounds.width, bounds.height) / 2 - 2 }
    private let count = ShakenSettings.slotCount

    /// Slot 0 is at the top; slots go clockwise.
    private func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        if d < innerRadius { return -1 }
        if d > outerRadius { return nil }
        var deg = 90 - atan2(dy, dx) * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        let step = 360 / CGFloat(count)
        return Int((deg + step / 2) / step) % count
    }

    private func slot(_ i: Int?) -> ResolvedSlot? {
        guard let i, i >= 0, i < ring.count else { return nil }
        return ring[i]
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = center
        let step = 360 / CGFloat(count)

        NSColor.windowBackgroundColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()

        for i in 0..<count {
            let mid = 90 - CGFloat(i) * step
            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: outerRadius, startAngle: mid - step / 2, endAngle: mid + step / 2)
            path.appendArc(withCenter: c, radius: innerRadius, startAngle: mid + step / 2, endAngle: mid - step / 2, clockwise: true)
            path.close()
            let s = slot(i)
            if hovered == i, s?.enabled == true {
                NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
                path.fill()
            }
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            if let s { drawSlot(s, angle: mid, highlighted: hovered == i) }
        }

        // Centre: what's being dragged, or "back" inside a submenu.
        let hole = NSBezierPath(ovalIn: NSRect(x: c.x - innerRadius, y: c.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
        (hovered == -1 && submenu != nil ? NSColor.controlAccentColor.withAlphaComponent(0.4) : NSColor.windowBackgroundColor.withAlphaComponent(0.6)).setFill()
        hole.fill()
        let centreText = submenu != nil ? "‹ " + L("Back") : summary
        drawText(centreText, in: NSRect(x: c.x - innerRadius + 6, y: c.y - 18, width: innerRadius * 2 - 12, height: 36),
                 font: .systemFont(ofSize: 10, weight: .medium), color: .labelColor, lines: 3)
    }

    private func drawSlot(_ s: ResolvedSlot, angle: CGFloat, highlighted: Bool) {
        let r = (innerRadius + outerRadius) / 2
        let rad = angle * .pi / 180
        let p = NSPoint(x: center.x + cos(rad) * r, y: center.y + sin(rad) * r)
        let color: NSColor = !s.enabled ? .tertiaryLabelColor : (highlighted ? .white : .labelColor)
        if s.kind != .empty, let img = NSImage(systemSymbolName: s.icon.isEmpty ? "circle" : s.icon, accessibilityDescription: s.title)
            ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular).applying(.init(paletteColors: [color]))
            let icon = img.withSymbolConfiguration(cfg) ?? img
            let sz = icon.size
            icon.draw(in: NSRect(x: p.x - sz.width / 2, y: p.y + 2, width: sz.width, height: sz.height))
        }
        let title = s.kind == .empty ? "" : s.title
        drawText(title, in: NSRect(x: p.x - 46, y: p.y - 26, width: 92, height: 26), font: .systemFont(ofSize: 10.5), color: color, lines: 2)
        if let note = s.note {
            drawText(note, in: NSRect(x: p.x - 46, y: p.y - 40, width: 92, height: 13), font: .systemFont(ofSize: 8.5), color: .systemOrange, lines: 1)
        }
        if s.kind == .submenu {
            drawText("•••", in: NSRect(x: p.x - 20, y: p.y - 38, width: 40, height: 12), font: .systemFont(ofSize: 8), color: color, lines: 1)
        }
    }

    private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, lines: Int) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let h = min(str.boundingRect(with: NSSize(width: rect.width, height: CGFloat(lines) * font.pointSize * 1.3), options: opts).height, rect.height)
        str.draw(with: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h), options: opts)
    }

    // MARK: hover + submenus

    private func hover(_ i: Int?) {
        if i != hovered { hovered = i; needsDisplay = true }
        if i != dwellIndex { dwellIndex = i; dwellStart = Date(); return }
        // Dwell to open a submenu during a drag (you can't click while dragging).
        guard mode == .drag, Date().timeIntervalSince(dwellStart) > 0.45 else { return }
        if submenu == nil, let s = slot(i), s.kind == .submenu, s.enabled {
            submenu = s; hovered = nil; dwellIndex = nil; needsDisplay = true
        } else if submenu != nil, i == -1 {
            submenu = nil; hovered = nil; dwellIndex = nil; needsDisplay = true
        }
    }

    // MARK: dragging destination

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let i = index(at: p)
        hover(i)
        if i == nil, !(controller?.inGrace ?? false) { DispatchQueue.main.async { self.controller?.exited() } }
        guard let s = slot(i), s.enabled, s.kind != .submenu else { return [] }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hover(nil)
        controller?.exited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = slot(index(at: convert(sender.draggingLocation, from: nil))) else { return false }
        return s.enabled && s.kind != .submenu
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = slot(index(at: convert(sender.draggingLocation, from: nil))), s.enabled, s.kind != .submenu else { return false }
        controller?.dropped(s, sender.draggingPasteboard)
        return true
    }

    // MARK: click mode

    override func mouseMoved(with event: NSEvent) {
        guard mode == .click else { return }
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if mode == .click { hovered = nil; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .click else { return }
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i == -1 {
            if submenu != nil { submenu = nil; hovered = nil; needsDisplay = true } else { controller?.delegate?.wheelShouldClose() }
            return
        }
        guard let s = slot(i), s.enabled else { return }
        if s.kind == .submenu { submenu = s; hovered = nil; needsDisplay = true; return }
        controller?.clicked(s)
    }
}
