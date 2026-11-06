import AppKit
import SwiftUI
import ShakenCore

/// Dev aid: `SHAKEN_SNAPSHOT=<dir> Shaken` renders the popups to PNGs and exits,
/// so the look can be checked without driving a real drag.
enum Snapshot {
    @MainActor static func runIfRequested() {
        if let dir = ProcessInfo.processInfo.environment["SHAKEN_DMG_BACKGROUND"] {
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
                try? Logo.dmgBackground(scale: scale).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            }
            exit(0)
        }
        guard let dir = ProcessInfo.processInfo.environment["SHAKEN_SNAPSHOT"] else { return }
        // Docs and the site use Shaken blue, whatever accent color this Mac has.
        Brand.look = { (.shaken, GlassTint.shakenHex, 0.5) }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let settings = ShakenSettings()
        let actions = ActionRegistry.builtins()
        let images = ActionResolver.layout(payload: ActionResolver.samplePayload(for: .image), actions: actions, settings: settings,
                                           fallbacks: ActionResolver.defaultFallbacks())
        let text = ActionResolver.layout(payload: ActionResolver.samplePayload(for: .text), actions: actions, settings: settings,
                                         fallbacks: ActionResolver.defaultFallbacks())
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let ap = NSAppearance(named: appearance)!
            wheel(images, summary: "2 images", mode: .drag, hover: 1, shelf: 0, ap, out.appendingPathComponent("wheel-drag-\(name).png"))
            wheel(images, summary: "2 images", mode: .drag, hover: -1, shelf: 0, ap, out.appendingPathComponent("wheel-centre-\(name).png"))
            let menu = Logo.menuBarImage()
            render(size: NSSize(width: 18, height: 18), ap, out.appendingPathComponent("menubar-\(name).png"), background: { b in
                (ap.name == .darkAqua ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); b.fill()
            }) { b in
                // Tint the template the way the menu bar does.
                let tinted = NSImage(size: b.size, flipped: false) { r in
                    menu.draw(in: r); (ap.name == .darkAqua ? NSColor.white : NSColor.black).set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: b)
            }
            tray(ap, out.appendingPathComponent("tray-\(name).png"))
            chip(.failed("Can't read image “IMG_0001.HEIC”. The file may be damaged."), ap, out.appendingPathComponent("chip-failed-\(name).png"))
            chip(.running("Convert to JPG"), ap, out.appendingPathComponent("chip-running-\(name).png"))
            var mixed = ShakenSettings()
            mixed.slots = [Slot(kind: .app, target: "/System/Applications/Calendar.app"), Slot(kind: .system, target: "mute"),
                           Slot(kind: .switcher), Slot(kind: .shell, title: "Backup", target: "true"),
                           Slot(kind: .keys, target: "cmd+shift+4"), Slot(kind: .snippet, target: "Thanks!")]
            let m = ActionResolver.layout(payload: DragPayload([]), actions: actions, settings: mixed.validated())
            wheel(m, summary: "Shaken", mode: .click, hover: 2, shelf: 0, ap, out.appendingPathComponent("wheel-kinds-\(name).png"))
            wheel(text, summary: "Text", mode: .click, hover: nil, shelf: 3, ap, out.appendingPathComponent("wheel-click-\(name).png"))
        }
        do {
            var m = ShakenSettings()
            m.slots = [Slot(kind: .app, target: "/System/Applications/Calendar.app"), Slot(kind: .system, target: "mute"),
                       Slot(kind: .switcher), Slot(kind: .auto), Slot(kind: .keys, target: "cmd+shift+4"), Slot(kind: .empty)]
            m = m.validated()
            let r = ImageRenderer(content: WheelPreview(slots: m.slots, selected: .constant(m.slots[1].id), swap: { _, _ in }, interactive: false)
                .padding(10).environment(\.colorScheme, .dark).background(Color(nsColor: NSColor(white: 0.16, alpha: 1))))
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("settings-preview.png"))
            }
        }
        // Mid-swipe: the ring turned partway, the centre still.
        for (dx, name) in [(CGFloat(-45), "turn-mid"), (CGFloat(-140), "turn-far")] {
            let d = WheelController.diameter
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            let v = WheelView(frame: NSRect(x: 0, y: 0, width: d, height: d))
            win.contentView = v
            v.configure(slots: images, summary: "2 images", mode: .click, shelfCount: 0)
            v.page = WheelPageInfo(name: "Main", index: 0, count: 3)
            v.display()
            v.turn(by: dx)
            v.display()
            let px = Int(d * 2)
            if let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let host = v.layer {
                ctx.setFillColor(Brand.night.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
                ctx.scaleBy(x: 2, y: 2)
                host.render(in: ctx)
                if let img = ctx.makeImage() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
                }
            }
        }
        if ProcessInfo.processInfo.environment["SHAKEN_SNAPSHOT_MOTION"] != nil { motionFrames(out.appendingPathComponent("motion", isDirectory: true), images: images, actions: actions) }
        if ProcessInfo.processInfo.environment["SHAKEN_SNAPSHOT_FLOW"] != nil { flowFrames(out.appendingPathComponent("flow", isDirectory: true), images: images) }
        let ctl = AppController()
        for i in 0..<4 {
            let r = ImageRenderer(content: WelcomeView(app: ctl, close: {}, page: i).environment(\.colorScheme, .dark)
                .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))))
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent("welcome-\(i).png"))
            }
        }
        exit(0)
    }

    private static func tray(_ ap: NSAppearance, _ url: URL) {
        let items = [ShelfItem(kind: .file, value: "/Applications/Safari.app"),
                     ShelfItem(kind: .file, value: "/System/Library/CoreServices/Finder.app"),
                     ShelfItem(kind: .link, value: "https://example.com/a"),
                     ShelfItem(kind: .text, value: "Meeting notes for Friday")]
        let t = ShelfTrayController()
        t.effect.appearance = ap
        let size = t.build(items: items)
        // Vibrant labels don't draw into a cache, so host the content in a plain view.
        let plain = NSView(frame: NSRect(origin: .zero, size: size))
        plain.appearance = ap
        let stack = t.effect.subviews.last!   // the content; the brand surface sits underneath
        stack.removeFromSuperview()
        plain.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: plain.leadingAnchor), stack.trailingAnchor.constraint(equalTo: plain.trailingAnchor),
            stack.topAnchor.constraint(equalTo: plain.topAnchor), stack.bottomAnchor.constraint(equalTo: plain.bottomAnchor),
        ])
        let host = NSWindow(contentRect: plain.frame, styleMask: .borderless, backing: .buffered, defer: true)
        host.contentView = plain
        plain.layoutSubtreeIfNeeded()
        render(size: size, ap, url, background: { b in
            let dark = ap.name == .darkAqua
            (dark ? Brand.night : NSColor(srgbRed: 0.86, green: 0.88, blue: 0.94, alpha: 1)).setFill(); b.fill()
            Brand.surface(dark: dark).setFill()
            NSBezierPath(roundedRect: b, xRadius: 16, yRadius: 16).fill()
        }) { b in
            let rep = plain.bitmapImageRepForCachingDisplay(in: plain.bounds)!
            plain.cacheDisplay(in: plain.bounds, to: rep)
            rep.draw(in: b, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Frames of the wheel turning between three wheels, for the README animation.
    @MainActor private static func motionFrames(_ dir: URL, images: [ResolvedSlot], actions: [ActionManifest]) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = WheelController.diameter
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        let v = WheelView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        win.contentView = v

        func wheel(_ slots: [Slot]) -> [ResolvedSlot] {
            var st = ShakenSettings(); st.slots = slots
            return ActionResolver.layout(payload: DragPayload([]), actions: actions, settings: st.validated())
        }
        let launcher = wheel([Slot(kind: .app, target: "/System/Applications/Calendar.app"), Slot(kind: .system, target: "mute"),
                              Slot(kind: .switcher), Slot(kind: .shell, title: "Backup", target: "true"),
                              Slot(kind: .keys, target: "cmd+shift+4"), Slot(kind: .snippet, target: "Thanks!")])
        let media = wheel([Slot(kind: .system, target: "play-pause"), Slot(kind: .system, target: "next-track"),
                           Slot(kind: .system, target: "volume-up"), Slot(kind: .system, target: "mute"),
                           Slot(kind: .system, target: "volume-down"), Slot(kind: .system, target: "previous-track")])
        let pages: [(slots: [ResolvedSlot], summary: String, name: String, hot: Int)] = [
            (images, "2 images", "Main", 1), (launcher, "Shaken", "Work", 2), (media, "Shaken", "Media", 0),
        ]
        var rings: [CGImage] = [], centres: [CGImage] = []
        for (i, p) in pages.enumerated() {
            v.configure(slots: p.slots, summary: p.summary, mode: .click, shelfCount: 0)
            v.page = WheelPageInfo(name: p.name, index: i, count: pages.count)
            v.hovered = p.hot
            if let r = v.snapshotRing(), let c = v.snapshotCentre() { rings.append(r); centres.append(c) }
        }
        guard rings.count == pages.count else { return }

        let px = Int(d * 2)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var n = 0
        func frame(_ layers: [(img: CGImage, angle: CGFloat, scale: CGFloat, alpha: CGFloat)]) {
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(Brand.night.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
            // A soft glow behind the wheel.
            let glow = CGGradient(colorsSpace: cs, colors: [Brand.accent.withAlphaComponent(0.42).cgColor, Brand.night.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: px / 2, y: px / 2), startRadius: 0, endCenter: CGPoint(x: px / 2, y: px / 2), endRadius: CGFloat(px) * 0.62, options: [])
            for l in layers where l.alpha > 0.001 {
                ctx.saveGState()
                ctx.setAlpha(l.alpha)
                ctx.translateBy(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
                ctx.rotate(by: l.angle * .pi / 180)
                ctx.scaleBy(x: l.scale * 0.84, y: l.scale * 0.84)   // leave room for the glow
                ctx.draw(l.img, in: CGRect(x: -CGFloat(px) / 2, y: -CGFloat(px) / 2, width: CGFloat(px), height: CGFloat(px)))
                ctx.restoreGState()
            }
            if let img = ctx.makeImage(),
               let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
                n += 1
            }
        }
        func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - min(max(t, 0), 1), 3) }
        func easeInOut(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

        let fps: CGFloat = 30, hold = 30, follow = 9, turn = 13
        for i in 0..<pages.count {
            let a = i, b = (i + 1) % pages.count
            for _ in 0..<hold { frame([(rings[a], 0, 1, 1), (centres[a], 0, 1, 1)]) }
            // Fingers start to push the ring.
            for k in 0..<follow {
                let ang = 18 * easeInOut(CGFloat(k + 1) / CGFloat(follow))
                frame([(rings[a], ang, 1, 1 - ang / 38 * 0.35), (centres[a], 0, 1, 1)])
            }
            // Past the switch point: old turns away, new turns in, centre crossfades.
            for k in 0..<turn {
                let t = CGFloat(k + 1) / fps
                let outP = easeOut(t / 0.26), inP = easeOut((t - 0.04) / 0.38)
                let oldAngle = 18 + (62 - 18) * outP
                frame([(rings[a], oldAngle, 1 - 0.06 * outP, (1 - 18.0 / 38 * 0.35) * (1 - outP)),
                       (rings[b], -62 * (1 - inP), 0.94 + 0.06 * inP, inP),
                       (centres[a], 0, 1, 1 - easeOut(t / 0.2)), (centres[b], 0, 1, easeOut(t / 0.2))])
            }
        }
    }

    private static func chip(_ state: ChipController.State, _ ap: NSAppearance, _ url: URL) {
        let c = ChipController()
        c.view.appearance = ap
        let size = c.layout(state)
        let shown: NSView = c.view
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        shown.removeFromSuperview()
        shown.frame = NSRect(origin: .zero, size: size)
        host.contentView = shown
        shown.layoutSubtreeIfNeeded()
        render(size: size, ap, url, background: { b in
            let dark = ap.name == .darkAqua
            Brand.surface(dark: dark).setFill()
            NSBezierPath(roundedRect: b, xRadius: c.cornerRadius(for: size), yRadius: c.cornerRadius(for: size)).fill()
        }) { b in
            let rep = shown.bitmapImageRepForCachingDisplay(in: shown.bounds)!
            shown.cacheDisplay(in: shown.bounds, to: rep)
            rep.draw(in: b, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private static func render(size: NSSize, _ ap: NSAppearance, _ url: URL, background: (NSRect) -> Void, content: (NSRect) -> Void) {
        let bounds = NSRect(origin: .zero, size: size)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ap.performAsCurrentDrawingAppearance { background(bounds); content(bounds) }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func wheel(_ slots: [ResolvedSlot], summary: String, mode: WheelMode, hover: Int?, shelf: Int, _ ap: NSAppearance, _ url: URL) {
        let d = WheelController.diameter
        let bounds = NSRect(x: 0, y: 0, width: d, height: d)
        let view = WheelView(frame: bounds)
        view.appearance = ap
        view.configure(slots: slots, summary: summary, mode: mode, shelfCount: shelf)
        view.hovered = hover
        if mode == .click { view.page = WheelPageInfo(name: "Safari", index: 1, count: 4) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(d * 2), pixelsHigh: Int(d * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ap.performAsCurrentDrawingAppearance {
            let dark = ap.name == .darkAqua
            // Stand-in desktop behind the wheel.
            (dark ? Brand.night : NSColor(srgbRed: 0.86, green: 0.88, blue: 0.94, alpha: 1)).setFill()
            bounds.fill()
            view.draw(bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The README's main demo, drawn with the real wheel: drag a photo, shake, drop on Convert to JPG,
    /// then drag the result chip into a form that only takes JPG. Frames go to `dir` at 30 fps.
    @MainActor private static func flowFrames(_ dir: URL, images: [ResolvedSlot]) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = WheelController.diameter
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        let v = WheelView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        win.contentView = v
        let jpg = images.firstIndex { $0.actionID == "builtin.to-jpg" } ?? 0
        v.configure(slots: images, summary: "IMG_0412.HEIC", mode: .drag, shelfCount: 0)
        v.hovered = nil
        guard let ringIdle = v.snapshotRing(), let centre = v.snapshotCentre() else { return }
        v.hovered = jpg
        guard let ringHot = v.snapshotRing() else { return }

        let W: CGFloat = 640, H: CGFloat = 400, scale: CGFloat = 2
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let wheelD: CGFloat = 290, wheelAt = CGPoint(x: 330, y: 205)
        // Where Convert to JPG sits on the wheel (slot 0 is at the top, then clockwise).
        let jpgAngle = (90 - CGFloat(jpg) * 60) * .pi / 180
        let jpgPoint = CGPoint(x: wheelAt.x + cos(jpgAngle) * wheelD * 0.335, y: wheelAt.y + sin(jpgAngle) * wheelD * 0.335)
        let photo = CGPoint(x: 112, y: 232), drop = CGPoint(x: 505, y: 105)
        let photoGrad = [NSColor(srgbRed: 0.95, green: 0.65, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.88, green: 0.38, blue: 0.49, alpha: 1),
                         NSColor(srgbRed: 0.42, green: 0.36, blue: 0.85, alpha: 1)]

        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        func ease(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
        func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint, centred: Bool = false) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            let w = a.size().width
            a.draw(at: NSPoint(x: centred ? p.x - w / 2 : p.x, y: p.y))
        }
        func thumb(_ r: NSRect) {
            NSGradient(colors: photoGrad)?.draw(in: NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7), angle: -45)
        }
        func window(_ r: NSRect, _ title: String) {
            NSColor(srgbRed: 0.12, green: 0.15, blue: 0.24, alpha: 0.96).setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12); p.fill()
            NSColor.white.withAlphaComponent(0.12).setStroke(); p.lineWidth = 1; p.stroke()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 12 + CGFloat(i) * 14, y: r.maxY - 18, width: 8, height: 8)).fill()
            }
            text(title, 10.5, .medium, NSColor.white.withAlphaComponent(0.6), at: CGPoint(x: r.minX + 60, y: r.maxY - 21))
        }
        func cursor(_ p: CGPoint) {
            let a = NSBezierPath()
            a.move(to: NSPoint(x: p.x, y: p.y)); a.line(to: NSPoint(x: p.x, y: p.y - 17)); a.line(to: NSPoint(x: p.x + 4.5, y: p.y - 13))
            a.line(to: NSPoint(x: p.x + 8, y: p.y - 20)); a.line(to: NSPoint(x: p.x + 11, y: p.y - 18.5)); a.line(to: NSPoint(x: p.x + 7.5, y: p.y - 12))
            a.line(to: NSPoint(x: p.x + 13, y: p.y - 12)); a.close()
            NSColor.white.setFill(); a.fill(); NSColor.black.setStroke(); a.lineWidth = 1.1; a.stroke()
        }
        func chip(at p: CGPoint, alpha: CGFloat) {
            guard alpha > 0 else { return }
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            let r = NSRect(x: p.x - 16, y: p.y - 26, width: 196, height: 50)
            Brand.drawGlass(NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14), dark: true)
            thumb(NSRect(x: r.minX + 9, y: r.minY + 9, width: 32, height: 32))
            text("IMG_0412.jpg", 12, .semibold, Brand.darkText, at: CGPoint(x: r.minX + 50, y: r.minY + 25))
            text("3.1 MB → 1.2 MB · drag me", 10, .regular, Brand.darkText.withAlphaComponent(0.6), at: CGPoint(x: r.minX + 50, y: r.minY + 10))
            NSGraphicsContext.current?.cgContext.setAlpha(1)
        }
        func caption(_ n: Int, _ s: String) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Brand.darkText])
            let w = a.size().width + 46, r = NSRect(x: (W - w) / 2, y: 14, width: w, height: 28)
            NSColor(srgbRed: 0.05, green: 0.07, blue: 0.13, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
            Brand.accent.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 5, y: r.minY + 4, width: 20, height: 20)).fill()
            text("\(n)", 11, .bold, .white, at: CGPoint(x: r.minX + 15, y: r.minY + 7.5), centred: true)
            a.draw(at: NSPoint(x: r.minX + 33, y: r.minY + 6))
        }

        var n = 0
        func frame(cursorAt c: CGPoint, ghost: Bool, wheel: CGFloat, hot: Bool, chipAt: CGPoint?, chipAlpha: CGFloat,
                   dropDone: Bool, dropHot: Bool, step: (Int, String)) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: W, height: H)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let ctx = NSGraphicsContext.current!.cgContext
            Brand.night.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
            let glow = CGGradient(colorsSpace: cs, colors: [Brand.accent.withAlphaComponent(0.30).cgColor, Brand.night.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.25, y: H), startRadius: 0, endCenter: CGPoint(x: W * 0.25, y: H), endRadius: W * 0.8, options: [])
            // Photos window with four pictures; the one being dragged is outlined.
            window(NSRect(x: 40, y: 150, width: 170, height: 200), "Photos")
            for (i, o) in [(0, 1), (1, 1), (0, 0), (1, 0)].enumerated() {
                let r = NSRect(x: 54 + CGFloat(o.0) * 76, y: 166 + CGFloat(o.1) * 76, width: 66, height: 66)
                if i == 2 { thumb(r); Brand.accent.setStroke(); let b = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9); b.lineWidth = 2; b.stroke() }
                else { (i == 1 ? NSColor(srgbRed: 0.3, green: 0.6, blue: 0.8, alpha: 0.8) : NSColor(srgbRed: 0.45, green: 0.7, blue: 0.5, alpha: 0.8)).setFill()
                       NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill() }
            }
            // A form that only takes JPG.
            window(NSRect(x: 420, y: 50, width: 190, height: 130), "Upload · JPG only")
            let zone = NSRect(x: 434, y: 64, width: 162, height: 82)
            let z = NSBezierPath(roundedRect: zone, xRadius: 9, yRadius: 9)
            if dropDone { NSColor.systemGreen.withAlphaComponent(0.16).setFill(); z.fill(); NSColor.systemGreen.withAlphaComponent(0.6).setStroke() }
            else { if dropHot { Brand.accent.withAlphaComponent(0.18).setFill(); z.fill() }
                   Brand.accent.withAlphaComponent(dropHot ? 0.9 : 0.45).setStroke(); z.setLineDash([5, 4], count: 2, phase: 0) }
            z.lineWidth = 1.4; z.stroke()
            text(dropDone ? "IMG_0412.jpg  ✓" : "Drop your photo here", 11, .medium,
                 dropDone ? NSColor(srgbRed: 0.72, green: 0.96, blue: 0.76, alpha: 1) : Brand.darkText.withAlphaComponent(0.6),
                 at: CGPoint(x: zone.midX, y: zone.midY - 7), centred: true)
            // The wheel, opened where the shake happened.
            if wheel > 0.001 {
                ctx.saveGState()
                ctx.setAlpha(wheel)
                let sc = 0.85 + 0.15 * wheel, side = wheelD * sc
                let r = CGRect(x: wheelAt.x - side / 2, y: wheelAt.y - side / 2, width: side, height: side)
                ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.draw(hot ? ringHot : ringIdle, in: r)
                ctx.setShadow(offset: .zero, blur: 0)
                ctx.draw(centre, in: r)
                ctx.restoreGState()
            }
            if let p = chipAt { chip(at: p, alpha: chipAlpha) }
            if ghost && wheel > 0.001 {
                // Over the wheel, the dragged item shrinks to its picture so it doesn't hide the slot names.
                ctx.setAlpha(0.92)
                thumb(NSRect(x: c.x + 10, y: c.y - 40, width: 26, height: 26))
                ctx.setAlpha(1)
            } else if ghost {
                ctx.setAlpha(0.92)
                let r = NSRect(x: c.x + 8, y: c.y - 44, width: 132, height: 36)
                NSColor(srgbRed: 0.12, green: 0.15, blue: 0.24, alpha: 0.95).setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                thumb(NSRect(x: r.minX + 5, y: r.minY + 5, width: 26, height: 26))
                text("IMG_0412.HEIC", 10.5, .medium, Brand.darkText, at: CGPoint(x: r.minX + 38, y: r.minY + 11))
                ctx.setAlpha(1)
            }
            cursor(c)
            caption(step.0, step.1)
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
                n += 1
            }
        }

        let mid = CGPoint(x: wheelAt.x - 10, y: wheelAt.y + 8)
        let s1 = (1, "Drag a photo"), s2 = (2, "Shake the mouse"), s3 = (3, "Drop on Convert to JPG"), s4 = (4, "Drag the result into the form")
        for _ in 0..<18 { frame(cursorAt: photo, ghost: false, wheel: 0, hot: false, chipAt: nil, chipAlpha: 0, dropDone: false, dropHot: false, step: s1) }
        for k in 0..<30 { frame(cursorAt: lerp(photo, mid, ease(CGFloat(k) / 29)), ghost: true, wheel: 0, hot: false, chipAt: nil, chipAlpha: 0, dropDone: false, dropHot: false, step: s1) }
        for k in 0..<24 {
            let dx = sin(CGFloat(k) / 24 * .pi * 6) * 26 * (1 - CGFloat(k) / 30)
            frame(cursorAt: CGPoint(x: mid.x + dx, y: mid.y), ghost: true, wheel: 0, hot: false, chipAt: nil, chipAlpha: 0, dropDone: false, dropHot: false, step: s2)
        }
        for k in 0..<9 { frame(cursorAt: mid, ghost: true, wheel: ease(CGFloat(k + 1) / 9), hot: false, chipAt: nil, chipAlpha: 0, dropDone: false, dropHot: false, step: s2) }
        for k in 0..<24 {
            let t = ease(CGFloat(k) / 23)
            frame(cursorAt: lerp(mid, jpgPoint, t), ghost: true, wheel: 1, hot: t > 0.6, chipAt: nil, chipAlpha: 0, dropDone: false, dropHot: false, step: s3)
        }
        for _ in 0..<14 { frame(cursorAt: jpgPoint, ghost: true, wheel: 1, hot: true, chipAt: nil, chipAlpha: 0, dropDone: false, dropHot: false, step: s3) }
        for k in 0..<8 {
            let t = CGFloat(k + 1) / 8
            frame(cursorAt: jpgPoint, ghost: false, wheel: 1 - t, hot: true, chipAt: jpgPoint, chipAlpha: t, dropDone: false, dropHot: false, step: s4)
        }
        for _ in 0..<12 { frame(cursorAt: jpgPoint, ghost: false, wheel: 0, hot: false, chipAt: jpgPoint, chipAlpha: 1, dropDone: false, dropHot: false, step: s4) }
        for k in 0..<34 {
            let t = ease(CGFloat(k) / 33), p = lerp(jpgPoint, drop, t)
            frame(cursorAt: p, ghost: false, wheel: 0, hot: false, chipAt: p, chipAlpha: 1, dropDone: false, dropHot: t > 0.75, step: s4)
        }
        for k in 0..<8 { frame(cursorAt: drop, ghost: false, wheel: 0, hot: false, chipAt: drop, chipAlpha: 1 - CGFloat(k + 1) / 8, dropDone: true, dropHot: false, step: s4) }
        for _ in 0..<45 { frame(cursorAt: drop, ghost: false, wheel: 0, hot: false, chipAt: nil, chipAlpha: 0, dropDone: true, dropHot: false, step: s4) }
    }
}
