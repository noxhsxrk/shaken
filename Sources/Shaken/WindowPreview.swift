import AppKit
import ScreenCaptureKit
import ShakenCore

/// Shows a picture of an app's front window next to the wheel while its slot is highlighted
/// in the app switcher. Off by default: it needs Screen Recording permission (macOS 14+).
final class WindowPreviewController {
    private let panel = FloatingPanel(size: NSSize(width: 340, height: 240))
    private let image = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var cache: [pid_t: (NSImage, Date)] = [:]

    init() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        image.imageScaling = .scaleProportionallyDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        for v in [image, title] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(v) }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            image.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            image.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            title.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])
        panel.contentView = effect
    }

    static var isAvailable: Bool { if #available(macOS 14.0, *) { return true } else { return false } }
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt (once) and returns whether access is already granted.
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Previews the running app at `appPath`, beside `wheel`. Hides if there's nothing to show.
    func show(appPath: String, beside wheel: NSRect) {
        task?.cancel()
        guard Self.isAvailable, Self.hasPermission,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == appPath }) else { return hide() }
        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        if let (img, at) = cache[pid], Date().timeIntervalSince(at) < 3 { return present(img, name, beside: wheel) }
        task = Task { @MainActor [weak self] in
            guard #available(macOS 14.0, *), let img = await Self.capture(pid: pid), !Task.isCancelled else { self?.hide(); return }
            self?.cache[pid] = (img, Date())
            self?.present(img, name, beside: wheel)
        }
    }

    func hide() {
        task?.cancel()
        panel.orderOut(nil)
    }

    private func present(_ img: NSImage, _ name: String, beside wheel: NSRect) {
        image.image = img
        title.stringValue = name
        let maxW: CGFloat = 320, maxH: CGFloat = 200
        let scale = min(maxW / max(img.size.width, 1), maxH / max(img.size.height, 1), 1)
        let size = NSSize(width: img.size.width * scale + 20, height: img.size.height * scale + 42)
        var origin = NSPoint(x: wheel.maxX + 10, y: wheel.midY - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(wheel) }) {
            let v = screen.visibleFrame
            if origin.x + size.width > v.maxX { origin.x = wheel.minX - size.width - 10 }   // no room on the right
            origin.y = min(max(origin.y, v.minY + 4), v.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { Motion.fadeIn(panel) }
    }

    /// The app's largest normal on-screen window.
    @available(macOS 14.0, *)
    private static func capture(pid: pid_t) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
        }
        guard let w = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let config = SCStreamConfiguration()
        let scale: CGFloat = 640 / max(w.frame.width, 1)
        config.width = Int(w.frame.width * min(scale, 2))
        config.height = Int(w.frame.height * min(scale, 2))
        config.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w.frame.width, height: w.frame.height))
    }
}
