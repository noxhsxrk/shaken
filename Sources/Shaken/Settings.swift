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
            PacksTab().tabItem { Label(L("Packs"), systemImage: "shippingbox") }
            GeneralTab().tabItem { Label(L("General"), systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - Wheel (R3)

struct WheelTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var selected: String?
    @State private var selectedChild: String?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack {
                WheelPreview(slots: model.settings.slots, selected: $selected) { a, b in
                    model.update { s in
                        guard let i = s.slots.firstIndex(where: { $0.id == a }), let j = s.slots.firstIndex(where: { $0.id == b }) else { return }
                        s.slots.swapAt(i, j)
                    }
                }
                Text(L("Drag one slot onto another to swap them. Positions stay fixed so your hand can learn them."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 280)
                Button(L("Reset to Suggestions")) { model.update { $0.slots = ShakenSettings.defaultSlots() } }
                    .padding(.top, 6)
            }
            Divider()
            if let id = selected, let i = model.settings.slots.firstIndex(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("Slot %@", String(i + 1))).font(.headline)
                        SlotFields(slot: slotBinding(i), actions: model.actions, allowSubmenu: true)
                        if model.settings.slots[i].kind == .submenu {
                            Divider()
                            ChildrenEditor(parent: i, selected: $selectedChild)
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
        .onAppear { if selected == nil { selected = model.settings.slots.first?.id } }
    }

    func slotBinding(_ i: Int) -> Binding<Slot> {
        Binding(get: { model.settings.slots.indices.contains(i) ? model.settings.slots[i] : Slot(kind: .empty) },
                set: { v in model.update { if $0.slots.indices.contains(i) { $0.slots[i] = v } } })
    }
}

struct ChildrenEditor: View {
    @EnvironmentObject var model: SettingsModel
    let parent: Int
    @Binding var selected: String?

    var children: [Slot] { model.settings.slots.indices.contains(parent) ? model.settings.slots[parent].children : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Submenu items")).font(.subheadline.bold())
                Spacer()
                Button {
                    model.update { $0.slots[parent].children.append(Slot(kind: .auto)) }
                } label: { Image(systemName: "plus") }
                    .disabled(children.count >= ShakenSettings.maxChildren)
                    .help(L("Add item"))
            }
            ForEach(Array(children.enumerated()), id: \.element.id) { j, child in
                DisclosureGroup(isExpanded: Binding(get: { selected == child.id }, set: { selected = $0 ? child.id : nil })) {
                    SlotFields(slot: Binding(
                        get: { model.settings.slots[parent].children.indices.contains(j) ? model.settings.slots[parent].children[j] : child },
                        set: { v in model.update { if $0.slots[parent].children.indices.contains(j) { $0.slots[parent].children[j] = v } } }
                    ), actions: model.actions, allowSubmenu: false)
                    .padding(.leading, 8)
                } label: {
                    HStack {
                        Image(systemName: child.icon.isEmpty ? "circle.dashed" : child.icon)
                        Text(child.title.isEmpty ? kindTitle(child.kind) : child.title)
                        Spacer()
                        Button(role: .destructive) {
                            model.update { $0.slots[parent].children.removeAll { $0.id == child.id } }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help(L("Remove"))
                    }
                }
            }
        }
    }
}

func kindTitle(_ k: SlotKind) -> String {
    switch k {
    case .auto: return L("Suggested command")
    case .empty: return L("Empty")
    case .app: return L("App")
    case .web: return L("Website")
    case .folder: return L("Folder")
    case .action: return L("Command")
    case .submenu: return L("Submenu")
    }
}

struct SlotFields: View {
    @Binding var slot: Slot
    let actions: [ActionManifest]
    let allowSubmenu: Bool

    var body: some View {
        Form {
            Picker(L("Shows"), selection: $slot.kind) {
                ForEach(SlotKind.allCases.filter { allowSubmenu || $0 != .submenu }, id: \.self) { Text(kindTitle($0)).tag($0) }
            }
            if slot.kind == .auto {
                Text(L("Filled with a command that fits what you're dragging.")).font(.caption).foregroundStyle(.secondary)
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
                    Button(L("Choose App…")) { if let u = choose(app: true) { slot.target = u.path } }
                }
                Text(L("Dropped files or links open in this app.")).font(.caption).foregroundStyle(.secondary)
            case .web:
                TextField(L("Address"), text: $slot.target, prompt: Text("https://www.google.com/search?q={query}"))
                Text(L("{query} is replaced with the dragged text or link.")).font(.caption).foregroundStyle(.secondary)
            case .folder:
                HStack {
                    Text(slot.target.isEmpty ? L("No folder chosen") : slot.target).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Choose Folder…")) { if let u = choose(app: false) { slot.target = u.path } }
                }
                Text(L("Dropped files are copied here (undoable)."))
                    .font(.caption).foregroundStyle(.secondary)
            case .action:
                Picker(L("Command"), selection: $slot.target) {
                    Text(L("Choose…")).tag("")
                    ForEach(actions) { a in Text(a.displayName).tag(a.id) }
                }
            default:
                EmptyView()
            }
        }
    }

    func choose(app: Bool) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = !app
        p.canChooseFiles = app
        if app {
            p.allowedContentTypes = [.application]
            p.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        return p.runModal() == .OK ? p.url : nil
    }
}

struct WheelPreview: View {
    let slots: [Slot]
    @Binding var selected: String?
    let swap: (String, String) -> Void

    var body: some View {
        ZStack {
            Circle().fill(.quaternary).frame(width: 280, height: 280)
            Circle().fill(.background).frame(width: 90, height: 90)
            Text(L("Dragged item")).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, s in
                let angle = (90 - Double(i) * 60) * .pi / 180
                SlotBubble(slot: s, isSelected: selected == s.id)
                    .offset(x: cos(angle) * 95, y: -sin(angle) * 95)
                    .onTapGesture { selected = s.id }
                    .onDrag { NSItemProvider(object: s.id as NSString) }
                    .onDrop(of: [.plainText], isTargeted: nil) { providers in
                        providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                            if let from = obj as? String, from != s.id {
                                DispatchQueue.main.async { swap(from, s.id); selected = s.id }
                            }
                        }
                        return true
                    }
            }
        }
        .frame(width: 290, height: 290)
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
        case .app: return "app"
        case .web: return "globe"
        case .folder: return "folder"
        case .action: return "bolt"
        case .submenu: return "circle.grid.2x2"
        }
    }

    var title: String {
        if !slot.title.isEmpty { return slot.title }
        switch slot.kind {
        case .app, .folder: return slot.target.isEmpty ? kindTitle(slot.kind) : URL(fileURLWithPath: slot.target).deletingPathExtension().lastPathComponent
        case .web: return URL(string: slot.target)?.host ?? kindTitle(slot.kind)
        default: return kindTitle(slot.kind)
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18))
            Text(title).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 76, height: 62)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
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
                    } minimumValueLabel: { Text(L("Firm")) } maximumValueLabel: { Text(L("Light")) }
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
                Picker(L("Keyboard shortcut"), selection: Binding(
                    get: { HotKeySetting.presets.firstIndex(of: model.settings.hotKey) ?? 0 },
                    set: { i in model.update { $0.hotKey = HotKeySetting.presets[i] } })) {
                    ForEach(Array(HotKeySetting.presets.enumerated()), id: \.offset) { i, p in
                        Text(p.keyCode == nil ? L("None") : p.display).tag(i)
                    }
                }
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

struct ActionsTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var kind: KindKey = .image

    var ordered: [ActionManifest] {
        ActionResolver.ordered(for: ActionResolver.samplePayload(for: kind), actions: model.actions, settings: model.settings, includeHidden: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L("When dragging"), selection: $kind) {
                    ForEach(KindKey.allCases.filter { $0 != .none }, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 320)
                Spacer()
                Button(L("Reset Order")) { model.update { $0.kindPreferences[kind.rawValue] = nil } }
            }
            Text(L("Suggested slots are filled from the top of this list. Untick to hide a command for this kind."))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, a in
                    HStack {
                        Toggle("", isOn: Binding(get: { !model.settings.preference(for: kind).hidden.contains(a.id) },
                                                 set: { on in setHidden(a.id, !on) })).labelsHidden()
                        Image(systemName: a.icon).frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(a.displayName)
                            Text(sourceLabel(a)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !a.missingRequirements().isEmpty {
                            Text(L("Install: %@", a.installHint)).font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == ordered.count - 1)
                    }
                }
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
    }

    func sourceLabel(_ a: ActionManifest) -> String {
        switch a.source {
        case .builtin: return L("Built in")
        case .local: return L("Your command") + " · " + (a.directory?.lastPathComponent ?? "")
        case .pack(let n): return L("Pack: %@", n)
        }
    }

    func setHidden(_ id: String, _ hide: Bool) {
        model.update { s in
            var p = s.preference(for: kind)
            p.hidden.removeAll { $0 == id }
            if hide { p.hidden.append(id) }
            s.kindPreferences[kind.rawValue] = p
        }
    }

    func move(_ i: Int, _ d: Int) {
        var ids = ordered.map(\.id)
        let j = i + d
        guard ids.indices.contains(j) else { return }
        ids.swapAt(i, j)
        model.update { s in
            var p = s.preference(for: kind)
            p.order = ids
            s.kindPreferences[kind.rawValue] = p
        }
    }
}

// MARK: - Packs (R9)

struct PacksTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var url = ""

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
            List {
                ForEach(model.packs) { pack in
                    Section {
                        ForEach(model.actions.filter { $0.source == .pack(pack.name) }) { a in
                            HStack {
                                Image(systemName: a.icon).frame(width: 20)
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
                            Button(L("Remove"), role: .destructive) { model.removePack(pack) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var launchAtLogin = false

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        Form {
            Toggle(L("Open at login"), isOn: Binding(get: { launchAtLogin }, set: { v in model.app.launchAtLogin = v; launchAtLogin = model.app.launchAtLogin }))
            LabeledContent(L("Version"), value: version)
            LabeledContent(L("License"), value: "MIT")
            LabeledContent(L("Language"), value: L("Follows your macOS language (English, ไทย)"))
            Text(L("Shaken needs no special permissions. It watches the mouse with a standard monitor and only reads what you drag after you shake."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.app.launchAtLogin }
    }
}
