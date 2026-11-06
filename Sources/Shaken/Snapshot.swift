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
}
