import Foundation

/// A wheel slot after deciding what it shows for this particular drag.
public struct ResolvedSlot: Equatable, Identifiable {
    public var id: String
    public var kind: SlotKind
    public var title: String
    public var icon: String
    public var target: String
    public var actionID: String?
    public var enabled: Bool
    /// Shown under the title, e.g. how to install a missing tool.
    public var note: String?
    public var children: [ResolvedSlot]

    public init(id: String, kind: SlotKind, title: String, icon: String, target: String, actionID: String? = nil,
                enabled: Bool = true, note: String? = nil, children: [ResolvedSlot] = []) {
        self.id = id; self.kind = kind; self.title = title; self.icon = icon; self.target = target
        self.actionID = actionID; self.enabled = enabled; self.note = note; self.children = children
    }
}

/// Filters actions by what is dragged and lays out the wheel (R5).
/// The result is computed once per drag and kept, so positions never move mid-drag.
public enum ActionResolver {
    /// Matching actions in the user's order for this kind, hidden ones removed.
    public static func suggestions(for payload: DragPayload, actions: [ActionManifest], settings: ShakenSettings) -> [ActionManifest] {
        ordered(for: payload, actions: actions, settings: settings, includeHidden: false)
    }

    /// Matching actions in the user's order; `includeHidden` is for the settings screen.
    public static func ordered(for payload: DragPayload, actions: [ActionManifest], settings: ShakenSettings, includeHidden: Bool) -> [ActionManifest] {
        guard !payload.isEmpty else { return [] }
        let pref = settings.preference(for: payload.kindKey)
        let hidden = includeHidden ? [] : Set(pref.hidden)
        let matching = actions.filter { $0.accepts(payload) && !hidden.contains($0.id) }
        let rank = Dictionary(pref.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return matching.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Commands the user put on a slot (or inside a submenu) themselves. Suggestions skip them.
    public static func pinnedActionIDs(_ wheel: [Slot]) -> Set<String> {
        var pinned = Set<String>()
        for s in wheel {
            if s.kind == .action { pinned.insert(s.target) }
            for c in s.children where c.kind == .action { pinned.insert(c.target) }
        }
        return pinned
    }

    /// Which Suggested slot this is, counting only Suggested slots: 0 for the first one.
    public static func suggestedIndex(ofSlot i: Int, in wheel: [Slot]) -> Int? {
        guard wheel.indices.contains(i), wheel[i].kind == .auto else { return nil }
        return wheel[..<i].filter { $0.kind == .auto }.count
    }

    /// Makes slot `slot` of `wheel` (a Suggested slot) show `actionID` for items like `payload`.
    /// It swaps places with the command the slot shows now, in the full order for this kind, so
    /// every other command keeps its exact rank: other items of the same kind (a JPG and a HEIC,
    /// two PDFs and a folder…) see the same swap and nothing else. A hidden command is shown again.
    /// - Parameters:
    ///   - actions: the commands the wheel offers (for the clipboard, without the copy-text ones).
    ///   - allActions: every command, so ones `actions` leaves out keep their rank. Defaults to `actions`.
    public static func place(_ actionID: String, inSlot slot: Int, payload: DragPayload, wheel: [Slot],
                             actions: [ActionManifest], allActions: [ActionManifest]? = nil, settings: inout ShakenSettings) {
        let kind = payload.kindKey
        guard kind != .none, suggestedIndex(ofSlot: slot, in: wheel) != nil else { return }
        let resolved = layout(payload: payload, actions: actions, settings: settings, slots: wheel)
        let current = resolved.indices.contains(slot) ? resolved[slot].actionID : nil
        guard current != actionID else { return }

        var pref = settings.preference(for: kind)
        let wasHidden = pref.hidden.contains(actionID)
        pref.hidden.removeAll { $0 == actionID }
        // The full ranking the resolver uses: the saved order, then everything else in registry order.
        var ids: [String] = []
        for id in pref.order + (allActions ?? actions).map(\.id) where !ids.contains(id) { ids.append(id) }
        guard let from = ids.firstIndex(of: actionID) else { return }
        if let current, let to = ids.firstIndex(of: current) {
            if wasHidden {
                // It wasn't on any slot, so nothing swaps out: it goes in just ahead of this slot's command.
                ids.remove(at: from)
                ids.insert(actionID, at: ids.firstIndex(of: current) ?? to)
            } else {
                ids.swapAt(from, to)
            }
        } else if let last = resolved.compactMap(\.actionID).last(where: { $0 != actionID }),
                  let lastAt = ids.firstIndex(of: last), lastAt > from {
            // The slot was left empty (fewer commands than slots): go right after the last one shown.
            ids.insert(ids.remove(at: from), at: lastAt)
        }
        pref.order = ids
        settings.kindPreferences[kind.rawValue] = pref
    }

    /// The same, on the main wheel, for a typical item of `kind` (the Commands tab in Settings).
    public static func place(_ actionID: String, inSlot slot: Int, for kind: KindKey,
                             actions: [ActionManifest], settings: inout ShakenSettings) {
        place(actionID, inSlot: slot, payload: samplePayload(for: kind), wheel: settings.slots,
              actions: actions, settings: &settings)
    }

    /// A typical payload for each kind, used by Settings to list the actions for that kind.
    public static func samplePayload(for kind: KindKey) -> DragPayload {
        func file(_ name: String, _ type: String) -> DragItem {
            DragItem(kind: .file, url: URL(fileURLWithPath: "/tmp/\(name)"), types: [type], displayName: name)
        }
        switch kind {
        case .image: return DragPayload([file("a.heic", "public.heic")])
        case .jpeg: return DragPayload([file("a.jpg", "public.jpeg")])
        case .pdf: return DragPayload([file("a.pdf", "com.adobe.pdf")])
        case .multiple: return DragPayload([file("a.jpg", "public.jpeg"), file("b.pdf", "com.adobe.pdf")])
        case .folder: return DragPayload([DragItem(kind: .folder, url: URL(fileURLWithPath: "/tmp"), types: ["public.folder"], displayName: "tmp")])
        case .link: return DragPayload([.link(URL(string: "https://example.com")!)])
        case .text: return DragPayload([.text("text")])
        case .file: return DragPayload([file("a.zip", "public.zip-archive")])
        case .none: return DragPayload([])
        }
    }

    /// Places for auto slots that no command fits, so the wheel isn't half empty
    /// when it is opened without dragging anything.
    public static func defaultFallbacks() -> [Slot] {
        [
            Slot(id: "fallback-downloads", kind: .folder, title: L("Downloads"), icon: "glyph:Downloads", target: ShakenPaths.downloads.path),
            Slot(id: "fallback-desktop", kind: .folder, title: L("Desktop"), icon: "menubar.dock.rectangle", target: ShakenPaths.desktop.path),
        ]
    }

    /// Why a slot can't run yet, or nil if it's complete.
    public static func incomplete(_ s: Slot) -> String? {
        let t = s.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.kind.needsTarget && t.isEmpty { return L("Not set up") }
        if s.kind == .keys && KeyCombo(t) == nil { return L("Check the keys") }
        if s.kind == .system && SystemControl(rawValue: t) == nil { return L("Not set up") }
        if s.kind == .delay && Double(t) == nil { return L("Not set up") }
        return nil
    }

    /// - Parameter fallbacks: used, in order, for auto slots left over after the suggestions run out.
    /// - Parameter slots: the wheel to lay out; defaults to the main one (`settings.slots`).
    public static func layout(payload: DragPayload, actions: [ActionManifest], settings: ShakenSettings, fallbacks: [Slot] = [],
                              slots wheelSlots: [Slot]? = nil) -> [ResolvedSlot] {
        let wheel = wheelSlots ?? settings.slots
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Actions the user pinned to a slot shouldn't appear twice.
        let pinned = pinnedActionIDs(wheel)
        var queue = suggestions(for: payload, actions: actions, settings: settings).filter { !pinned.contains($0.id) }[...]
        // Skip fallback places the user already put on the wheel.
        let fixedTargets = Set(wheel.filter { $0.kind == .folder }.map(\.target))
        var spare = fallbacks.filter { !fixedTargets.contains($0.target) }[...]

        let hasFiles = payload.items.contains { [.file, .folder, .promise].contains($0.kind) }
        let hasLink = payload.items.contains { $0.kind == .link }
        let hasText = payload.items.contains { $0.kind == .text }

        func resolve(_ s: Slot) -> ResolvedSlot {
            var r = ResolvedSlot(id: s.id, kind: s.kind, title: s.title, icon: s.icon, target: s.target,
                                 actionID: nil, enabled: true, note: nil, children: [])
            switch s.kind {
            case .empty:
                r.enabled = false
            case .auto:
                if let a = queue.popFirst() {
                    fill(&r, with: a)
                } else if let f = spare.popFirst() {
                    var resolved = resolve(f)
                    resolved.id = s.id
                    return resolved
                } else {
                    r.kind = .empty; r.enabled = false
                }
            case .action:
                if let a = byID[s.target] {
                    fill(&r, with: a)
                    if !s.title.isEmpty { r.title = s.title }
                    if !s.icon.isEmpty { r.icon = s.icon }
                    r.enabled = a.accepts(payload)
                } else {
                    r.enabled = false
                    r.note = L("Action not found")
                    if r.icon.isEmpty { r.icon = "questionmark" }
                }
            case .app:
                if r.title.isEmpty { r.title = URL(fileURLWithPath: s.target).deletingPathExtension().lastPathComponent }
                if r.icon.isEmpty { r.icon = s.target }   // a path: the wheel draws the app's own icon
                r.enabled = payload.isEmpty || hasFiles || hasLink
            case .web:
                if r.title.isEmpty { r.title = URL(string: s.target)?.host ?? s.target }
                if r.icon.isEmpty { r.icon = "globe" }
                r.enabled = payload.isEmpty || !s.target.contains("{query}") || hasLink || hasText
            case .folder:
                if r.title.isEmpty { r.title = URL(fileURLWithPath: s.target).lastPathComponent }
                if r.icon.isEmpty { r.icon = "folder" }
                r.enabled = payload.isEmpty || hasFiles
            case .submenu:
                if r.icon.isEmpty { r.icon = "circle.grid.2x2" }
                r.children = s.children.map(resolve)
                r.enabled = r.children.contains { $0.enabled }
            case .file:
                if r.title.isEmpty { r.title = URL(fileURLWithPath: s.target).lastPathComponent }
                if r.icon.isEmpty { r.icon = s.target }
                r.enabled = payload.isEmpty
            case .shortcut:
                if r.title.isEmpty { r.title = s.target }
                if r.icon.isEmpty { r.icon = "square.2.layers.3d" }
            case .snippet:
                if r.title.isEmpty { r.title = String((s.target.split(whereSeparator: \.isNewline).first.map(String.init) ?? s.target).prefix(30)) }
                if r.icon.isEmpty { r.icon = "text.quote" }
                r.enabled = payload.isEmpty
            case .keys:
                if r.title.isEmpty { r.title = KeyCombo(s.target)?.display ?? s.target }
                if r.icon.isEmpty { r.icon = "glyph:Keyboard" }
                r.enabled = payload.isEmpty
            case .workflow:
                if r.icon.isEmpty { r.icon = "list.bullet.rectangle" }
                if r.title.isEmpty { r.title = L("Workflow") }
                // Steps that aren't filled in yet are skipped when it runs.
                r.children = s.children.filter { Self.incomplete($0) == nil }.map(resolve).map { var c = $0; c.enabled = true; return c }
                r.enabled = payload.isEmpty && !r.children.isEmpty
            case .shell, .applescript:
                if r.title.isEmpty { r.title = s.kind == .shell ? L("Shell script") : L("AppleScript") }
                if r.icon.isEmpty { r.icon = s.kind == .shell ? "terminal" : "applescript" }
            case .system:
                let c = SystemControl(rawValue: s.target)
                if r.title.isEmpty { r.title = c?.title ?? s.target }
                if r.icon.isEmpty { r.icon = c == .mute ? "glyph:Mute" : (c?.icon ?? "gearshape") }
                r.enabled = payload.isEmpty
            case .delay:
                r.title = L("Wait %@ s", s.target)
                r.icon = "hourglass"
                r.enabled = false
            case .switcher:
                // Children (the running apps) are filled in by the app when the wheel opens.
                if r.icon.isEmpty { r.icon = "glyph:SwitchApp" }
                if r.title.isEmpty { r.title = L("Switch app") }
                r.enabled = payload.isEmpty || hasFiles
            }
            if r.enabled, let problem = Self.incomplete(s) {
                r.enabled = false
                r.note = problem
            }
            return r
        }

        func fill(_ r: inout ResolvedSlot, with a: ActionManifest) {
            r.kind = .action
            r.actionID = a.id
            r.title = a.displayName
            r.icon = a.icon
            r.target = a.id
            let missing = a.missingRequirements()
            if !missing.isEmpty { r.note = L("Install: %@", a.installHint) }
        }

        return wheel.map(resolve)
    }
}
