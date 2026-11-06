import AppKit
import SwiftUI

/// Colours and artwork from the Shaken asset kit (ShakenAssets/README.md).
enum Brand {
    // MARK: colours

    static let accent = NSColor(srgbRed: 0x7D / 255, green: 0x89 / 255, blue: 0xED / 255, alpha: 1)        // #7D89ED
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
        Brand.surface(dark: dark).setFill()
        shape.fill()
        Brand.stroke(dark: dark).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
