import AppKit
import ShakenCore

/// Right-click a slot on the open wheel to choose the command it shows, right there.
extension AppController {
    func wheel(didRightClickSlotAt index: Int, menuHost view: NSView, at point: NSPoint) {
        guard let menu = slotMenu(forSlotAt: index) else { return }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// The right-click menu for a slot of the open wheel (nil while dragging).
    func slotMenu(forSlotAt index: Int) -> NSMenu? {
        guard wheel.mode == .click, pages.indices.contains(pageIndex) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(header(L("Slot %@", String(index + 1))))
        // Commands are chosen per kind of item; say which, so a change here isn't expected elsewhere.
        if !clickPayload.isEmpty {
            menu.addItem(note(L("For: %@", clickPayload.kindKey.title)))
        }

        guard let wheelSlots = pages[pageIndex].slots else {
            // Running apps: filled by macOS, nothing to choose.
            menu.addItem(note(L("This wheel shows your running apps.")))
            return menu
        }
        let resolved = layoutPage(pageIndex)
        if ActionResolver.suggestedIndex(ofSlot: index, in: wheelSlots) != nil {
            let pinned = ActionResolver.pinnedActionIDs(wheelSlots)
            let commands = ActionResolver.ordered(for: clickPayload, actions: clickActions, settings: store.settings, includeHidden: true)
                .filter { !pinned.contains($0.id) }
            if commands.isEmpty {
                menu.addItem(note(L("Put something on the shelf or copy something, and the commands for it show here.")))
            }
            for a in commands {
                let shownAt = resolved.firstIndex { $0.actionID == a.id }
                let item = ClosureMenuItem(title: a.displayName) { [weak self] in self?.place(a.id, inSlot: index, wheel: wheelSlots) }
                item.image = Self.menuIcon(a.icon)
                if shownAt == index {
                    item.state = .on
                } else if let k = shownAt {
                    item.toolTip = L("Swaps it with slot %@", String(k + 1))
                    item.attributedTitle = Self.titled(a.displayName, note: L("Slot %@", String(k + 1)))
                }
                menu.addItem(item)
            }
        } else {
            let title = resolved.indices.contains(index) ? resolved[index].title : ""
            menu.addItem(note(title.isEmpty ? L("This slot is set in Settings.") : L("This slot always shows “%@”.", title)))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Edit Wheels in Settings…")) { [weak self] in
            self?.closeWheel()
            self?.openSettings()
        })
        return menu
    }

    private func place(_ id: String, inSlot i: Int, wheel slots: [Slot]) {
        store.update { s in
            ActionResolver.place(id, inSlot: i, payload: clickPayload, wheel: slots, actions: clickActions,
                                 allActions: registry.actions, settings: &s)
        }
        cachedLayout = nil
        guard wheel.isVisible else { return }
        wheel.replace(slots: layoutPage(pageIndex), summary: clickSummary, shelfCount: shelf.items.count, page: pageLabel)
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
        i.isEnabled = false
        return i
    }

    private func note(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private static func titled(_ title: String, note: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        s.append(NSAttributedString(string: "  " + note, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    /// A 16 pt template icon from an SF Symbol or one of Shaken's glyphs.
    static func menuIcon(_ name: String) -> NSImage? {
        if name.hasPrefix(Brand.glyphPrefix), let g = Brand.glyph(String(name.dropFirst(Brand.glyphPrefix.count))) {
            let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in g.draw(in: r); return true }
            img.isTemplate = true
            return img
        }
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
