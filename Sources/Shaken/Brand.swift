import AppKit
import SwiftUI
import ShakenCore

/// Colours and artwork from the Shaken asset kit. The glyphs, menu bar template and app icon live in Resources/.
enum Brand {
    // MARK: colours

    /// Shaken's own periwinkle (#7D89ED): the app icon, the installer and the "Shaken blue" glass.
    static let brandAccent = NSColor(srgbRed: 0x7D / 255, green: 0x89 / 255, blue: 0xED / 255, alpha: 1)

    /// The glass colour setting. AppController points this at the settings store.
    static var look: () -> (tint: GlassTint, hex: String, strength: Double) = { (.system, GlassTint.shakenHex, 0.5) }

    /// The accent for the wheel, chip, shelf and Settings: the Mac's accent colour, Shaken blue or a custom one.
    static var accent: NSColor {
        let l = look()
        switch l.tint {
        case .shaken: return brandAccent
        case .custom:
            guard let c = GlassTint.rgb(fromHex: l.hex) else { return brandAccent }
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        case .system:
            return NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? brandAccent
        }
    }

    /// Text and icons on a selected (accent) tile: white while it has at least 3:1 contrast
    /// (WCAG for bold and large text), dark on light accents such as yellow, orange or green.
    static var onAccent: NSColor {
        guard let c = accent.usingColorSpace(.sRGB) else { return .white }
        func lin(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        return 1.05 / (lum + 0.05) >= 3 ? .white : lightText
    }
    static var onAccentColor: Color { Color(nsColor: onAccent) }

    /// How strongly unselected glass takes the accent, 0–1.
    static var tintStrength: CGFloat { CGFloat(look().strength) }
    static let darkSurface = NSColor(srgbRed: 0x20 / 255, green: 0x28 / 255, blue: 0x3D / 255, alpha: 1)   // #20283D
    static let lightSurface = NSColor(srgbRed: 0xF5 / 255, green: 0xF7 / 255, blue: 0xFF / 255, alpha: 1)  // #F5F7FF
    static let darkText = NSColor(srgbRed: 0xF4 / 255, green: 0xF5 / 255, blue: 0xFF / 255, alpha: 1)      // #F4F5FF
    static let lightText = NSColor(srgbRed: 0x18 / 255, green: 0x20 / 255, blue: 0x35 / 255, alpha: 1)     // #182035
    static let darkStroke = NSColor(srgbRed: 0xC5 / 255, green: 0xD2 / 255, blue: 0xFF / 255, alpha: 0.22) // #C5D2FF @ 22%
    static let lightStroke = NSColor(srgbRed: 0x67 / 255, green: 0x72 / 255, blue: 0x8E / 255, alpha: 0.22) // #67728E @ 22%
    static let night = NSColor(srgbRed: 0x12 / 255, green: 0x18 / 255, blue: 0x29 / 255, alpha: 1)         // backdrop #121829

    static var accentColor: Color { Color(nsColor: accent) }

    /// Wheel, chip and tray surfaces, following light and dark mode.
    static func surface(dark: Bool) -> NSColor { (dark ? darkSurface : lightSurface).withAlphaComponent(0.94) }
    static func stroke(dark: Bool) -> NSColor { dark ? darkStroke : lightStroke }
    static func text(dark: Bool) -> NSColor { dark ? darkText : lightText }

    /// Draw over NSVisualEffectView, retaining the backdrop instead of painting it opaque.
    /// Snapshot callers get a deterministic gradient even without a WindowServer backdrop.
    static func drawGlass(_ path: NSBezierPath, dark: Bool, selected: Bool = false) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || contrast
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let top: NSColor
        let bottom: NSColor
        let a = accent
        // Neutral glass, pulled toward the accent by the strength setting.
        let pull = 0.42 * tintStrength
        func mix(_ base: NSColor, _ amount: CGFloat, alpha: CGFloat) -> NSColor {
            (base.blended(withFraction: amount, of: a) ?? base).withAlphaComponent(alpha)
        }
        if selected {
            top = (a.blended(withFraction: 0.3, of: .white) ?? a).withAlphaComponent(0.98)
            bottom = (a.blended(withFraction: 0.1, of: .black) ?? a).withAlphaComponent(0.98)
        } else if dark {
            top = mix(NSColor(srgbRed: 0.27, green: 0.28, blue: 0.31, alpha: 1), pull, alpha: opaque ? 1 : 0.52)
            bottom = mix(NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1), pull * 0.8, alpha: opaque ? 1 : 0.72)
        } else {
            top = mix(.white, pull * 0.25, alpha: opaque ? 1 : 0.64)
            bottom = mix(NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1), pull, alpha: opaque ? 1 : 0.62)
        }
        NSGradient(starting: bottom, ending: top)?.draw(in: path, angle: 90)
        if !opaque {
            // Broad light falloff rather than a flat coloured tile.
            NSGradient(starting: NSColor.white.withAlphaComponent(selected ? 0.22 : 0.13),
                       ending: NSColor.white.withAlphaComponent(0))?
                .draw(in: path, relativeCenterPosition: NSPoint(x: -0.6, y: 1))
        }
        path.lineWidth = contrast ? 1.4 : (selected ? 1.15 : 0.8)
        (contrast ? text(dark: dark) : NSColor.white.withAlphaComponent(selected ? 0.72 : (dark ? 0.30 : 0.68))).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: glyphs

    /// Icon names that start with this use a Shaken glyph instead of an SF Symbol ("glyph:Convert").
    static let glyphPrefix = "glyph:"
    static let glyphNames = ["Backup", "Calendar", "ChevronRight", "Close", "Compress", "Convert", "CopyName", "Downloads",
                             "Keyboard", "Link", "Metadata", "Mute", "Preview", "Shelf", "Stack", "SwitchApp"]

    private static var cache: [String: NSImage] = [:]

    /// A glyph as a template image (tint it when drawing). Looks in the app bundle, then in
    /// `Resources/` of the source tree so debug builds and snapshots find them too.
    static func glyph(_ name: String) -> NSImage? {
        if let img = cache[name] { return img }
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Glyphs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Glyphs/\(name).pdf"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    /// The glyph tinted with `color`, at `side` points.
    static func tinted(_ name: String, color: NSColor, side: CGFloat) -> NSImage? {
        guard let g = glyph(name) else { return nil }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            g.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    /// The menu bar icon from the kit: a template image, 18 pt.
    static func menuBarImage() -> NSImage {
        let candidates = [
            Bundle.main.url(forResource: "ShakenMenuBarTemplate", withExtension: "pdf"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/ShakenMenuBarTemplate.pdf"),
        ].compactMap { $0 }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            img.accessibilityDescription = "Shaken"
            return img
        }
        return Logo.menuBarImage()
    }
}

/// The kit's panel surface (navy in dark mode, pale blue-white in light) with its hairline edge,
/// placed over the blur so chips and trays match the wheel.
final class BrandSurfaceView: NSView {
    var cornerRadius: CGFloat = 16 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        Brand.drawGlass(shape, dark: dark)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
