import AppKit
import QuickLookThumbnailing
import ShakenCore

protocol ChipDelegate: AnyObject {
    func chipUndo()
    func chipClose()
}

/// The result chip (R6): appears under the pointer, can be dragged straight
/// into the next app, and carries the undo button (R7).
final class ChipController {
    enum State {
        case running(String)
        case done(JobResult)
        case failed(String)
    }

    weak var delegate: ChipDelegate?
    private let panel = FloatingPanel(size: NSSize(width: 300, height: 64))
    let view = ChipView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
    private let effect = NSVisualEffectView()
    private(set) var state: State?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        effect.frame = view.frame
        effect.material = .hudWindow     // same glass as the wheel and shelf tray
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect
        view.controller = self
    }

    /// Renders `state` and returns the size the chip needs.
    func layout(_ state: State) -> NSSize {
        view.render(state)
        let size = view.fittingSize
        return NSSize(width: max(240, min(size.width, 380)), height: max(56, size.height))
    }

    func cornerRadius(for size: NSSize) -> CGFloat { 14 }

    /// Shows the chip with the thumbnail sitting under the pointer, so a press-and-drag picks it up.
    func show(_ state: State, at point: NSPoint? = nil) {
        self.state = state
        var frame = panel.frame
        frame.size = layout(state)
        effect.layer?.cornerRadius = cornerRadius(for: frame.size)
        if let p = point {
            frame.origin = NSPoint(x: p.x - 30, y: p.y - frame.height / 2)
        } else {
            frame.origin.x = panel.frame.midX - frame.width / 2
            frame.origin.y += panel.frame.height - frame.height
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point ?? frame.origin, $0.frame, false) }) {
            let v = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, v.minX + 4), v.maxX - frame.width - 4)
            frame.origin.y = min(max(frame.origin.y, v.minY + 4), v.maxY - frame.height - 4)
        }
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: true)
        effect.frame = NSRect(origin: .zero, size: frame.size)
        panel.invalidateShadow()
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

    }

    func close() {
        panel.orderOut(nil)
        state = nil
    }

    fileprivate func undoTapped() { delegate?.chipUndo() }
    fileprivate func closeTapped() { delegate?.chipClose() }
}

final class ChipView: NSView, NSDraggingSource {
    weak var controller: ChipController?

    private let thumb = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let undo = NSButton()
    private let closeButton = NSButton()
    private var outputs: [URL] = []
    private var mouseDownPoint: NSPoint?

    private var thumbW: NSLayoutConstraint!
    private var thumbH: NSLayoutConstraint!
    private var row: NSStackView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 7
        thumb.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 230
        detail.cell?.truncatesLastVisibleLine = true
        spinner.style = .spinning
        spinner.controlSize = .small

        for (b, symbol, tip, sel) in [(undo, "arrow.uturn.backward", L("Undo: move results to Trash"), #selector(undoTapped)),
                                      (closeButton, "xmark", L("Close (Esc)"), #selector(closeTapped))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
            b.imagePosition = .imageOnly
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.wantsLayer = true
            b.layer?.cornerRadius = 11
            b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            b.toolTip = tip
            b.target = self
            b.action = sel
            b.setAccessibilityLabel(tip)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        row = NSStackView(views: [thumb, spinner, text, undo, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(6, after: undo)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        thumbW = thumb.widthAnchor.constraint(equalToConstant: 40)
        thumbH = thumb.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbW, thumbH,
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Filled badge symbols: white glyph on a coloured shape.
    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [.white, color])))
    }

    private func setThumb(_ side: CGFloat, scaling: NSImageScaling) {
        thumbW.constant = side
        thumbH.constant = side
        thumb.imageScaling = scaling
    }

    func render(_ state: ChipController.State) {
        outputs = []
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        thumb.isHidden = false
        undo.isHidden = true
        closeButton.isHidden = false
        title.textColor = .labelColor
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        row.edgeInsets = NSEdgeInsets(top: 9, left: 9, bottom: 9, right: 10)
        row.spacing = 10
        setThumb(40, scaling: .scaleProportionallyUpOrDown)
        switch state {
        case .running(let name):
            thumb.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            title.stringValue = name
            detail.stringValue = L("Working… Esc to cancel")
            closeButton.isHidden = true
        case .done(let r):
            outputs = r.outputs
            undo.isHidden = r.outputs.isEmpty
            if r.outputs.count == 1 {
                title.stringValue = r.outputs[0].lastPathComponent
            } else if r.outputs.count > 1 {
                title.stringValue = L("%@ files", String(r.outputs.count))
            } else {
                title.stringValue = r.actionName
            }
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            var d = r.outputs.isEmpty ? (r.message ?? L("Done")) : "\(fmt.string(fromByteCount: r.inputBytes)) → \(fmt.string(fromByteCount: r.outputBytes))"
            if !r.outputs.isEmpty { d += " · " + L("drag me") }
            detail.stringValue = d
            thumb.image = NSWorkspace.shared.icon(forFile: r.outputs.first?.path ?? "/")
            if let first = r.outputs.first { loadThumbnail(first) }
        case .failed(let message):
            setThumb(30, scaling: .scaleNone)
            thumb.image = symbol("exclamationmark.triangle.fill", size: 20, color: .systemOrange)
            row.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 10)
            title.stringValue = L("Didn't work")
            detail.stringValue = message
        }
        detail.isHidden = detail.stringValue.isEmpty
        layoutSubtreeIfNeeded()
    }

    private func loadThumbnail(_ url: URL) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 80, height: 80), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                if self?.outputs.first == url { self?.thumb.image = img }
            }
        }
    }

    @objc private func undoTapped() { controller?.undoTapped() }
    @objc private func closeTapped() { controller?.closeTapped() }

    // MARK: drag out

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard !outputs.isEmpty, let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        let local = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = outputs.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let img = i == 0 ? (thumb.image ?? NSWorkspace.shared.icon(forFile: url.path)) : NSWorkspace.shared.icon(forFile: url.path)
            let off = CGFloat(i) * 6
            item.setDraggingFrame(NSRect(x: local.x - 24 + off, y: local.y - 24 - off, width: 48, height: 48), contents: img)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: the result stays put, so undo and further drags still work.
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

