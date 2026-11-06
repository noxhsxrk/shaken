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
    /// Right-click or Control-click on a slot (click mode): a menu to change what it shows.
    func wheel(didRightClickSlotAt index: Int, menuHost view: NSView, at point: NSPoint)
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
        view = WheelView(frame: effect.bounds)
        // The glass is cut into the same tiles the view draws, so gaps show the desktop. It's a layer
        // mask, not a mask image, so the cut-out turns with the ring when switching wheels.
        effect.wantsLayer = true
        view.glassMask.frame = effect.bounds
        effect.layer?.mask = view.glassMask
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
    // MARK: turning between wheels
    // The window and the centre stay still; only the ring of slots turns, like a dial.

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Follows a two-finger swipe: the ring turns with the fingers.
    func follow(_ dx: CGFloat) {
        guard !reduceMotion else { return }
        view.turn(by: dx)
    }

    /// The swipe wasn't far enough: the ring springs back.
    func settle() { view.cancelTurn() }

    /// Turns the old ring away and the new one in. `direction` 1 = next, -1 = previous.
    func slide(direction: Int, swap: @escaping () -> Void) {
        guard !reduceMotion, panel.isVisible else {
            view.endTurn()
            swap()
            return
        }
        view.finishTurn(direction: direction, swap: swap)
    }

    func replace(slots: [ResolvedSlot], summary: String, shelfCount: Int, page: WheelPageInfo?) {
        view.configure(slots: slots, summary: summary, mode: mode, shelfCount: shelfCount)
        view.page = page
        view.hovered = 0
    }

    func key(_ k: WheelKeys.Key) { view.handleKey(k) }

    func close() {
        view.endTurn()
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

    fileprivate func rightClicked(_ index: Int, in view: NSView, at point: NSPoint) {
        delegate?.wheel(didRightClickSlotAt: index, menuHost: view, at: point)
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
        wantsLayer = true   // the ring turns as layers on top while switching wheels
        buildGlassMask()
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
        if !ringHidden { drawRing() }
        drawCentre()
    }

    /// The six slots: glass tiles, icons and labels.
    private func drawRing() {
        let g = geo
        for i in 0..<g.count {
            let path = g.sector(i)
            let s = slot(i)
            let hot = hovered == i && s?.enabled == true
            Brand.drawGlass(path, dark: isDark, selected: hot)
            if let s { drawSlot(s, index: i, angle: g.midAngle(i), highlighted: hot) }
        }
    }

    // MARK: turning the ring

    /// The shape the window's glass is cut to: the centre disc, which stays still, and the tiles,
    /// which turn with the ring. Each turning ring layer gets a matching tile mask that moves with it.
    let glassMask = CALayer()
    private let restingTiles = CAShapeLayer()
    private var tileMasks: [ObjectIdentifier: CAShapeLayer] = [:]

    private func tilesMask() -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = bounds
        let g = geo
        let path = CGMutablePath()
        for i in 0..<g.count { path.addPath(g.sector(i).cgPathCompat) }
        l.path = path
        l.fillColor = NSColor.black.cgColor
        l.actions = ["transform": NSNull(), "opacity": NSNull(), "hidden": NSNull(), "path": NSNull()]
        return l
    }

    private func buildGlassMask() {
        glassMask.frame = bounds
        glassMask.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let disc = CAShapeLayer()
        disc.frame = bounds
        disc.path = geo.centreDisc.cgPathCompat
        disc.fillColor = NSColor.black.cgColor
        glassMask.addSublayer(disc)
        let tiles = tilesMask()
        restingTiles.frame = tiles.frame
        restingTiles.path = tiles.path
        restingTiles.fillColor = tiles.fillColor
        restingTiles.actions = tiles.actions
        glassMask.addSublayer(restingTiles)
    }

    /// Does the same to a ring layer and the tile mask that turns with it.
    private func both(_ l: CALayer, _ change: (CALayer) -> Void) {
        change(l)
        if let m = tileMasks[ObjectIdentifier(l)] { change(m) }
    }

    /// While turning, the ring is drawn by these layers instead of draw(_:), so it can rotate on the GPU.
    private var ringHidden = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            restingTiles.isHidden = ringHidden
            CATransaction.commit()
        }
    }
    private var oldRing: CALayer?
    private var turnAngle: CGFloat = 0
    private static let turnLimit: CGFloat = 38   // degrees the ring can be dragged
    private static let turnAway: CGFloat = 62    // degrees it turns when switching

    private func ringImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        effectiveAppearance.performAsCurrentDrawingAppearance { drawRing() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// For the snapshot renderer: the ring and the centre as separate images.
    func snapshotRing() -> CGImage? { ringImage() }
    func snapshotCentre() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        effectiveAppearance.performAsCurrentDrawingAppearance { drawCentre() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private func ringLayer() -> CALayer? {
        guard let host = layer, let img = ringImage() else { return nil }
        let l = CALayer()
        l.frame = bounds
        l.contents = img
        l.contentsScale = window?.backingScaleFactor ?? 2
        l.actions = ["transform": NSNull(), "opacity": NSNull()]   // driven explicitly, never implicitly
        host.addSublayer(l)
        let m = tilesMask()
        glassMask.addSublayer(m)
        tileMasks[ObjectIdentifier(l)] = m
        return l
    }

    private func rotation(_ degrees: CGFloat, scale: CGFloat = 1) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeRotation(degrees * .pi / 180, 0, 0, 1), scale, scale, 1)
    }

    private func beginTurn() {
        guard oldRing == nil else { return }
        // A switch that's still animating snaps to its end first.
        if !pendingRings.isEmpty { endTurn() }
        turnID += 1
        oldRing = ringLayer()
        ringHidden = oldRing != nil
        turnAngle = 0
        needsDisplay = true
    }

    /// Fingers moving left turn the ring anticlockwise, like pushing the top of a dial.
    func turn(by dx: CGFloat) {
        beginTurn()
        guard let l = oldRing else { return }
        let limit = Self.turnLimit
        turnAngle = limit * tanh(-dx * 0.45 / limit)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = rotation(turnAngle), o = Float(1 - abs(turnAngle) / limit * 0.35)
        both(l) { $0.transform = t; $0.opacity = o }
        CATransaction.commit()
    }

    func cancelTurn() {
        guard let l = oldRing else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = l.presentation()?.transform ?? l.transform
        spring.toValue = CATransform3DIdentity
        spring.damping = 16
        spring.stiffness = 260
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = l.opacity
        fade.toValue = 1
        fade.duration = 0.2
        let id = turnID
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in if self?.turnID == id { self?.endTurn() } }
        both(l) {
            $0.transform = CATransform3DIdentity
            $0.opacity = 1
            $0.add(spring, forKey: "settle")
            $0.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }

    /// Old ring turns away and fades; the new ring turns in from the other side and settles.
    func finishTurn(direction: Int, swap: () -> Void) {
        beginTurn()
        guard let old = oldRing else { swap(); return }
        let d = CGFloat(direction)
        let from = old.presentation()?.transform ?? old.transform
        swap()
        ringHidden = true
        guard let new = ringLayer() else { endTurn(); return }

        let ease = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1)
        func animate(_ l: CALayer, _ key: String, _ a: Any, _ b: Any, _ t: CFTimeInterval, delay: CFTimeInterval = 0) {
            let an = CABasicAnimation(keyPath: key)
            an.fromValue = a; an.toValue = b; an.duration = t; an.timingFunction = ease
            an.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
            an.fillMode = .backwards
            both(l) { $0.add(an, forKey: key) }
        }
        let id = turnID
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in if self?.turnID == id { self?.endTurn() } }
        let outT = rotation(d * Self.turnAway, scale: 0.94)
        both(old) { $0.transform = outT; $0.opacity = 0 }
        animate(old, "transform", from, outT, 0.26)
        animate(old, "opacity", old.presentation()?.opacity ?? 1, 0, 0.2)
        let inFrom = rotation(-d * Self.turnAway, scale: 0.94)
        both(new) { $0.transform = CATransform3DIdentity; $0.opacity = 1 }
        animate(new, "transform", inFrom, CATransform3DIdentity, 0.36, delay: 0.04)
        animate(new, "opacity", 0, 1, 0.24, delay: 0.04)
        CATransaction.commit()
        oldRing = nil
        pendingRings = [old, new]
    }

    private var pendingRings: [CALayer] = []
    /// Bumped on every turn, so a finished animation only cleans up its own layers.
    private var turnID = 0

    /// Drops the turning layers and draws the ring normally again.
    func endTurn() {
        for l in [oldRing].compactMap({ $0 }) + pendingRings {
            l.removeFromSuperlayer()
            tileMasks.removeValue(forKey: ObjectIdentifier(l))?.removeFromSuperlayer()
        }
        oldRing = nil
        pendingRings = []
        turnAngle = 0
        if ringHidden { ringHidden = false; needsDisplay = true }
    }

    /// The centre button: what's dragged, the shelf, Back in a submenu, and the wheel's name.
    private func drawCentre() {
        let g = geo
        let disc = g.centreDisc
        let centreActive = hovered == -1 && (submenu != nil || mode == .drag)
        Brand.drawGlass(disc, dark: isDark, selected: centreActive)

        let c = g.center, r = g.innerRadius
        if let page, submenu == nil, mode == .click { drawPage(page, centre: c) }
        let fg: NSColor = centreActive ? Brand.onAccent : ink
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
        let color: NSColor = !s.enabled ? ink.withAlphaComponent(0.35) : (highlighted ? Brand.onAccent : ink)
        let iconColor = color
        // Icon, title (1–2 lines) and note stacked as one block centred on the tile.
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleWidth: CGFloat = 112
        // Number keys are active only in click mode, so badges appear only there. The badge sits
        // beside the title, and the title wraps next to it instead of being cut off.
        let badged = mode == .click
        let badgeW: CGFloat = 14, badgeGap: CGFloat = 6
        let textWidth = badged ? titleWidth - badgeW - badgeGap : titleWidth
        let titleSize = textSize(s.title, font: titleFont, width: textWidth, lines: 3)
        let titleH = titleSize.height
        let iconH: CGFloat = 24, gap: CGFloat = 5, noteH: CGFloat = s.note == nil ? 0 : 14
        let extraH: CGFloat = s.kind.opensRing ? 12 : 0
        let total = iconH + gap + titleH + noteH + extraH
        var y = p.y + total / 2
        drawSymbol(s.icon.isEmpty ? "bolt.fill" : s.icon, size: 22, weight: .regular, color: iconColor, at: NSPoint(x: p.x, y: y - iconH / 2))
        y -= iconH + gap
        let titleRect = NSRect(x: p.x - titleWidth / 2, y: y - titleH, width: titleWidth, height: titleH)
        if badged {
            let number = String(index + 1)
            // Wrap at the same width it was measured at, then centre badge + visible text as one group.
            let textW = min(titleSize.width, textWidth)
            let groupWidth = badgeW + badgeGap + textW
            let badge = NSRect(x: p.x - groupWidth / 2, y: titleRect.midY - 7, width: badgeW, height: 14)
            let textMid = badge.maxX + badgeGap + textW / 2
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            drawText(number, in: badge, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: color, lines: 1)
            drawText(s.title, in: NSRect(x: textMid - textWidth / 2, y: titleRect.minY, width: textWidth, height: titleH), font: titleFont, color: color, lines: 3)
        } else {
            drawText(s.title, in: titleRect, font: titleFont, color: color, lines: 3)
        }
        y -= titleH
        if let note = s.note {
            drawText(note, in: NSRect(x: p.x - 48, y: y - noteH, width: 96, height: noteH),
                     font: .systemFont(ofSize: 9, weight: .medium), color: highlighted ? Brand.onAccent : NSColor.systemOrange, lines: 1)
            y -= noteH
        }
        if s.kind.opensRing {
            drawSymbol("ellipsis", size: 10, weight: .bold, color: color.withAlphaComponent(0.6), at: NSPoint(x: p.x, y: y - extraH / 2))
        }
    }

    /// The size `s` takes when wrapped to `width`, at most `lines` lines.
    private func textSize(_ s: String, font: NSFont, width: CGFloat, lines: Int) -> NSSize {
        // Same wrapping as drawText, so the measured width matches the lines that get drawn.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineBreakStrategy = .standard
        para.lineHeightMultiple = 0.95
        let r = NSAttributedString(string: s, attributes: [.font: font, .paragraphStyle: para])
            .boundingRect(with: NSSize(width: width, height: CGFloat(lines) * font.pointSize * 1.3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return NSSize(width: r.width, height: ceil(r.height) + 1)
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
        para.lineBreakStrategy = .standard
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
        if event.modifierFlags.contains(.control) { return }   // Control-click is a right-click (mouseDown)
        activate(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
    }

    /// Right-click a slot to change what it shows. Only in click mode: during a drag the button is held.
    override func rightMouseDown(with event: NSEvent) {
        guard mode == .click, submenu == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p), i >= 0, i < ring.count else { return }
        hovered = i
        needsDisplay = true
        controller?.rightClicked(i, in: self, at: p)
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

extension NSBezierPath {
    /// `cgPath` is macOS 14+; this works on 13.
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
