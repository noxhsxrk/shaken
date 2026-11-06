import AppKit
import ShakenCore
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(app: AppController) {
        model = SettingsModel(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Shaken Settings")
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsModel: ObservableObject {
    let app: AppController
    @Published var settings: ShakenSettings
    @Published var actions: [ActionManifest] = []
    @Published var problems: [LoadProblem] = []
    @Published var packs: [PackManager.Pack] = []
    @Published var packBusy = false
    @Published var packMessage: String?
    /// Which wheel the Wheel tab edits: nil = main, otherwise an app's bundle id.
    @Published var wheelScope: String?

    init(app: AppController) {
        self.app = app
        settings = app.store.settings
        refresh()
    }

    func refresh() {
        app.registry.reload()
        actions = app.registry.actions
        problems = app.registry.problems
        packs = app.packs.packs()
        settings = app.store.settings
    }

    func update(_ change: (inout ShakenSettings) -> Void) {
        app.store.update(change)
        settings = app.store.settings
    }

    /// A binding that writes through the validated store.
    func binding<T>(_ kp: WritableKeyPath<ShakenSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    func installPack(_ url: String) {
        packBusy = true
        packMessage = nil
        Task { @MainActor in
            do {
                let p = try await app.packs.install(url)
                packMessage = L("Installed “%@”. Nothing has run yet — each command asks before its first run.", p.name)
            } catch {
                packMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            packBusy = false
            refresh()
        }
    }

    func updatePack(_ p: PackManager.Pack) {
        packBusy = true
        Task { @MainActor in
            do { try await app.packs.update(p); packMessage = L("Updated “%@”. Changed commands will ask again.", p.name) }
            catch { packMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            packBusy = false
            refresh()
        }
    }

    func removePack(_ p: PackManager.Pack) {
        do {
            try app.packs.uninstall(p)
            update { s in s.approvals = s.approvals.filter { !$0.key.hasPrefix("pack.\(p.name)") } }
            packMessage = L("Removed “%@”.", p.name)
        } catch {
            packMessage = error.localizedDescription
        }
        refresh()
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            WheelTab().tabItem { Label(L("Wheel"), systemImage: "circle.circle") }
            GestureTab().tabItem { Label(L("Gesture"), systemImage: "hand.wave") }
            ActionsTab().tabItem { Label(L("Commands"), systemImage: "bolt") }
            GalleryTab().tabItem { Label(L("Gallery"), systemImage: "square.grid.2x2") }
            PacksTab().tabItem { Label(L("Packs"), systemImage: "shippingbox") }
            GeneralTab().tabItem { Label(L("General"), systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 500)
        .tint(Brand.accentColor)
    }
}

// MARK: - Wheel (R3)

extension SettingsModel {
    // wheelScope: nil = main wheel, "wheel:<id>" = one of your extra wheels, otherwise an app's bundle id.
    static let namedPrefix = "wheel:"

    var editingNamedIndex: Int? {
        guard let scope = wheelScope, scope.hasPrefix(Self.namedPrefix) else { return nil }
        let id = String(scope.dropFirst(Self.namedPrefix.count))
        return settings.wheels.firstIndex { $0.id == id }
    }

    var editingAppID: String? {
        guard let scope = wheelScope, !scope.hasPrefix(Self.namedPrefix), settings.appWheels[scope] != nil else { return nil }
        return scope
    }

    var editingName: String {
        if let i = editingNamedIndex { return settings.wheels[i].name }
        if let id = editingAppID { return settings.appWheels[id]?.name ?? "" }
        return L("Main")
    }

    var editingSlots: [Slot] {
        if let i = editingNamedIndex { return settings.wheels[i].slots }
        if let id = editingAppID, let w = settings.appWheels[id] { return w.slots }
        return settings.slots
    }

    func updateSlots(_ change: @escaping (inout [Slot]) -> Void) {
        let named = editingNamedIndex.map { settings.wheels[$0].id }
        let app = editingAppID
        update { s in
            if let named, let i = s.wheels.firstIndex(where: { $0.id == named }) { change(&s.wheels[i].slots) }
            else if let app, var w = s.appWheels[app] { change(&w.slots); s.appWheels[app] = w }
            else { change(&s.slots) }
        }
    }

    func addBlankWheel() {
        guard settings.wheels.count < ShakenSettings.maxWheels else { return }
        let w = NamedWheel(name: L("Wheel %@", String(settings.wheels.count + 2)))
        update { $0.wheels.append(w) }
        wheelScope = Self.namedPrefix + w.id
    }

    func renameWheel(_ name: String) {
        guard let i = editingNamedIndex else { return }
        let id = settings.wheels[i].id
        update { s in if let j = s.wheels.firstIndex(where: { $0.id == id }) { s.wheels[j].name = name } }
    }

    /// Moves an extra wheel earlier or later in the ⌘← / ⌘→ order.
    func moveWheel(by d: Int) {
        guard let i = editingNamedIndex, settings.wheels.indices.contains(i + d) else { return }
        update { $0.wheels.swapAt(i, i + d) }
    }

    func addAppWheel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        update { s in if s.appWheels[id] == nil { s.appWheels[id] = AppWheel(name: name, slots: s.slots) } }
        wheelScope = id
    }

    func exportWheel() {
        let name = editingName
        let preset = WheelPreset(name: name, app: editingAppID, slots: editingSlots)
        let p = NSSavePanel()
        p.nameFieldStringValue = name + "." + WheelPreset.fileExtension
        p.allowedContentTypes = [UTType(filenameExtension: WheelPreset.fileExtension) ?? .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try preset.encoded().write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    func importWheelFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: WheelPreset.fileExtension) ?? .json, .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { importWheel(try WheelPreset.decode(Data(contentsOf: url))) } catch { NSAlert(error: error).runModal() }
    }

    /// Downloads a gallery wheel and goes through the same review as any import.
    @MainActor func installGalleryWheel(_ e: GalleryIndex.Entry) async {
        do {
            guard let url = URL(string: e.url) else { return }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else {
                throw ShakenError.other(L("Couldn't download the wheel"))
            }
            importWheel(try WheelPreset.decode(data))
        } catch { NSAlert(error: error).runModal() }
    }

    func importWheelFromURL() {
        let alert = NSAlert()
        alert.messageText = L("Import a wheel from a web address")
        alert.informativeText = L("Paste a link to a .shakenwheel file (https only).")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…/My.shakenwheel"
        alert.accessoryView = field
        alert.addButton(withTitle: L("Import"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else { return }
        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else {
                    throw ShakenError.other(L("Couldn't download the wheel"))
                }
                importWheel(try WheelPreset.decode(data))
            } catch { NSAlert(error: error).runModal() }
        }
    }

    /// Shows everything in the wheel that runs code or types, then asks where to put it.
    func importWheel(_ preset: WheelPreset) {
        let alert = NSAlert()
        alert.messageText = L("Import “%@”?", preset.name)
        let risky = preset.sensitiveSlots
        if risky.isEmpty {
            alert.informativeText = L("It only opens apps, files, folders and websites.")
        } else {
            alert.alertStyle = .warning
            alert.informativeText = L("Check these before importing. Scripts run as you and can read and change any of your files.")
            let text = risky.map { slot -> String in
                let head = "[" + kindTitle(slot.kind) + "]" + (slot.title.isEmpty ? "" : " " + slot.title)
                return head + "\n" + slot.target
            }.joined(separator: "\n\n")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
            scroll.hasVerticalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.string = text
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            scroll.documentView = tv
            alert.accessoryView = scroll
        }
        let appName = preset.app.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        // Buttons, in order: [Use in <app>], Add as New Wheel, Replace Main Wheel, Cancel.
        var choices: [() -> Void] = []
        if let appName, let id = preset.app {
            alert.addButton(withTitle: L("Use in %@", appName))
            choices.append { self.update { $0.appWheels[id] = AppWheel(name: appName, slots: preset.slots) }; self.wheelScope = id }
        }
        if settings.wheels.count < ShakenSettings.maxWheels {
            alert.addButton(withTitle: L("Add as New Wheel"))
            choices.append {
                let w = NamedWheel(name: preset.name, slots: preset.slots)
                self.update { $0.wheels.append(w) }
                self.wheelScope = Self.namedPrefix + w.id
            }
        }
        alert.addButton(withTitle: L("Replace Main Wheel"))
        choices.append { self.update { $0.slots = preset.slots }; self.wheelScope = nil }
        alert.addButton(withTitle: L("Cancel"))
        let i = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if choices.indices.contains(i) { choices[i]() }
    }

    func removeWheel() {
        if let i = editingNamedIndex {
            let id = settings.wheels[i].id
            wheelScope = nil
            update { $0.wheels.removeAll { $0.id == id } }
        } else if let id = editingAppID {
            wheelScope = nil
            update { $0.appWheels[id] = nil }
        }
    }
}

struct WheelTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var selected: String?
    @State private var selectedChild: String?
    @State private var confirmingRemove = false

    /// The name of the wheel being edited, for the remove confirmation.
    var editingName: String {
        if let i = model.editingNamedIndex, model.settings.wheels.indices.contains(i) { return model.settings.wheels[i].name }
        if let id = model.editingAppID { return model.settings.appWheels[id]?.name ?? "" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L("Wheel"), selection: $model.wheelScope) {
                    Text(L("Main wheel")).tag(String?.none)
                    if !model.settings.wheels.isEmpty {
                        Divider()
                        ForEach(model.settings.wheels) { w in
                            Text(w.name).tag(String?.some(SettingsModel.namedPrefix + w.id))
                        }
                    }
                    if !model.settings.appWheels.isEmpty {
                        Divider()
                        ForEach(model.settings.appWheels.sorted { $0.value.name < $1.value.name }, id: \.key) { id, w in
                            Text(L("In %@", w.name)).tag(String?.some(id))
                        }
                    }
                }
                .frame(maxWidth: 280)
                Menu(L("Add Wheel")) {
                    Button(L("Blank Wheel")) { model.addBlankWheel() }
                        .disabled(model.settings.wheels.count >= ShakenSettings.maxWheels)
                    Button(L("Wheel for an App…")) { model.addAppWheel() }
                }
                .frame(width: 110)
                if model.wheelScope != nil {
                    Button(L("Remove…"), role: .destructive) { confirmingRemove = true }
                        .confirmationDialog(L("Remove the wheel “%@”?", editingName), isPresented: $confirmingRemove) {
                            Button(L("Remove Wheel"), role: .destructive) { model.removeWheel() }
                        } message: {
                            Text(L("Its slots are deleted. You can't undo this, but you can export it first from Share."))
                        }
                }
                Spacer()
                Menu(L("Share")) {
                    Button(L("Export This Wheel…")) { model.exportWheel() }
                    Divider()
                    Button(L("Import Wheel File…")) { model.importWheelFile() }
                    Button(L("Import Wheel from URL…")) { model.importWheelFromURL() }
                }
                .frame(width: 90)
            }
            if let i = model.editingNamedIndex {
                HStack {
                    TextField(L("Name"), text: Binding(get: { model.settings.wheels.indices.contains(i) ? model.settings.wheels[i].name : "" },
                                                       set: { model.renameWheel($0) }))
                        .frame(maxWidth: 220)
                    HotKeyRecorder(value: Binding(
                        get: { model.settings.wheels.indices.contains(i) ? model.settings.wheels[i].hotKey : .none },
                        set: { v in
                            let id = model.settings.wheels[i].id
                            model.update { s in if let j = s.wheels.firstIndex(where: { $0.id == id }) { s.wheels[j].hotKey = v } }
                        }), defaultValue: .none, placeholder: L("Add shortcut"))
                        .help(L("Opens the wheel straight on this one"))
                    Button { model.moveWheel(by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(i == 0).help(L("Earlier in the ⌘← / ⌘→ order"))
                    Button { model.moveWheel(by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(i == model.settings.wheels.count - 1).help(L("Later in the ⌘← / ⌘→ order"))
                }
            }
            Text(model.wheelScope == nil
                 ? L("Used while dragging, and without dragging in apps that have no wheel of their own.")
                 : model.editingNamedIndex != nil
                 ? L("An extra wheel. Open the wheel without dragging, then flip to it with ⌘← / ⌘→ or a two-finger swipe.")
                 : L("Shown instead of the main wheel when this app is in front and you open the wheel without dragging."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack {
                    WheelPreview(slots: model.editingSlots, selected: $selected) { a, b in
                        model.updateSlots { slots in
                            guard let i = slots.firstIndex(where: { $0.id == a }), let j = slots.firstIndex(where: { $0.id == b }) else { return }
                            slots.swapAt(i, j)
                        }
                    }
                    Text(L("Drag one slot onto another to swap them. Positions stay fixed so your hand can learn them."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 280)
                    Button(L("Reset to Suggestions")) { model.updateSlots { $0 = ShakenSettings.defaultSlots() } }
                        .padding(.top, 6)
                }
                Divider()
                if let id = selected, let i = model.editingSlots.firstIndex(where: { $0.id == id }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(L("Slot %@", String(i + 1))).font(.headline)
                                Spacer()
                                Button(L("Run Now")) { model.app.runFromSettings(model.editingSlots[i]) }
                                    .disabled(![.app, .web, .folder, .file, .shortcut, .snippet, .keys, .workflow, .shell, .applescript, .system, .switcher]
                                        .contains(model.editingSlots[i].kind))
                                    .help(L("Do what clicking this slot does"))
                            }
                            SlotFields(slot: slotBinding(i), actions: model.actions, allowed: SlotKind.wheelKinds)
                            let kind = model.editingSlots[i].kind
                            if kind == .submenu || kind == .workflow {
                                Divider()
                                ChildrenEditor(parent: i, isWorkflow: kind == .workflow, selected: $selectedChild)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(L("Pick a slot to change it."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selected == nil { selected = model.editingSlots.first?.id } }
        .onChange(of: model.wheelScope) { _ in selected = model.editingSlots.first?.id }
    }

    func slotBinding(_ i: Int) -> Binding<Slot> {
        Binding(get: { model.editingSlots.indices.contains(i) ? model.editingSlots[i] : Slot(kind: .empty) },
                set: { v in model.updateSlots { if $0.indices.contains(i) { $0[i] = v } } })
    }
}

/// Submenu items, or a workflow's steps drawn as a flow of cards: drag a card to reorder it,
/// press its play button to try just that step, or Run All to try the whole thing.
struct ChildrenEditor: View {
    @EnvironmentObject var model: SettingsModel
    let parent: Int
    let isWorkflow: Bool
    @Binding var selected: String?
    @State private var dragging: String?
    @State private var dropBefore: String?

    var children: [Slot] { model.editingSlots.indices.contains(parent) ? model.editingSlots[parent].children : [] }
    var limit: Int { isWorkflow ? ShakenSettings.maxWorkflowSteps : ShakenSettings.maxChildren }

    /// Moves the dragged item so it sits before `target` (or at the end when target is nil).
    func move(_ id: String, before target: String?) {
        model.updateSlots { slots in
            guard slots.indices.contains(parent), let from = slots[parent].children.firstIndex(where: { $0.id == id }) else { return }
            let item = slots[parent].children.remove(at: from)
            let to = target.flatMap { t in slots[parent].children.firstIndex { $0.id == t } } ?? slots[parent].children.count
            slots[parent].children.insert(item, at: to)
        }
    }

    func add(_ kind: SlotKind) {
        var slot = Slot(kind: kind)
        if kind == .delay { slot.target = "1" }
        if kind == .system { slot.target = SystemControl.mute.rawValue }
        // Empty targets are cleaned to "Empty" on save, so the new item opens for editing straight away.
        model.updateSlots { $0[parent].children.append(slot) }
        selected = model.editingSlots[parent].children.last?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isWorkflow ? L("Steps, run in order") : L("Submenu items")).font(.subheadline.bold())
                Text("\(children.count)/\(limit)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isWorkflow {
                    Button { model.app.runFromSettings(model.editingSlots[parent]) } label: { Label(L("Run All"), systemImage: "play.fill") }
                        .disabled(children.isEmpty)
                }
                Menu {
                    ForEach(isWorkflow ? SlotKind.workflowSteps : SlotKind.wheelKinds.filter { !$0.isContainer }, id: \.self) { k in
                        Button(kindTitle(k)) { add(k) }
                    }
                } label: { Label(L("Add"), systemImage: "plus") }
                    .fixedSize()
                    .disabled(children.count >= limit)
            }
            if children.isEmpty {
                Text(isWorkflow ? L("Add the first step: an app to open, a link, a Shortcut, a script, keys to press…")
                                : L("Add up to six items. Rest on the slot while dragging, or click it, to open them."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.quaternary))
            }
            ForEach(Array(children.enumerated()), id: \.element.id) { j, child in
                VStack(spacing: 0) {
                    if dropBefore == child.id {
                        RoundedRectangle(cornerRadius: 2).fill(Brand.accentColor).frame(height: 3).padding(.bottom, 4)
                    }
                    card(j, child)
                    if isWorkflow && j < children.count - 1 {
                        Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary).padding(.vertical, 3)
                    }
                }
                .onDrop(of: [.plainText], isTargeted: Binding(get: { dropBefore == child.id }, set: { dropBefore = $0 ? child.id : nil })) { _ in
                    if let d = dragging, d != child.id { move(d, before: child.id) }
                    dragging = nil
                    return true
                }
            }
            if !children.isEmpty {
                // Drop here to move an item to the end.
                Color.clear.frame(height: 14)
                    .overlay(alignment: .top) {
                        if dropBefore == "end" { RoundedRectangle(cornerRadius: 2).fill(Brand.accentColor).frame(height: 3) }
                    }
                    .onDrop(of: [.plainText], isTargeted: Binding(get: { dropBefore == "end" }, set: { dropBefore = $0 ? "end" : nil })) { _ in
                        if let d = dragging { move(d, before: nil) }
                        dragging = nil
                        return true
                    }
            }
        }
    }

    private func card(_ j: Int, _ child: Slot) -> some View {
        let bubble = SlotBubble(slot: child, isSelected: false)
        let expanded = selected == child.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .help(L("Drag to reorder"))
                if isWorkflow {
                    Text("\(j + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Brand.accentColor))
                }
                SlotIcon(name: bubble.icon, size: 14).frame(width: 24)
                    .foregroundStyle(Brand.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bubble.title).lineLimit(1)
                    Text(kindTitle(child.kind)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if child.kind != .delay {
                    Button { model.app.runFromSettings(child) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help(L("Try this step now"))
                }
                Button { selected = expanded ? nil : child.id } label: { Image(systemName: expanded ? "chevron.up" : "slider.horizontal.3") }
                    .buttonStyle(.borderless).help(L("Edit"))
                Button(role: .destructive) {
                    model.updateSlots { $0[parent].children.removeAll { $0.id == child.id } }
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("Remove"))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { selected = expanded ? nil : child.id }
            .onDrag {
                dragging = child.id
                return NSItemProvider(object: child.id as NSString)
            }
            if expanded {
                Divider()
                SlotFields(slot: Binding(
                    get: { model.editingSlots[parent].children.indices.contains(j) ? model.editingSlots[parent].children[j] : child },
                    set: { v in model.updateSlots { if $0[parent].children.indices.contains(j) { $0[parent].children[j] = v } } }
                ), actions: model.actions, allowed: isWorkflow ? SlotKind.workflowSteps : SlotKind.wheelKinds.filter { !$0.isContainer })
                .padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(dragging == child.id ? 0.03 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(expanded ? Brand.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
        .opacity(dragging == child.id ? 0.5 : 1)
    }
}

func kindTitle(_ k: SlotKind) -> String {
    switch k {
    case .auto: return L("Suggested command")
    case .empty: return L("Empty")
    case .app: return L("App")
    case .web: return L("Website")
    case .folder: return L("Folder")
    case .file: return L("File")
    case .action: return L("Command")
    case .submenu: return L("Submenu")
    case .shortcut: return L("Apple Shortcut")
    case .snippet: return L("Text snippet")
    case .keys: return L("Keyboard shortcut")
    case .workflow: return L("Workflow")
    case .switcher: return L("App switcher")
    case .shell: return L("Shell script")
    case .applescript: return L("AppleScript")
    case .system: return L("System control")
    case .delay: return L("Wait")
    }
}

/// An SF Symbol, or a file's own icon when `name` is a path.
struct SlotIcon: View {
    let name: String
    var size: CGFloat = 18
    var body: some View {
        if name.hasPrefix(Brand.glyphPrefix), let g = Brand.glyph(String(name.dropFirst(Brand.glyphPrefix.count))) {
            Image(nsImage: g).renderingMode(.template).resizable().scaledToFit().frame(width: size * 1.25, height: size * 1.25)
        } else if name.hasPrefix("/") {
            Image(nsImage: NSWorkspace.shared.icon(forFile: name)).resizable().frame(width: size * 1.5, height: size * 1.5)
        } else {
            Image(systemName: name).font(.system(size: size))
        }
    }
}

/// A field's hint text: wraps inside the slot editor instead of widening it past the window.
struct Hint: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SlotFields: View {
    @Binding var slot: Slot
    let actions: [ActionManifest]
    let allowed: [SlotKind]
    @State private var shortcutNames: [String] = []

    var body: some View {
        Form {
            Picker(L("Shows"), selection: $slot.kind) {
                ForEach(allowed, id: \.self) { Text(kindTitle($0)).tag($0) }
            }
            if slot.kind == .auto {
                Text(L("Filled with a command that fits what you're dragging. Choose which one in the Commands tab, or right-click the slot on the wheel."))
                    .modifier(Hint()).fixedSize(horizontal: false, vertical: true)
            }
            if slot.kind != .auto && slot.kind != .empty {
                TextField(L("Name"), text: $slot.title, prompt: Text(L("Automatic")))
                HStack {
                    TextField(L("Icon (SF Symbol)"), text: $slot.icon, prompt: Text(L("Automatic")))
                    Image(systemName: slot.icon.isEmpty ? "circle.dashed" : slot.icon).frame(width: 22)
                }
            }
            switch slot.kind {
            case .app:
                HStack {
                    Text(slot.target.isEmpty ? L("No app chosen") : URL(fileURLWithPath: slot.target).deletingPathExtension().lastPathComponent)
                    Spacer()
                    Button(L("Choose App…")) { if let u = choose(.app) { slot.target = u.path } }
                }
                Text(L("Dropped files or links open in this app.")).modifier(Hint())
            case .web:
                TextField(L("Address"), text: $slot.target, prompt: Text("https://www.google.com/search?q={query}"))
                Text(L("{query} is replaced with the dragged text or link.")).modifier(Hint())
            case .folder:
                HStack {
                    Text(slot.target.isEmpty ? L("No folder chosen") : slot.target).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Choose Folder…")) { if let u = choose(.folder) { slot.target = u.path } }
                }
                Text(L("Dropped files are copied here (undoable)."))
                    .modifier(Hint())
            case .file:
                HStack {
                    Text(slot.target.isEmpty ? L("No file chosen") : slot.target).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Choose File…")) { if let u = choose(.file) { slot.target = u.path } }
                }
            case .action:
                Picker(L("Command"), selection: $slot.target) {
                    Text(L("Choose…")).tag("")
                    ForEach(actions) { a in Text(a.displayName).tag(a.id) }
                }
            case .shortcut:
                HStack {
                    TextField(L("Shortcut name"), text: $slot.target)
                    Menu(L("Pick")) {
                        ForEach(shortcutNames, id: \.self) { n in Button(n) { slot.target = n } }
                    }
                    .frame(width: 70)
                    .disabled(shortcutNames.isEmpty)
                }
                .task { shortcutNames = await Shortcuts.list() }
                Text(L("Runs from the Shortcuts app. Things you drag onto it become its input."))
                    .modifier(Hint())
            case .snippet:
                TextEditor(text: $slot.target)
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                Text(L("Pasted where you're typing. Needs Accessibility permission the first time."))
                    .modifier(Hint())
            case .keys:
                HStack {
                    TextField(L("Keys"), text: $slot.target, prompt: Text("cmd+shift+4"))
                    Text(KeyCombo(slot.target)?.display ?? "—").font(.system(.body, design: .rounded)).frame(minWidth: 60)
                }
                Text(L("Pressed in the app in front, e.g. cmd+shift+4, ctrl+opt+t, f5. Needs Accessibility permission the first time."))
                    .modifier(Hint())
            case .shell, .applescript:
                TextEditor(text: $slot.target)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                Text(slot.kind == .shell
                     ? L("Runs with zsh in your home folder. Dragged files are $1, $2…; dragged text is in $SHAKEN_TEXT.")
                     : L("Dragged files are passed to on run argv."))
                    .modifier(Hint())
            case .system:
                Picker(L("Does"), selection: $slot.target) {
                    Text(L("Choose…")).tag("")
                    ForEach(SystemControl.allCases, id: \.rawValue) { c in
                        Label(c.title, systemImage: c.icon).tag(c.rawValue)
                    }
                }
                if SystemControl(rawValue: slot.target)?.needsAccessibility == true {
                    Text(L("Sent as a key press, so it needs Accessibility permission the first time."))
                        .modifier(Hint())
                }
            case .delay:
                TextField(L("Seconds"), text: $slot.target, prompt: Text("0.5"))
            case .workflow:
                Text(L("Runs each step below in order: open apps, links and files, run Shortcuts and scripts, paste text, press keys."))
                    .modifier(Hint())
            case .switcher:
                Text(L("Opens a ring of your recently used apps. Drop files on one to open them in it."))
                    .modifier(Hint())
            default:
                EmptyView()
            }
        }
    }

    enum Pick { case app, folder, file }

    func choose(_ what: Pick) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = what == .folder
        p.canChooseFiles = what != .folder
        if what == .app {
            p.allowedContentTypes = [.application]
            p.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        return p.runModal() == .OK ? p.url : nil
    }
}

/// One tile of the wheel, the same shape as the real one (parallel gaps around a centre disc).
struct WheelTileShape: Shape {
    let index: Int
    let count = ShakenSettings.slotCount

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 2
        let inner: CGFloat = outer * 0.32
        let gap: CGFloat = 4
        let step = 360 / Double(count)
        // SwiftUI's y axis points down, so slot 0 at the top is -90° and slots go clockwise.
        let mid = -90 + Double(index) * step
        func half(_ r: CGFloat) -> Double { asin(Double(gap / 2 / r)) * 180 / .pi }
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .degrees(mid - step / 2 + half(outer)),
                 endAngle: .degrees(mid + step / 2 - half(outer)), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .degrees(mid + step / 2 - half(inner)),
                 endAngle: .degrees(mid - step / 2 + half(inner)), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelPreview: View {
    let slots: [Slot]
    @Binding var selected: String?
    let swap: (String, String) -> Void
    /// False only for rendering a still image (drag and drop can't be rendered offscreen).
    var interactive = true
    @State private var dropTarget: String?
    private let size: CGFloat = 290

    var body: some View {
        ZStack {
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, s in
                let isSel = selected == s.id
                let tile = GlassShape(shape: WheelTileShape(index: i), selected: isSel, highlighted: dropTarget == s.id)
                if !interactive { tile } else {
                tile
                    .contentShape(WheelTileShape(index: i))
                    .onTapGesture { selected = s.id }
                    .onDrag { NSItemProvider(object: s.id as NSString) }
                    .onDrop(of: [.plainText], isTargeted: Binding(get: { dropTarget == s.id }, set: { dropTarget = $0 ? s.id : nil })) { providers in
                        providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                            if let from = obj as? String, from != s.id {
                                DispatchQueue.main.async { swap(from, s.id); selected = s.id }
                            }
                        }
                        return true
                    }
                    .accessibilityElement()
                    .accessibilityLabel(L("Slot %@", String(i + 1)) + ": " + SlotBubble(slot: s, isSelected: isSel).title)
                    .accessibilityAddTraits(isSel ? [.isButton, .isSelected] : .isButton)
                }
                let angle = (90 - Double(i) * 60) * .pi / 180
                let r = (size / 2 - 2) * 0.66
                SlotBubble(slot: s, isSelected: isSel)
                    .offset(x: cos(angle) * r, y: -sin(angle) * r)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            GlassShape(shape: Circle(), selected: false).frame(width: size * 0.31, height: size * 0.31)
            Text(L("Slot 1 is at the top")).font(.system(size: 9)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(width: size * 0.26)
        }
        .frame(width: size, height: size)
    }
}

/// A shape filled with the wheel's glass (the same colours as the real wheel), for Settings previews.
struct GlassShape<S: Shape>: View {
    let shape: S
    var selected = false
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = Brand.glassColors(dark: scheme == .dark, selected: selected)
        shape
            .fill(LinearGradient(colors: [Color(nsColor: c.top), Color(nsColor: c.bottom)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(Color.primary.opacity(highlighted ? 0.12 : 0)))
            // On the window background the glass's white edge disappears, so add a faint dark one.
            .overlay(shape.stroke(Color.primary.opacity(selected ? 0 : 0.10), lineWidth: 1))
            .overlay(shape.stroke(Color(nsColor: c.edge), lineWidth: selected ? 1 : 0.6))
    }
}

struct SlotBubble: View {
    let slot: Slot
    let isSelected: Bool

    var icon: String {
        if !slot.icon.isEmpty { return slot.icon }
        switch slot.kind {
        case .auto: return "sparkles"
        case .empty: return "circle.dashed"
        case .app, .file: return slot.target.isEmpty ? (slot.kind == .app ? "app" : "doc") : slot.target
        case .web: return "globe"
        case .folder: return "folder"
        case .action: return "bolt"
        case .submenu: return "circle.grid.2x2"
        case .shortcut: return "square.2.layers.3d"
        case .snippet: return "text.quote"
        case .keys: return "glyph:Keyboard"
        case .workflow: return "list.bullet.rectangle"
        case .switcher: return "glyph:SwitchApp"
        case .shell: return "terminal"
        case .applescript: return "applescript"
        case .system: return slot.target == SystemControl.mute.rawValue ? "glyph:Mute" : (SystemControl(rawValue: slot.target)?.icon ?? "gearshape")
        case .delay: return "hourglass"
        }
    }

    var title: String {
        if !slot.title.isEmpty { return slot.title }
        switch slot.kind {
        case .app, .folder, .file:
            return slot.target.isEmpty ? kindTitle(slot.kind) : URL(fileURLWithPath: slot.target).deletingPathExtension().lastPathComponent
        case .web: return URL(string: slot.target)?.host ?? kindTitle(slot.kind)
        case .shortcut: return slot.target.isEmpty ? kindTitle(slot.kind) : slot.target
        case .snippet: return slot.target.isEmpty ? kindTitle(slot.kind) : String(slot.target.prefix(24))
        case .keys: return KeyCombo(slot.target)?.display ?? kindTitle(slot.kind)
        case .system: return SystemControl(rawValue: slot.target)?.title ?? kindTitle(slot.kind)
        case .delay: return L("Wait %@ s", slot.target.isEmpty ? "…" : slot.target)
        default: return kindTitle(slot.kind)
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            SlotIcon(name: icon)
                .foregroundStyle(isSelected ? Brand.onAccentColor : (slot.kind == .empty ? Color.secondary : Brand.accentColor))
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Brand.onAccentColor : (slot.kind == .empty ? Color.secondary : Color.primary))
        }
        .frame(width: 80, height: 62)
    }
}

// MARK: - Gallery

struct GalleryTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var index: GalleryIndex?
    @State private var error: String?
    @State private var loading = false
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Wheels and command packs shared by other people. Everything is shown to you before it's added."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Reload")).disabled(loading)
            }
            if loading && index == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(error).foregroundStyle(.secondary)
                    Button(L("Try Again")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let index {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section(L("Wheels"), index.wheels, action: L("Add…")) { e in await model.installGalleryWheel(e) }
                        section(L("Command packs"), index.packs, action: L("Install")) { e in model.installPack(e.url) }
                        if index.packs.isEmpty {
                            Text(L("No command packs yet."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Link(L("Share your own wheel or pack…"), destination: GalleryIndex.submitPage).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { if index == nil { await load() } }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [GalleryIndex.Entry], action: String,
                         run: @escaping (GalleryIndex.Entry) async -> Void) -> some View {
        if !entries.isEmpty {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                ForEach(entries) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: e.icon ?? "circle.circle").font(.system(size: 20)).foregroundStyle(Brand.accentColor)
                            .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 9).fill(Brand.accentColor.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.name).font(.body.weight(.semibold))
                            Text(e.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(L("by %@", e.author)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button(action) {
                            busy = e.id
                            Task { await run(e); busy = nil }
                        }
                        .disabled(busy != nil)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do { index = try await GalleryIndex.fetch() } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Shortcut recorder

/// Click, then press a key combination. Esc cancels, Delete clears.
struct HotKeyRecorder: View {
    @EnvironmentObject var model: SettingsModel
    @Binding var value: HotKeySetting
    let defaultValue: HotKeySetting
    var placeholder = L("None")
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    Text(recording ? L("Press keys…") : (value.isSet ? value.display : placeholder))
                        .font(.system(.body, design: .rounded).weight(value.isSet && !recording ? .semibold : .regular))
                        .foregroundStyle(recording ? Brand.accentColor : (value.isSet ? Color.primary : Color.secondary))
                        .frame(minWidth: 110)
                }
                .accessibilityLabel(L("Keyboard shortcut"))
                .accessibilityValue(value.isSet ? value.display : L("None"))
                if value.isSet && !recording {
                    Button { set(.none) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help(L("Remove shortcut"))
                }
                if defaultValue.isSet && value != defaultValue && !recording {
                    Button(L("Default")) { set(defaultValue) }.buttonStyle(.borderless)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if value.isSet && model.app.failedHotKeys.contains(value.display) {
                Text(L("Another app already uses %@. Pick a different one.", value.display))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        problem = nil
        recording = true
        model.app.suspendHotKeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case 53: stop()                         // Esc
            case 51, 117: set(.none); stop()        // Delete clears
            default:
                var mods: UInt32 = 0
                let f = e.modifierFlags
                if f.contains(.command) { mods |= HotKeySetting.cmd }
                if f.contains(.shift) { mods |= HotKeySetting.shift }
                if f.contains(.option) { mods |= HotKeySetting.option }
                if f.contains(.control) { mods |= HotKeySetting.control }
                switch HotKeySetting.make(keyCode: UInt32(e.keyCode), modifiers: mods) {
                case .success(let hk): set(hk); stop()
                case .failure(let err): problem = err.errorDescription
                }
            }
            return nil   // swallow the key while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; model.app.suspendHotKeys(false) }
    }

    private func set(_ hk: HotKeySetting) {
        value = hk
        problem = nil
        // Validation drops a wheel shortcut that repeats another one; say so instead of failing silently.
        DispatchQueue.main.async {
            if hk.isSet && value != hk { problem = L("%@ is already used by another wheel or the main shortcut.", hk.display) }
        }
    }
}

// MARK: - Gesture (R1, R2)

struct GestureTab: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Shake while dragging")) {
                VStack(alignment: .leading) {
                    Slider(value: Binding(get: { Double(model.settings.gesture.sensitivity) },
                                          set: { v in model.update { $0.gesture.sensitivity = Int(v.rounded()) } }),
                           in: 1...5, step: 1) {
                        Text(L("Sensitivity"))
                    } minimumValueLabel: { Text(L("Firm")).foregroundStyle(.secondary) } maximumValueLabel: { Text(L("Light")).foregroundStyle(.secondary) }
                }
                Picker(L("Also hold"), selection: model.binding(\.gesture.modifier)) {
                    Text(L("Nothing")).tag(ModifierRequirement.none)
                    Text("⌥ Option").tag(ModifierRequirement.option)
                    Text("⇧ Shift").tag(ModifierRequirement.shift)
                    Text("⌃ Control").tag(ModifierRequirement.control)
                    Text("⌘ Command").tag(ModifierRequirement.command)
                }
                Text(L("If the wheel opens by mistake, just move out of it: it closes at once and your drag carries on."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Without dragging")) {
                Toggle(L("⌥ + shake opens the wheel"), isOn: model.binding(\.gesture.optionShakeWithoutDrag))
                Text(L("A bare shake never opens it, because macOS uses that to enlarge the pointer."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("Keyboard shortcut")) {
                    HotKeyRecorder(value: model.binding(\.hotKey), defaultValue: .default)
                }
                Text(L("Click the shortcut, then press the keys you want. Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("App switcher")) {
                Toggle(L("Show window previews"), isOn: Binding(get: { model.settings.windowPreviews }, set: { on in
                    model.update { $0.windowPreviews = on }
                    if on { WindowPreviewController.requestPermission() }
                }))
                .disabled(!WindowPreviewController.isAvailable)
                Text(L("Shows a picture of the app's window while you point at it in the switcher. macOS asks for Screen Recording permission; Shaken only captures that one window, only while the switcher is open, and never saves it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Ignore shakes in these apps")) {
                ExcludedApps()
            }
        }
        .formStyle(.grouped)
    }
}

struct ExcludedApps: View {
    @EnvironmentObject var model: SettingsModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading) {
            List(model.settings.excludedApps, id: \.self, selection: $selection) { id in
                HStack {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(url.deletingPathExtension().lastPathComponent)
                    } else {
                        Text(id)
                    }
                }
            }
            .frame(minHeight: 80)
            HStack {
                Button(L("Add App…")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.application]
                    p.directoryURL = URL(fileURLWithPath: "/Applications")
                    if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier {
                        model.update { $0.excludedApps.append(id) }
                    }
                }
                Button(L("Remove")) {
                    if let s = selection { model.update { $0.excludedApps.removeAll { $0 == s } } }
                }.disabled(selection == nil)
            }
        }
    }
}

// MARK: - Commands (R5, R8)

/// Commands per kind of dragged item, edited on the wheel itself: pick a slot, then the command it shows.
struct ActionsTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var kind: KindKey = .image
    @State private var selected: String?
    @State private var startedOnLastKind = false

    var payload: DragPayload { ActionResolver.samplePayload(for: kind) }

    /// Every command that works on this kind, hidden ones too.
    var commands: [ActionManifest] {
        ActionResolver.ordered(for: payload, actions: model.actions, settings: model.settings, includeHidden: true)
    }

    /// What the main wheel shows while dragging this kind.
    var resolved: [ResolvedSlot] {
        ActionResolver.layout(payload: payload, actions: model.actions, settings: model.settings)
    }

    var previewSlots: [Slot] {
        resolved.map { r in
            Slot(id: r.id, kind: r.kind, title: r.kind == .empty ? L("Nothing") : r.title, icon: r.icon, target: r.target)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L("When dragging"), selection: $kind) {
                    ForEach(KindKey.allCases.filter { $0 != .none && $0 != .jpeg }, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 320)
                Spacer()
                Button(L("Reset to Defaults")) { model.update { $0.kindPreferences[kind.rawValue] = nil } }
            }
            Text(L("The wheel you get when you drag this kind of item. Click a slot, then pick its command."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack {
                    WheelPreview(slots: previewSlots, selected: $selected) { a, b in swapSlots(a, b) }
                    Text(L("Drag one slot onto another to swap them. Two or more items at once use Several items. On the wheel itself, right-click a slot to change it."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 280)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            HStack {
                Text(L("Shrink below"))
                TextField("", value: model.binding(\.shrinkTargetKB), format: .number).frame(width: 80)
                Text("KB")
                Spacer()
                Button(L("Open Commands Folder")) {
                    try? FileManager.default.createDirectory(at: ShakenPaths.actions, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ShakenPaths.actions)
                }
                Button(L("Reload")) { model.refresh() }
            }
            if !model.problems.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(model.problems, id: \.path) { p in
                        Text("⚠︎ \(p.path): \(p.message)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear {
            // Start on what was dragged last, so the wheel here is the one you just saw.
            if !startedOnLastKind {
                startedOnLastKind = true
                if let k = model.app.lastKind, k != .none, k != .jpeg { kind = k }
            }
            if selected == nil { selected = firstSuggested() }
        }
        .onChange(of: kind) { _ in if selected == nil { selected = firstSuggested() } }
    }

    @ViewBuilder var detail: some View {
        let slots = model.settings.slots
        if let id = selected, let i = slots.firstIndex(where: { $0.id == id }) {
            if let m = ActionResolver.suggestedIndex(ofSlot: i, in: slots) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Slot %@", String(i + 1))).font(.headline)
                    Text(L("Pick the command this slot shows."))
                        .font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(commands) { a in row(a, slot: i, suggested: m) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Slot %@", String(i + 1))).font(.headline)
                    Text(L("This slot always shows “%@”. Change it in the Wheel tab, or let it show a command here instead.",
                           SlotBubble(slot: slots[i], isSelected: false).title))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Show a Command Here")) {
                        model.update { s in if s.slots.indices.contains(i) { s.slots[i] = Slot(id: s.slots[i].id, kind: .auto) } }
                    }
                }
            }
        } else {
            Text(L("Pick a slot to change it."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func row(_ a: ActionManifest, slot i: Int, suggested m: Int) -> some View {
        let shownAt = resolved.firstIndex { $0.actionID == a.id }
        let pinned = ActionResolver.pinnedActionIDs(model.settings.slots).contains(a.id)
        let here = shownAt == i
        return Button {
            guard !here else { return }
            model.update { s in ActionResolver.place(a.id, inSlot: i, for: kind, actions: model.actions, settings: &s) }
        } label: {
            HStack {
                SlotIcon(name: a.icon, size: 14).frame(width: 20)
                VStack(alignment: .leading) {
                    Text(a.displayName)
                    Text(sourceLabel(a)).font(.caption2).foregroundStyle(.secondary)
                }
                if !a.missingRequirements().isEmpty {
                    Text(L("Install: %@", a.installHint)).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if here {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.accentColor)
                } else if pinned {
                    Text(L("Set in Wheel tab")).font(.caption).foregroundStyle(.secondary)
                } else if let k = shownAt {
                    Text(L("Slot %@", String(k + 1))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The current choice is highlighted, not greyed out: greyed reads as "can't use".
        .listRowBackground(here ? Brand.accentColor.opacity(0.16) : Color.clear)
        .disabled(pinned)
        .accessibilityValue(here ? L("In this slot") : pinned ? L("Set in Wheel tab")
                            : shownAt.map { L("In slot %@", String($0 + 1)) } ?? "")
        .accessibilityAddTraits(here ? .isSelected : [])
        .help(here ? L("Shown in this slot") : shownAt != nil ? L("Swaps it with what this slot shows") : L("Shows it in this slot"))
    }

    func firstSuggested() -> String? {
        model.settings.slots.first { $0.kind == .auto }?.id ?? model.settings.slots.first?.id
    }

    /// Two Suggested slots swap their commands; anything else swaps the slots on the main wheel.
    func swapSlots(_ a: String, _ b: String) {
        let slots = model.settings.slots
        guard let i = slots.firstIndex(where: { $0.id == a }), let j = slots.firstIndex(where: { $0.id == b }) else { return }
        if ActionResolver.suggestedIndex(ofSlot: j, in: slots) != nil, ActionResolver.suggestedIndex(ofSlot: i, in: slots) != nil,
           let id = resolved[i].actionID {
            model.update { s in ActionResolver.place(id, inSlot: j, for: kind, actions: model.actions, settings: &s) }
        } else {
            model.update { s in s.slots.swapAt(i, j) }
        }
    }

    func sourceLabel(_ a: ActionManifest) -> String {
        switch a.source {
        case .builtin: return L("Built in")
        case .local: return L("Your command") + " · " + (a.directory?.lastPathComponent ?? "")
        case .pack(let n): return L("Pack: %@", n)
        }
    }
}

// MARK: - Packs (R9)

struct PacksTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var url = ""
    @State private var removing: PackManager.Pack?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("Git URL"), text: $url, prompt: Text("https://github.com/someone/shaken-actions.git"))
                Button(L("Install")) { model.installPack(url); url = "" }
                    .disabled(url.isEmpty || model.packBusy)
                if model.packBusy { ProgressView().controlSize(.small) }
            }
            Text(L("Installing only downloads files. Each command shows you its scripts and asks before the first run, and again whenever a file changes."))
                .font(.caption).foregroundStyle(.secondary)
            if let m = model.packMessage { Text(m).font(.callout).textSelection(.enabled) }
            if model.packs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(Brand.accentColor)
                    Text(L("No command packs yet")).font(.headline)
                    Text(L("A pack is a Git repository of commands someone shared. Paste its URL above to install it, or find packs in the Gallery tab."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List {
                ForEach(model.packs) { pack in
                    Section {
                        ForEach(model.actions.filter { $0.source == .pack(pack.name) }) { a in
                            HStack {
                                SlotIcon(name: a.icon, size: 14).frame(width: 20)
                                Text(a.displayName)
                                Spacer()
                                if PackManager.isApproved(a, settings: model.settings) {
                                    Label(L("Allowed"), systemImage: "checkmark.seal").foregroundStyle(.green).font(.caption)
                                } else {
                                    Label(L("Not allowed yet"), systemImage: "lock").foregroundStyle(.secondary).font(.caption)
                                }
                                Button(L("Review…")) {
                                    if ApprovalDialog.ask(for: a, reviewOnly: true) { model.app.approve(a) }
                                    model.refresh()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(pack.name).font(.headline)
                            if let r = pack.remote { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Button(L("Update")) { model.updatePack(pack) }.disabled(model.packBusy)
                            Button(L("Remove…"), role: .destructive) { removing = pack }
                        }
                    }
                }
            }
            }
        }
        .confirmationDialog(L("Remove the pack “%@”?", removing?.name ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("Remove Pack"), role: .destructive) {
                if let p = removing { model.removePack(p) }
                removing = nil
            }
        } message: {
            Text(L("Its commands are removed from your wheels. You can install it again from its URL."))
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var launchAtLogin = false

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var customColor: Binding<Color> {
        Binding(get: {
            let c = GlassTint.rgb(fromHex: model.settings.glassTintHex) ?? (0.49, 0.54, 0.93)
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
        }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            model.update { $0.glassTintHex = GlassTint.hex(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)) }
        })
    }

    var body: some View {
        Form {
            Toggle(L("Open at login"), isOn: Binding(get: { launchAtLogin }, set: { v in model.app.launchAtLogin = v; launchAtLogin = model.app.launchAtLogin }))
            Toggle(L("Check for updates automatically"), isOn: model.binding(\.checkForUpdates))
            LabeledContent(L("Version")) {
                HStack {
                    Text(version)
                    Button(L("Check Now")) { model.app.checkForUpdates() }
                }
            }
            LabeledContent(L("License"), value: "MIT")
            Section(L("Glass")) {
                Picker(L("Color"), selection: model.binding(\.glassTint)) {
                    Text(L("Mac accent color")).tag(GlassTint.system)
                    Text(L("Shaken blue")).tag(GlassTint.shaken)
                    Text(L("Custom")).tag(GlassTint.custom)
                }
                if model.settings.glassTint == .system {
                    Text(L("Follows the accent color in System Settings › Appearance."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.settings.glassTint == .custom {
                    ColorPicker(L("Custom color"), selection: customColor, supportsOpacity: false)
                }
                LabeledContent(L("Tint")) {
                    Slider(value: model.binding(\.glassTintStrength), in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text(L("Grey")).font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text(L("Strong")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L("Preview")) {
                    GlassSwatch(look: "\(model.settings.glassTint.rawValue)\(model.settings.glassTintHex)\(model.settings.glassTintStrength)")
                        .frame(width: 210, height: 56)
                }
            }
            Text(L("Shaken watches the mouse with a standard monitor and only reads what you drag after you shake. Snippets, keyboard shortcuts and a few system controls need Accessibility; nothing else needs special permission."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.app.launchAtLogin }
    }
}

/// Two wheel tiles drawn with the real glass code: one plain, one selected.
struct GlassSwatch: NSViewRepresentable {
    /// Changes whenever the glass setting does, so the swatch redraws.
    let look: String
    func makeNSView(context: Context) -> SwatchView { SwatchView() }
    func updateNSView(_ v: SwatchView, context: Context) { v.needsDisplay = true }

    final class SwatchView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let w = (bounds.width - 10) / 2
            for (i, selected) in [false, true].enumerated() {
                let r = NSRect(x: CGFloat(i) * (w + 10), y: 0, width: w, height: bounds.height).insetBy(dx: 0.5, dy: 0.5)
                Brand.drawGlass(NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12), dark: dark, selected: selected)
            }
        }
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    }
}
