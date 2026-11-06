import AppKit
import QuickLookThumbnailing
import ShakenCore

protocol ShelfTrayDelegate: AnyObject {
    func shelfTrayDragBegan()
    /// `ids` were dropped somewhere (operation wasn't cancelled).
    func shelfTrayDragEnded(ids: [String], delivered: Bool)
    func shelfTrayRemove(_ ids: [String])
}

/// The shelf, shown under the wheel when it's opened without dragging.
/// Each tile drags out on its own; the first tile drags everything.
final class ShelfTrayController {
    weak var delegate: ShelfTrayDelegate?
    weak var ownDrag: DragMonitor?
    private let panel = FloatingPanel(size: NSSize(width: 360, height: 118))
    let effect = NSVisualEffectView()
    private let surface = BrandSurfaceView()
    private(set) var isDragging = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        surface.frame = effect.bounds
        surface.autoresizingMask = [.width, .height]
        effect.addSubview(surface)
        panel.contentView = effect
    }

    func show(items: [ShelfItem], below wheel: NSRect) {
        guard !items.isEmpty else { return close() }
        let size = build(items: items)
        var origin = NSPoint(x: wheel.midX - size.width / 2, y: wheel.minY - size.height - 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(wheel) }) {
            let v = screen.visibleFrame
            if origin.y < v.minY { origin.y = wheel.maxY + 10 }   // no room below: go above
            origin.x = min(max(origin.x, v.minX + 4), v.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        Motion.fadeIn(panel)
    }

    /// Lays out the tray for `items` and returns the size it needs.
    @discardableResult
    func build(items: [ShelfItem]) -> NSSize {
        effect.subviews.filter { $0 !== surface }.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: L("Shelf"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let count = NSTextField(labelWithString: items.count == 1 ? L("1 item") : L("%@ items", String(items.count)))
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, count])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let clear = NSButton(title: L("Clear"), target: self, action: #selector(clearAll))
        clear.bezelStyle = .roundRect
        clear.controlSize = .small
        clear.font = .systemFont(ofSize: 10, weight: .medium)
        clear.widthAnchor.constraint(equalToConstant: 44).isActive = true

        var tiles: [NSView] = []
        if items.count > 1 { tiles.append(ShelfTileView(items: items, tray: self, isAll: true)) }
        tiles += items.reversed().map { ShelfTileView(items: [$0], tray: self, isAll: false) }
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(row)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            row.topAnchor.constraint(equalTo: doc.topAnchor),
            row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])

        // A single horizontal strip: title/count, separator, draggable items, Clear.
        // Individual tiles and the All tile retain their existing drag lifecycle.
        let stack = NSStackView(views: [header, divider, scroll, clear])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: ShelfTileView.size.height),
        ])
        scroll.setContentHuggingPriority(.init(1), for: .horizontal)
        scroll.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let tilesWidth = CGFloat(tiles.count) * (ShelfTileView.size.width + 4) - 4
        let displayWidth = NSScreen.main?.visibleFrame.width ?? 640
        let width = min(max(tilesWidth + 200, 460), min(640, displayWidth - 16))
        let size = NSSize(width: width, height: 76)

        effect.frame = NSRect(origin: .zero, size: size)
        return size
    }

    func close() {
        guard !isDragging else { return }
        panel.orderOut(nil)
    }

    @objc private func clearAll() { delegate?.shelfTrayRemove([]) }

    fileprivate func remove(_ ids: [String]) { delegate?.shelfTrayRemove(ids) }

    fileprivate func began() { isDragging = true; delegate?.shelfTrayDragBegan() }

    fileprivate func ended(_ ids: [String], delivered: Bool) {
        isDragging = false
        delegate?.shelfTrayDragEnded(ids: ids, delivered: delivered)
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ShelfTileView: NSView, NSDraggingSource {
    static let size = NSSize(width: 118, height: 48)

    let items: [ShelfItem]
    weak var tray: ShelfTrayController?
    let isAll: Bool
    private let image = NSImageView()
    private let removeButton = NSButton()
    private var downAt: NSPoint?
    private var hovering = false { didSet { updateHover() } }

    init(items: [ShelfItem], tray: ShelfTrayController, isAll: Bool) {
        self.items = items
        self.tray = tray
        self.isAll = isAll
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true

        image.frame = NSRect(x: 4, y: 8, width: 32, height: 32)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.masksToBounds = true
        if isAll {
            image.image = Brand.tinted("Stack", color: .white, side: 24) ?? symbol("square.stack.3d.up.fill", size: 24, color: .white)
            image.imageScaling = .scaleNone
            image.layer?.cornerRadius = 12
            image.layer?.backgroundColor = Brand.accent.cgColor
            image.frame = NSRect(x: 4, y: 8, width: 32, height: 32)
        } else {
            image.image = icon(for: items[0])
            if items[0].kind != .file { image.imageScaling = .scaleNone }
        }
        addSubview(image)

        let label = NSTextField(labelWithString: isAll ? L("All %@", String(items.count)) : items[0].title)
        label.font = .systemFont(ofSize: 10.5, weight: isAll ? .semibold : .regular)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = !isAll && items[0].kind == .file ? .byTruncatingMiddle : .byTruncatingTail
        label.frame = NSRect(x: 44, y: 16, width: Self.size.width - 50, height: 16)
        addSubview(label)

        if !isAll {
            removeButton.image = symbol("xmark.circle.fill", size: 15, color: .secondaryLabelColor)
            removeButton.isBordered = false
            removeButton.target = self
            removeButton.action = #selector(removeTapped)
            removeButton.frame = NSRect(x: Self.size.width - 22, y: Self.size.height - 22, width: 20, height: 20)
            removeButton.toolTip = L("Remove from shelf")
            removeButton.setAccessibilityLabel(L("Remove from shelf"))
            removeButton.isHidden = true
            addSubview(removeButton)
            if let f = items[0].fileURL { loadThumbnail(f) }
        }
        toolTip = isAll ? L("Drag everything on the shelf") : items[0].value
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateHover() {
        layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
        removeButton.isHidden = !hovering
    }

    private func symbol(_ name: String, size: CGFloat = 24, color: NSColor = Brand.accent) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color])))
    }

    private func icon(for item: ShelfItem) -> NSImage? {
        switch item.kind {
        case .file: return NSWorkspace.shared.icon(forFile: item.value)
        case .link: return Brand.tinted("Link", color: Brand.accent, side: 26) ?? symbol("link")
        case .text: return symbol("text.alignleft")
        }
    }

    private func loadThumbnail(_ url: URL) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 80, height: 80),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.image.image = img }
        }
    }

    @objc private func removeTapped() { tray?.remove(items.map(\.id)) }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        downAt = nil
        let local = convert(p, from: nil)
        let dragItems: [NSDraggingItem] = items.enumerated().compactMap { i, item in
            let writer: NSPasteboardWriting
            switch item.kind {
            case .file: writer = URL(fileURLWithPath: item.value) as NSURL
            case .link: guard let u = URL(string: item.value) else { return nil }; writer = u as NSURL
            case .text: writer = item.value as NSString
            }
            let d = NSDraggingItem(pasteboardWriter: writer)
            let off = CGFloat(min(i, 4)) * 5
            d.setDraggingFrame(NSRect(x: local.x - 22 + off, y: local.y - 22 - off, width: 44, height: 44),
                               contents: i == 0 && !isAll ? image.image : icon(for: item))
            return d
        }
        guard !dragItems.isEmpty else { return }
        tray?.began()
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy: the shelved file stays where it is. Inside Shaken, the wheel can take it too.
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        tray?.ownDrag?.ownDragBegan()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        tray?.ownDrag?.ownDragMoved(to: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tray?.ended(items.map(\.id), delivered: operation != [])
    }
}
