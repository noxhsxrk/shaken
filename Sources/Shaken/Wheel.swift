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
    static let diameter: CGFloat = 360

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
            let f = screen.visibleFrame.insetBy(dx: 6, dy: 6)
            // Keep a compact shelf beneath the wheel when the display has room.
            let shelfSpace: CGFloat = mode == .click && shelfCount > 0 && f.height >= Self.diameter + 92 ? 86 : 0
            origin.x = min(max(origin.x, f.minX), f.maxX - Self.diameter)
            origin.y = min(max(origin.y, f.minY + shelfSpace), f.maxY - Self.diameter)
        }
        panel.setFrameOrigin(origin)
        restOrigin = origin
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
    // MARK: sliding between wheels

    /// Where the panel sits when it isn't being dragged sideways.
    private var restOrigin = NSPoint.zero
    private var sliding = false
    static let slideDistance: CGFloat = 80

    /// Follows the fingers during a two-finger swipe, with some resistance.
    func follow(_ dx: CGFloat) {
        guard !sliding, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let limit = Self.slideDistance * 1.4
        let x = limit * tanh(dx / limit)   // eases off as it goes further
        panel.setFrameOrigin(NSPoint(x: restOrigin.x + x, y: restOrigin.y))
        panel.alphaValue = 1 - min(abs(x) / (limit * 2.2), 0.45)
    }

    /// The swipe wasn't far enough: spring back into place.
    func settle() {
        guard !sliding else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.1)
            panel.animator().setFrameOrigin(restOrigin)
            panel.animator().alphaValue = 1
        }
    }

    /// Slides the current wheel out and the next one in. `direction` 1 = next (moves left), -1 = previous.
    func slide(direction: Int, swap: @escaping () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !panel.isVisible {
            swap()
            panel.setFrameOrigin(restOrigin)
            panel.alphaValue = 1
            return
        }
        sliding = true
        let d = CGFloat(direction) * Self.slideDistance
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(NSPoint(x: restOrigin.x - d, y: restOrigin.y))
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            swap()
            self.panel.setFrameOrigin(NSPoint(x: self.restOrigin.x + d, y: self.restOrigin.y))
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
                self.panel.animator().setFrameOrigin(self.restOrigin)
                self.panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.sliding = false })
        })
    }

    func replace(slots: [ResolvedSlot], summary: String, shelfCount: Int, page: WheelPageInfo?) {
        view.configure(slots: slots, summary: summary, mode: mode, shelfCount: shelfCount)
        view.page = page
        view.hovered = 0
    }

    func key(_ k: WheelKeys.Key) { view.handleKey(k) }

    func close() {
        sliding = false
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
    fileprivate func swipeFollow(_ dx: CGFloat) { follow(dx) }
    fileprivate func swipeCancelled() { settle() }

    fileprivate func hoverChanged(_ slot: ResolvedSlot?) { delegate?.wheelHover(slot) }

    fileprivate func exited() {
        if !inGrace { delegate?.wheelShouldClose() }
    }
}

/// Shared by the glass mask and the drawing: six tiles with even gaps around a centre disc.
/// The Shaken asset kit's wheel, scaled from its 420 pt canvas:
/// outer radius 202, ring inner radius 72, centre button 67, slots 57.6° wide with 2.4° gaps.
struct WheelGeometry {
    let bounds: NSRect
    let count = ShakenSettings.slotCount
    static let gapDegrees: CGFloat = 2.4

    var scale: CGFloat { min(bounds.width, bounds.height) / 420 }
    var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    var outerRadius: CGFloat { 202 * scale }
    var ringInner: CGFloat { 72 * scale }
    /// The centre button.
    var innerRadius: CGFloat { 67 * scale }
    var step: CGFloat { 360 / CGFloat(count) }
    /// Slot 0 is at the top; slots go clockwise.
    func midAngle(_ i: Int) -> CGFloat { 90 - CGFloat(i) * step }

    var centreDisc: NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
    }

    func sector(_ i: Int) -> NSBezierPath {
        let mid = midAngle(i)
        let half = (step - Self.gapDegrees) / 2
        // Sample the two circular boundaries and soften only their four junctions.
        // These are real rounded corners; lineJoinStyle alone does not round a fill.
        let samples = 48
        func point(_ radius: CGFloat, _ angle: CGFloat) -> NSPoint {
            let radians = angle * .pi / 180
            return NSPoint(x: center.x + cos(radians) * radius,
                           y: center.y + sin(radians) * radius)
        }
        var points: [NSPoint] = []
        for n in 0...samples {
            points.append(point(outerRadius, mid + half - CGFloat(n) * 2 * half / CGFloat(samples)))
        }
        for n in 0...samples {
            points.append(point(ringInner, mid - half + CGFloat(n) * 2 * half / CGFloat(samples)))
        }
        let corners: Set<Int> = [0, samples, samples + 1, points.count - 1]
        // Skip arc samples near the corner, leaving enough tangent length for a soft fillet.
        let trim = 4
        let kept = points.indices.filter { i in
            if corners.contains(i) { return true }
            return !corners.contains { abs($0 - i) <= trim }
        }
        let vertices = kept.map { points[$0] }
        let path = NSBezierPath()
        for j in vertices.indices {
            let vertex = vertices[j]
            let previous = vertices[(j + vertices.count - 1) % vertices.count]
            let next = vertices[(j + 1) % vertices.count]
            func toward(_ target: NSPoint, distance: CGFloat) -> NSPoint {
                let length = hypot(target.x - vertex.x, target.y - vertex.y)
                let fraction = min(distance / max(length, 0.001), 0.48)
                return NSPoint(x: vertex.x + (target.x - vertex.x) * fraction,
                               y: vertex.y + (target.y - vertex.y) * fraction)
            }
            let distance: CGFloat = corners.contains(kept[j]) ? 11 * scale : 0
            let entry = toward(previous, distance: distance)
            let exit = toward(next, distance: distance)
            if j == 0 { path.move(to: entry) } else { path.line(to: entry) }
            if distance > 0 {
                // Quadratic corner expressed as a cubic with matching tangents.
                let c1 = NSPoint(x: entry.x + (vertex.x - entry.x) * 2 / 3,
                                 y: entry.y + (vertex.y - entry.y) * 2 / 3)
                let c2 = NSPoint(x: exit.x + (vertex.x - exit.x) * 2 / 3,
                                 y: exit.y + (vertex.y - exit.y) * 2 / 3)
                path.curve(to: exit, controlPoint1: c1, controlPoint2: c2)
            }
        }
        path.close()
        return path
    }

    /// -1 = centre, nil = outside.
    func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        if d < (innerRadius + ringInner) / 2 { return -1 }
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
    private var ink: NSColor { Brand.text(dark: isDark) }
    private var inkMuted: NSColor { ink.withAlphaComponent(0.6) }

    override func draw(_ dirtyRect: NSRect) {
        let g = geo
        for i in 0..<g.count {
            let path = g.sector(i)
            let s = slot(i)
            let hot = hovered == i && s?.enabled == true
            Brand.drawGlass(path, dark: isDark, selected: hot)
            if let s { drawSlot(s, index: i, angle: g.midAngle(i), highlighted: hot) }
        }

        let disc = g.centreDisc
        let centreActive = hovered == -1 && (submenu != nil || mode == .drag)
        Brand.drawGlass(disc, dark: isDark, selected: centreActive)

        let c = g.center, r = g.innerRadius
        if let page, submenu == nil, mode == .click { drawPage(page, centre: c) }
        let fg: NSColor = centreActive ? .white : ink
        let sub: NSColor = centreActive ? .white.withAlphaComponent(0.85) : inkMuted
        if let parent = submenu {
            drawSymbol("chevron.backward", size: 14, weight: .semibold, color: fg, at: NSPoint(x: c.x, y: c.y + 12))
            drawText(parent.title, in: NSRect(x: c.x - r + 10, y: c.y - 20, width: r * 2 - 20, height: 26),
                     font: .systemFont(ofSize: 10, weight: .medium), color: sub, lines: 2)
        } else if mode == .drag {
            // What's being dragged, and that dropping in the middle parks it on the shelf.
            drawSymbol(centreActive ? "glyph:Shelf" : "glyph:Stack", size: 18, weight: .regular, color: fg, at: NSPoint(x: c.x, y: c.y + 18))
            drawText(centreActive ? L("Put on shelf") : summary, in: NSRect(x: c.x - r + 10, y: c.y - 6, width: r * 2 - 20, height: 16),
                     font: .systemFont(ofSize: 12, weight: .semibold), color: fg, lines: 1)
            drawText(L("Drop to shelf"), in: NSRect(x: c.x - r + 10, y: c.y - 24, width: r * 2 - 20, height: 14),
                     font: .systemFont(ofSize: 9.5), color: sub, lines: 1)
        } else if shelfCount > 0 {
            let lift: CGFloat = page != nil ? 6 : 0
            drawSymbol("glyph:Shelf", size: 18, weight: .regular, color: ink, at: NSPoint(x: c.x, y: c.y + 12 + lift))
            drawText(L("Shelf · %@", String(shelfCount)), in: NSRect(x: c.x - r + 10, y: c.y - 20 + lift, width: r * 2 - 20, height: 20),
                     font: .systemFont(ofSize: 11.5, weight: .semibold), color: ink, lines: 1)
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
                 font: .systemFont(ofSize: 9, weight: .semibold), color: inkMuted, lines: 1)
        let dot: CGFloat = 4.5, gap: CGFloat = 4
        let shown = min(page.count, 9)
        let width = CGFloat(shown) * dot + CGFloat(shown - 1) * gap
        var x = c.x - width / 2
        let y = c.y - r + 8
        for i in 0..<shown {
            let current = i == min(page.index, shown - 1)
            (current ? Brand.accent : inkMuted.withAlphaComponent(0.35)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            x += dot + gap
        }
    }

    private func drawSlot(_ s: ResolvedSlot, index: Int, angle: CGFloat, highlighted: Bool) {
        guard s.kind != .empty else { return }
        let g = geo
        let r = 141 * g.scale   // label centre radius from the kit
        let rad = angle * .pi / 180
        let p = NSPoint(x: g.center.x + cos(rad) * r, y: g.center.y + sin(rad) * r)
        let color: NSColor = !s.enabled ? ink.withAlphaComponent(0.35) : (highlighted ? .white : ink)
        let iconColor = color
        // Icon, title (1–2 lines) and note stacked as one block centred on the tile.
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleWidth: CGFloat = 112
        let titleH = textHeight(s.title, font: titleFont, width: titleWidth, lines: 2)
        let iconH: CGFloat = 24, gap: CGFloat = 5, noteH: CGFloat = s.note == nil ? 0 : 14
        let extraH: CGFloat = s.kind.opensRing ? 12 : 0
        let total = iconH + gap + titleH + noteH + extraH
        var y = p.y + total / 2
        drawSymbol(s.icon.isEmpty ? "bolt.fill" : s.icon, size: 22, weight: .regular, color: iconColor, at: NSPoint(x: p.x, y: y - iconH / 2))
        y -= iconH + gap
        let titleRect = NSRect(x: p.x - titleWidth / 2, y: y - titleH, width: titleWidth, height: titleH)
        if mode == .click, titleH < 20 {
            // Number keys are active only in click mode, so badges appear only there.
            let number = String(index + 1)
            let measured = (s.title as NSString).size(withAttributes: [.font: titleFont]).width
            let groupWidth = min(measured, titleWidth - 22) + 22
            let badge = NSRect(x: p.x - groupWidth / 2, y: titleRect.midY - 7, width: 14, height: 14)
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            drawText(number, in: badge, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: color, lines: 1)
            drawText(s.title, in: NSRect(x: badge.maxX + 6, y: titleRect.minY, width: groupWidth - 20, height: titleH), font: titleFont, color: color, lines: 1)
        } else {
            drawText(s.title, in: titleRect, font: titleFont, color: color, lines: 2)
        }
        y -= titleH
        if let note = s.note {
            drawText(note, in: NSRect(x: p.x - 48, y: y - noteH, width: 96, height: noteH),
                     font: .systemFont(ofSize: 9, weight: .medium), color: highlighted ? .white : NSColor.systemOrange, lines: 1)
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
        // Shaken's own glyphs from the asset kit.
        if name.hasPrefix(Brand.glyphPrefix) {
            let side = size + 2
            if let img = Brand.tinted(String(name.dropFirst(Brand.glyphPrefix.count)), color: color, side: side) {
                img.draw(in: NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
                return
            }
        }
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
        if event.phase == .ended || event.phase == .cancelled {
            // Let go before the switch point: spring back.
            if !swipeDone { controller?.swipeCancelled() }
            swipeX = 0; swipeDone = false
            return
        }
        guard event.hasPreciseScrollingDeltas else {
            // A plain mouse wheel: each notch with horizontal movement flips once.
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 {
                controller?.swiped(next: event.scrollingDeltaX < 0)
            }
            return
        }
        // Only count gestures that are mostly sideways.
        guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return }
        guard !swipeDone else { return }
        swipeX += event.scrollingDeltaX
        // The wheel follows the fingers, then slides on to the next wheel past the switch point.
        controller?.swipeFollow(swipeX)
        if abs(swipeX) > 70 {
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
