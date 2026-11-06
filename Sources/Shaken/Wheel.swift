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

/// Fades panels in, or shows them at once when Reduce Motion is on.
enum Motion {
    static func fadeIn(_ panel: NSPanel, duration: TimeInterval = 0.09) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 1
        }
    }
}

struct WheelPageInfo: Equatable { var name: String; var index: Int; var count: Int }

protocol WheelDelegate: AnyObject {
    func wheel(didDrop slot: ResolvedSlot, pasteboard: NSPasteboard, at point: NSPoint)
    func wheel(didDropOnShelf pasteboard: NSPasteboard, at point: NSPoint)
    func wheel(didClick slot: ResolvedSlot, at point: NSPoint)
    func wheelShouldClose()
    /// Two-finger swipe sideways on a trackpad or Magic Mouse: flip to the next or previous wheel.
    func wheelSwipe(next: Bool)
    /// The highlighted slot changed (nil = none), for window previews.
    func wheelHover(_ slot: ResolvedSlot?)
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
        // The glass is cut into the same tiles the view draws, so gaps show the desktop.
        effect.maskImage = NSImage(size: size, flipped: false) { r in
            let g = WheelGeometry(bounds: r)
            NSColor.black.setFill()
            g.centreDisc.fill()
            for i in 0..<g.count { g.sector(i).fill() }
            return true
        }
        view = WheelView(frame: effect.bounds)
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        panel.contentView = effect
        view.controller = self
    }

    func show(at point: NSPoint, slots: [ResolvedSlot], summary: String, mode: WheelMode, shelfCount: Int = 0, page: WheelPageInfo? = nil) {
        self.mode = mode
        view.configure(slots: slots, summary: summary, mode: mode, shelfCount: shelfCount)
        view.page = page
        var origin = NSPoint(x: point.x - Self.diameter / 2, y: point.y - Self.diameter / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX), f.maxX - Self.diameter)
            origin.y = min(max(origin.y, f.minY), f.maxY - Self.diameter)
        }
        panel.setFrameOrigin(origin)
        Motion.fadeIn(panel)
        openedAt = Date()
        NSAccessibility.post(element: view, notification: .layoutChanged)
        poll?.invalidate()
        if mode == .drag {
            // Other apps keep the mouse during a drag, so we check its state ourselves.
            poll = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    /// Swaps in another wheel without moving or re-animating the panel (⌘← / ⌘→).
    func replace(slots: [ResolvedSlot], summary: String, shelfCount: Int, page: WheelPageInfo?) {
        view.configure(slots: slots, summary: summary, mode: mode, shelfCount: shelfCount)
        view.page = page
        view.hovered = 0
    }

    func key(_ k: WheelKeys.Key) { view.handleKey(k) }

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

    fileprivate func droppedOnShelf(_ pb: NSPasteboard) {
        delegate?.wheel(didDropOnShelf: pb, at: NSEvent.mouseLocation)
    }

    fileprivate func clicked(_ slot: ResolvedSlot) {
        delegate?.wheel(didClick: slot, at: NSEvent.mouseLocation)
    }

    fileprivate func swiped(next: Bool) { delegate?.wheelSwipe(next: next) }

    fileprivate func hoverChanged(_ slot: ResolvedSlot?) { delegate?.wheelHover(slot) }

    fileprivate func exited() {
        if !inGrace { delegate?.wheelShouldClose() }
    }
}

/// Shared by the glass mask and the drawing: six tiles with even gaps around a centre disc.
struct WheelGeometry {
    let bounds: NSRect
    let count = ShakenSettings.slotCount
    let innerRadius: CGFloat = 50     // centre disc
    let ringGap: CGFloat = 5          // between disc and tiles
    let tileGap: CGFloat = 5          // between tiles

    var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    var outerRadius: CGFloat { min(bounds.width, bounds.height) / 2 - 3 }
    var ringInner: CGFloat { innerRadius + ringGap }
    var step: CGFloat { 360 / CGFloat(count) }
    /// Slot 0 is at the top; slots go clockwise.
    func midAngle(_ i: Int) -> CGFloat { 90 - CGFloat(i) * step }

    var centreDisc: NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
    }

    /// A tile whose sides are parallel, so the gap is the same width all the way out.
    func sector(_ i: Int) -> NSBezierPath {
        let mid = midAngle(i)
        func half(_ r: CGFloat) -> CGFloat { asin(min(1, tileGap / 2 / r)) * 180 / .pi }
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: outerRadius, startAngle: mid - step / 2 + half(outerRadius), endAngle: mid + step / 2 - half(outerRadius))
        p.appendArc(withCenter: center, radius: ringInner, startAngle: mid + step / 2 - half(ringInner), endAngle: mid - step / 2 + half(ringInner), clockwise: true)
        p.close()
        return p
    }

    /// -1 = centre, nil = outside.
    func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        if d < innerRadius + ringGap / 2 { return -1 }
        if d > outerRadius + 2 { return nil }
        var deg = (90 - atan2(dy, dx) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return Int((deg + step / 2) / step) % count
    }
}

final class WheelView: NSView {
    weak var controller: WheelController?

    private var top: [ResolvedSlot] = []
    private var submenu: ResolvedSlot? { didSet { submenuChanged = true } }
    private var summary = ""
    private var shelfCount = 0
    private var mode: WheelMode = .drag
    var hovered: Int? {                // -1 = centre (internal for snapshots)
        didSet { if oldValue != hovered || submenuChanged { submenuChanged = false; controller?.hoverChanged(slot(hovered)) } }
    }
    private var submenuChanged = false
    /// Which wheel this is when there's more than one to flip through with ⌘← / ⌘→.
    var page: WheelPageInfo? { didSet { needsDisplay = true } }
    private var dwellIndex: Int?
    private var dwellStart = Date()

    private var ring: [ResolvedSlot] { submenu?.children ?? top }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DragReader.acceptedTypes)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(slots: [ResolvedSlot], summary: String, mode: WheelMode, shelfCount: Int) {
        top = slots
        self.summary = summary
        self.shelfCount = shelfCount
        self.mode = mode
        submenu = nil
        hovered = nil
        needsDisplay = true
    }

    func reset() { submenu = nil; hovered = nil; dwellIndex = nil }

    // MARK: geometry

    private var geo: WheelGeometry { WheelGeometry(bounds: bounds) }
    private func index(at p: NSPoint) -> Int? { geo.index(at: p) }

    private func slot(_ i: Int?) -> ResolvedSlot? {
        guard let i, i >= 0, i < ring.count else { return nil }
        return ring[i]
    }

    // MARK: drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private var tileFill: NSColor { NSColor.labelColor.withAlphaComponent(highContrast ? 0.14 : (isDark ? 0.07 : 0.05)) }
    private var rim: NSColor {
        if highContrast { return NSColor.labelColor.withAlphaComponent(0.6) }
        return isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = geo
        for i in 0..<g.count {
            let path = g.sector(i)
            let s = slot(i)
            let hot = hovered == i && s?.enabled == true
            (hot ? NSColor.controlAccentColor : tileFill).setFill()
            path.fill()
            rim.setStroke()
            path.lineWidth = 1
            path.stroke()
            if let s { drawSlot(s, angle: g.midAngle(i), highlighted: hot) }
        }

        let disc = g.centreDisc
        let centreActive = hovered == -1 && (submenu != nil || mode == .drag)
        (centreActive ? NSColor.controlAccentColor : tileFill).setFill()
        disc.fill()
        rim.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let c = g.center, r = g.innerRadius
        if let page, submenu == nil, mode == .click { drawPage(page, centre: c) }
        let fg: NSColor = centreActive ? .white : .labelColor
        let sub: NSColor = centreActive ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
        if let parent = submenu {
            drawSymbol("chevron.backward", size: 13, weight: .semibold, color: fg, at: NSPoint(x: c.x, y: c.y + 11))
            drawText(parent.title, in: NSRect(x: c.x - r + 10, y: c.y - 20, width: r * 2 - 20, height: 26),
                     font: .systemFont(ofSize: 10, weight: .medium), color: sub, lines: 2)
        } else if mode == .drag {
            // Dropping in the middle parks the items on the shelf.
            drawSymbol("tray.and.arrow.down.fill", size: 17, weight: .regular, color: centreActive ? .white : .controlAccentColor,
                       at: NSPoint(x: c.x, y: c.y + 12))
            drawText(centreActive ? L("Put on shelf") : summary, in: NSRect(x: c.x - r + 10, y: c.y - 24, width: r * 2 - 20, height: 28),
                     font: .systemFont(ofSize: 10, weight: centreActive ? .semibold : .medium), color: centreActive ? .white : sub, lines: 2)
        } else if shelfCount > 0 {
            let lift: CGFloat = page != nil ? 6 : 0
            drawSymbol("tray.full.fill", size: 17, weight: .regular, color: .controlAccentColor, at: NSPoint(x: c.x, y: c.y + 12 + lift))
            drawText(L("Shelf · %@", String(shelfCount)), in: NSRect(x: c.x - r + 10, y: c.y - 20 + lift, width: r * 2 - 20, height: 20),
                     font: .systemFont(ofSize: 10.5, weight: .semibold), color: .labelColor, lines: 1)
        } else {
            // Leave room at the bottom for the page name and dots.
            let hasPage = page != nil
            drawText(summary, in: NSRect(x: c.x - r + 10, y: hasPage ? c.y - 10 : c.y - 20, width: r * 2 - 20, height: hasPage ? 30 : 40),
                     font: .systemFont(ofSize: 10, weight: .medium), color: sub, lines: hasPage ? 2 : 3)
        }
    }

    /// Inside the disc, at the bottom: the wheel's name and one dot per wheel.
    private func drawPage(_ page: WheelPageInfo, centre c: NSPoint) {
        let r = geo.innerRadius
        drawText(page.name, in: NSRect(x: c.x - r + 10, y: c.y - r + 15, width: r * 2 - 20, height: 12),
                 font: .systemFont(ofSize: 9, weight: .semibold), color: .secondaryLabelColor, lines: 1)
        let dot: CGFloat = 4.5, gap: CGFloat = 4
        let shown = min(page.count, 9)
        let width = CGFloat(shown) * dot + CGFloat(shown - 1) * gap
        var x = c.x - width / 2
        let y = c.y - r + 8
        for i in 0..<shown {
            let current = i == min(page.index, shown - 1)
            (current ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            x += dot + gap
        }
    }

    private func drawSlot(_ s: ResolvedSlot, angle: CGFloat, highlighted: Bool) {
        guard s.kind != .empty else { return }
        let g = geo
        let r = (g.ringInner + g.outerRadius) / 2
        let rad = angle * .pi / 180
        let p = NSPoint(x: g.center.x + cos(rad) * r, y: g.center.y + sin(rad) * r)
        let color: NSColor = !s.enabled ? .tertiaryLabelColor : (highlighted ? .white : .labelColor)
        let iconColor: NSColor = !s.enabled ? .tertiaryLabelColor : (highlighted ? .white : .controlAccentColor)
        // Icon, title (1–2 lines) and note stacked as one block centred on the tile.
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let titleH = textHeight(s.title, font: titleFont, width: 96, lines: 2)
        let iconH: CGFloat = 24, gap: CGFloat = 5, noteH: CGFloat = s.note == nil ? 0 : 14
        let extraH: CGFloat = s.kind.opensRing ? 12 : 0
        let total = iconH + gap + titleH + noteH + extraH
        var y = p.y + total / 2
        drawSymbol(s.icon.isEmpty ? "bolt.fill" : s.icon, size: 21, weight: .medium, color: iconColor, at: NSPoint(x: p.x, y: y - iconH / 2))
        y -= iconH + gap
        drawText(s.title, in: NSRect(x: p.x - 48, y: y - titleH, width: 96, height: titleH), font: titleFont, color: color, lines: 2)
        y -= titleH
        if let note = s.note {
            drawText(note, in: NSRect(x: p.x - 48, y: y - noteH, width: 96, height: noteH),
                     font: .systemFont(ofSize: 9, weight: .medium), color: highlighted ? .white : .systemOrange, lines: 1)
            y -= noteH
        }
        if s.kind.opensRing {
            drawSymbol("ellipsis", size: 10, weight: .bold, color: color.withAlphaComponent(0.6), at: NSPoint(x: p.x, y: y - extraH / 2))
        }
    }

    private func textHeight(_ s: String, font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 0.95
        let r = NSAttributedString(string: s, attributes: [.font: font, .paragraphStyle: para])
            .boundingRect(with: NSSize(width: width, height: CGFloat(lines) * font.pointSize * 1.3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return ceil(r.height) + 1
    }

    private func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint) {
        // A path means "use this app's or file's own icon".
        if name.hasPrefix("/") {
            let side = size * 1.45
            let img = NSWorkspace.shared.icon(forFile: name)
            img.draw(in: NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side), from: .zero, operation: .sourceOver,
                     fraction: color == .tertiaryLabelColor ? 0.4 : 1)
            return
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        let img = base.withSymbolConfiguration(cfg) ?? base
        let sz = img.size
        img.draw(in: NSRect(x: p.x - sz.width / 2, y: p.y - sz.height / 2, width: sz.width, height: sz.height))
    }

    private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, lines: Int) {
        guard !s.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping   // truncatesLastVisibleLine adds the ellipsis
        para.lineHeightMultiple = 0.95
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
        if submenu == nil, let s = slot(i), s.kind.opensRing, s.enabled {
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
        if i == -1 { return submenu == nil ? .copy : [] }
        guard let s = slot(i), s.enabled, !s.kind.opensRing else { return [] }
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
        let i = index(at: convert(sender.draggingLocation, from: nil))
        if i == -1 { return submenu == nil }
        guard let s = slot(i) else { return false }
        return s.enabled && !s.kind.opensRing
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let i = index(at: convert(sender.draggingLocation, from: nil))
        if i == -1 {
            guard submenu == nil else { return false }
            controller?.droppedOnShelf(sender.draggingPasteboard)
            return true
        }
        guard let s = slot(i), s.enabled, !s.kind.opensRing else { return false }
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
        activate(index(at: convert(event.locationInWindow, from: nil)))
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { submenu?.title ?? L("Shaken wheel") }

    /// One element per slot, in slot order, so VoiceOver can read and press them.
    override func accessibilityChildren() -> [Any]? {
        guard let window else { return nil }
        let g = geo
        return ring.enumerated().compactMap { i, s -> NSAccessibilityElement? in
            guard s.kind != .empty else { return nil }
            let e = WheelSlotElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            var label = s.title
            if s.kind.opensRing { label += ", " + L("submenu") }
            if let note = s.note { label += ", " + note }
            e.setAccessibilityLabel(label)
            e.setAccessibilityEnabled(s.enabled)
            e.setAccessibilityHelp(L("Slot %@", String(i + 1)))
            let local = g.sector(i).bounds
            e.setAccessibilityFrame(window.convertToScreen(convert(local, to: nil)))
            e.onPress = { [weak self] in self?.activate(i) }
            return e
        }
    }

    // MARK: swipe (click mode)

    private var swipeX: CGFloat = 0
    private var swipeDone = false

    /// One page per gesture: a sideways two-finger swipe past a small distance flips once,
    /// and momentum after lifting the fingers is ignored.
    override func scrollWheel(with event: NSEvent) {
        guard mode == .click, submenu == nil else { return super.scrollWheel(with: event) }
        if event.momentumPhase != [] { return }
        if event.phase == .began || event.phase == .mayBegin { swipeX = 0; swipeDone = false }
        if event.phase == .ended || event.phase == .cancelled { swipeX = 0; swipeDone = false; return }
        guard event.hasPreciseScrollingDeltas else {
            // A plain mouse wheel: each notch with horizontal movement flips once.
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 {
                controller?.swiped(next: event.scrollingDeltaX < 0)
            }
            return
        }
        // Only count gestures that are mostly sideways.
        guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return }
        swipeX += event.scrollingDeltaX
        if !swipeDone && abs(swipeX) > 30 {
            swipeDone = true
            controller?.swiped(next: swipeX < 0)
        }
    }

    // MARK: keyboard (click mode)

    func handleKey(_ k: WheelKeys.Key) {
        guard mode == .click else { return }
        let n = ring.count
        guard n > 0 else { return }
        func step(_ d: Int) {
            let cur = hovered ?? -1
            hovered = cur < 0 ? (d > 0 ? 0 : n - 1) : (cur + d + n) % n
            needsDisplay = true
        }
        switch k {
        case .right, .down: step(1)
        case .left, .up: step(-1)
        case .enter: activate(hovered ?? -1)
        case .back:
            if submenu != nil { submenu = nil; hovered = 0; needsDisplay = true }
        case .slot(let i): if i < n { hovered = i; needsDisplay = true; activate(i) }
        case .nextWheel, .previousWheel: break   // handled by the app
        }
    }

    fileprivate func activate(_ i: Int?) {
        if i == -1 {
            if submenu != nil { submenu = nil; hovered = nil; needsDisplay = true } else { controller?.delegate?.wheelShouldClose() }
            return
        }
        guard let s = slot(i), s.enabled else { return }
        if s.kind.opensRing { submenu = s; hovered = 0; needsDisplay = true; return }
        controller?.clicked(s)
    }
}

/// A wheel slot as VoiceOver sees it.
private final class WheelSlotElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
