import AppKit

/// The Shaken mark: six wheel slices with one lit, a centre dot, and two shake strokes.
/// Shared by the app icon, the menu bar icon and docs/images/logo.svg.
enum Logo {
    static let accent = NSColor(srgbRed: 0xF2 / 255, green: 0x61 / 255, blue: 0x3F / 255, alpha: 1)

    /// Draws the mark into `rect` (square). `template` draws a single-colour silhouette for the menu bar.
    static func drawMark(in rect: NSRect, tile: NSColor, hot: NSColor, core: NSColor, shake: NSColor?) {
        let s = rect.width / 120   // the SVG is 120 units wide
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let R = 44 * s, r = 22 * s, gap = 3.2 * s
        for i in 0..<6 {
            // Same geometry as the wheel: parallel gaps, slot 0 at the top, clockwise.
            let mid = 90 - CGFloat(i) * 60
            func half(_ rad: CGFloat) -> CGFloat { asin(gap / 2 / rad) * 180 / .pi }
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: R, startAngle: mid + 30 - half(R), endAngle: mid - 30 + half(R), clockwise: true)
            p.appendArc(withCenter: c, radius: r, startAngle: mid - 30 + half(r), endAngle: mid + 30 - half(r))
            p.close()
            (i == 1 ? hot : tile).setFill()
            p.fill()
        }
        core.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 12 * s, y: c.y - 12 * s, width: 24 * s, height: 24 * s)).fill()
        if let shake {
            shake.setStroke()
            for side in [-1.0, 1.0] as [CGFloat] {
                let p = NSBezierPath()
                p.lineWidth = 3.2 * s
                p.lineCapStyle = .round
                let x0 = c.x + side * 51 * s, x1 = c.x + side * 57 * s
                p.move(to: NSPoint(x: x0, y: c.y + 14 * s))
                p.curve(to: NSPoint(x: x0, y: c.y - 14 * s), controlPoint1: NSPoint(x: x1, y: c.y + 6 * s), controlPoint2: NSPoint(x: x1, y: c.y - 6 * s))
                p.stroke()
            }
        }
    }

    /// The menu bar icon: a template image so macOS tints it for light, dark and highlighted bars.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            // Template images use alpha only, so the lit slice and core read as solid and the rest a bit lighter.
            drawMark(in: r.insetBy(dx: -1.5, dy: -1.5), tile: NSColor.black.withAlphaComponent(0.55),
                     hot: .black, core: .black, shake: nil)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Shaken"
        return img
    }

    /// One app icon image, `px` pixels square, in the macOS icon grid (824 of 1024 is the body).
    static func appIcon(px: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

        // Soft drop shadow like the system icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 28
        shadow.set()
        NSColor(white: 0.1, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.26, alpha: 1),
                   ending: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))?.draw(in: shape, angle: -90)
        // A faint top highlight on the edge.
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
        rim.lineWidth = 4
        rim.stroke()

        drawMark(in: body.insetBy(dx: 70, dy: 70), tile: NSColor(srgbRed: 0.90, green: 0.93, blue: 0.95, alpha: 0.92),
                 hot: accent, core: accent, shake: NSColor.white.withAlphaComponent(0.45))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Writes an .iconset folder for `iconutil -c icns`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try appIcon(px: base * scale).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    /// The installer window's background: 660×400 points, the app on the left, Applications on the right.
    static func dmgBackground(scale: Int) -> NSBitmapImageRep {
        let size = NSSize(width: 660, height: 400)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(origin: .zero, size: size)
        // Light, so Finder's icon labels (black in light mode) stay readable.
        NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
                   ending: NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1))?.draw(in: r, angle: -90)

        // A faint wheel behind everything, cropped by the window.
        drawMark(in: NSRect(x: 380, y: -120, width: 460, height: 460), tile: NSColor.black.withAlphaComponent(0.035),
                 hot: accent.withAlphaComponent(0.12), core: NSColor.black.withAlphaComponent(0.03), shake: nil)

        // Title.
        let title = NSAttributedString(string: "Shaken", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        title.draw(at: NSPoint(x: (size.width - title.size().width) / 2, y: 330))
        let sub = NSAttributedString(string: "Shake mid-drag, pick a command, drag the result onward.", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(white: 0.1, alpha: 0.55)])
        sub.draw(at: NSPoint(x: (size.width - sub.size().width) / 2, y: 306))

        // Arrow from the app (x 170) to Applications (x 490); icons sit at y 180 from the top = 220 here.
        let y: CGFloat = 220 - 10
        accent.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 4
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: 268, y: y))
        line.curve(to: NSPoint(x: 384, y: y), controlPoint1: NSPoint(x: 300, y: y + 26), controlPoint2: NSPoint(x: 352, y: y + 26))
        line.stroke()
        accent.setFill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 396, y: y - 2))
        head.line(to: NSPoint(x: 378, y: y + 12))
        head.line(to: NSPoint(x: 377, y: y - 11))
        head.close()
        head.fill()

        let hint = NSAttributedString(string: "Drag Shaken into Applications", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(white: 0.1, alpha: 0.85)])
        hint.draw(at: NSPoint(x: (size.width - hint.size().width) / 2, y: 70))
        let note = NSAttributedString(string: "Then open it from Applications. A wheel icon appears in the menu bar.", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.1, alpha: 0.45)])
        note.draw(at: NSPoint(x: (size.width - note.size().width) / 2, y: 48))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
