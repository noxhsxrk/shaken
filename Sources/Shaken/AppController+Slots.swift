import AppKit
import ShakenCore

/// Running what a slot holds: commands, apps, folders, Shortcuts, scripts, keys, workflows.
extension AppController {
    // MARK: performing a slot

    func wheel(didDrop slot: ResolvedSlot, pasteboard: NSPasteboard, at point: NSPoint) {
        closeWheel()
        cachedLayout = nil
        chip.show(.running(slot.title), at: point)
        updateEscape()
        DragReader.materialize(pasteboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let input): self.perform(slot, input: input, at: point)
            case .failure(let e): self.fail(e)
            }
        }
    }

    func wheel(didDropOnShelf pasteboard: NSPasteboard, at point: NSPoint) {
        closeWheel()
        cachedLayout = nil
        DragReader.materialize(pasteboard, into: ShakenPaths.shelfFiles) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let input):
                self.shelf.add(input)
                self.updateEscape()
            case .failure(let e):
                self.fail(e)
            }
        }
    }

    func wheel(didClick slot: ResolvedSlot, at point: NSPoint) {
        closeWheel()
        // On the shelf: commands, apps and folders take the shelved items.
        if clickSource == .shelf, [.action, .app, .folder, .shortcut, .shell, .applescript].contains(slot.kind), let input = shelf.jobInput {
            chip.show(.running(slot.title), at: point)
            updateEscape()
            perform(slot, input: input, at: point)
            return
        }
        switch slot.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: slot.target), configuration: .init())
        case .web:
            if let u = URL(string: slot.target.replacingOccurrences(of: "{query}", with: "")) { NSWorkspace.shared.open(u) }
        case .folder, .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: slot.target))
        case .shortcut:
            chip.show(.running(slot.title), at: point)
            updateEscape()
            runShortcut(slot, input: nil)
        case .snippet, .keys:
            guard Typing.ensureTrusted() else { return fail(Typing.notTrustedError) }
            // Let the wheel close so the front app has the keyboard again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.typeSlot(slot) }
        case .shell, .applescript:
            chip.show(.running(slot.title), at: point)
            updateEscape()
            runScript(slot, input: nil)
        case .system:
            guard let c = SystemControl(rawValue: slot.target) else { return }
            Task { @MainActor in
                // Let the wheel close first so key presses reach the app in front.
                try? await Task.sleep(nanoseconds: 80_000_000)
                do { try await SystemActions.perform(c) } catch { self.fail(error) }
            }
        case .workflow:
            runWorkflow(slot.children, at: point)
        case .action:
            chip.show(.running(slot.title), at: point)
            updateEscape()
            DragReader.materialize(NSPasteboard.general) { [weak self] result in
                switch result {
                case .success(let input): self?.perform(slot, input: input, at: point)
                case .failure(let e): self?.fail(e)
                }
            }
        default:
            break
        }
    }

    func perform(_ slot: ResolvedSlot, input: JobInput, at point: NSPoint) {
        switch slot.kind {
        case .action:
            guard let id = slot.actionID ?? Optional(slot.target), let action = registry.action(id: id) else {
                return fail(ShakenError.other(L("Action not found")))
            }
            if PackManager.needsApproval(action) && !PackManager.isApproved(action, settings: store.settings) {
                chip.close()
                guard ApprovalDialog.ask(for: action) else { updateEscape(); return }
                approve(action)
                chip.show(.running(slot.title), at: point)
            }
            var toRun = action
            if action.asksForName {
                chip.close()
                guard let name = askRenameBase(for: input.files) else { updateEscape(); return }
                toRun = action.withRenameBase(name)
                chip.show(.running(slot.title), at: point)
            }
            let ready = toRun
            run(label: action.displayName) { try await $0.run(ready, input: input) }

        case .folder:
            let folder = URL(fileURLWithPath: slot.target)
            guard !input.files.isEmpty else { return fail(ShakenError.unsupportedInput(L("Only files can be copied to a folder"))) }
            run(label: slot.title) { try await $0.copy(input.files, into: folder) }

        case .app:
            let app = URL(fileURLWithPath: slot.target)
            let urls: [URL]
            switch input {
            case .files(let f): urls = f
            case .link(let u): urls = [u]
            case .text: return fail(ShakenError.unsupportedInput(L("Text")))
            }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, error in
                DispatchQueue.main.async { if let error { self.fail(error) } else { self.chipClose() } }
            }

        case .shortcut:
            runShortcut(slot, input: input)

        case .shell, .applescript:
            runScript(slot, input: input)

        case .web:
            var target = slot.target
            let query: String
            switch input {
            case .text(let t): query = t
            case .link(let u): query = u.absoluteString
            case .files(let f): query = f.map(\.lastPathComponent).joined(separator: " ")
            }
            target = target.replacingOccurrences(of: "{query}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? "")
            guard let u = URL(string: target) else { return fail(ShakenError.other(L("Invalid web address"))) }
            NSWorkspace.shared.open(u)
            chipClose()

        default:
            chipClose()
        }
    }

    /// Shortcuts and scripts share the command path: results land in the chip, with undo.
    func runShortcut(_ slot: ResolvedSlot, input: JobInput?) {
        let name = slot.target
        run(label: slot.title) { runner in
            try await runner.runSlot(slot.title, input: input) { out in try await Shortcuts.run(name, input: input, output: out) }
        }
    }

    /// "Run now" in Settings: does what clicking the slot on a wheel opened without dragging does.
    func runFromSettings(_ slot: Slot) {
        guard let r = ActionResolver.layout(payload: DragPayload([]), actions: registry.actions, settings: store.settings,
                                            slots: [slot]).first, r.enabled else { return }
        clickSource = .clipboard
        let p = NSEvent.mouseLocation
        if r.kind == .switcher, let first = fillSwitchers([r], canDrop: false).first?.children.first {
            return wheel(didClick: first, at: p)
        }
        wheel(didClick: r, at: p)
    }

    func runScript(_ slot: ResolvedSlot, input: JobInput?) {
        let code = slot.target
        let lang: InlineScript.Language = slot.kind == .shell ? .shell : .applescript
        run(label: slot.title) { runner in
            try await runner.runSlot(slot.title, input: input) { out in try await InlineScript.run(code, language: lang, input: input, output: out) }
        }
    }

    func typeSlot(_ slot: ResolvedSlot) {
        switch slot.kind {
        case .snippet: Typing.paste(slot.target)
        case .keys: if let k = KeyCombo(slot.target) { Typing.press(k) }
        default: break
        }
    }

    /// Runs a workflow's steps in order, pausing so apps can open before the next step.
    func runWorkflow(_ steps: [ResolvedSlot], at point: NSPoint) {
        let needsTyping = steps.contains { [.snippet, .keys].contains($0.kind)
            || ($0.kind == .system && SystemControl(rawValue: $0.target)?.needsAccessibility == true) }
        if needsTyping && !Typing.ensureTrusted() {
            return fail(Typing.notTrustedError)
        }
        job?.cancel()
        job = Task { @MainActor [weak self] in
            for step in steps {
                guard let self, !Task.isCancelled else { break }
                switch step.kind {
                case .app:
                    let cfg = NSWorkspace.OpenConfiguration()
                    _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: step.target), configuration: cfg)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                case .web:
                    if let u = URL(string: step.target.replacingOccurrences(of: "{query}", with: "")) { NSWorkspace.shared.open(u) }
                case .folder, .file:
                    NSWorkspace.shared.open(URL(fileURLWithPath: step.target))
                case .shortcut:
                    do { try await Shortcuts.run(step.target) } catch { self.fail(error); return }
                case .snippet, .keys:
                    self.typeSlot(step)
                case .shell, .applescript:
                    do { try await InlineScript.run(step.target, language: step.kind == .shell ? .shell : .applescript) }
                    catch { self.fail(error); return }
                case .system:
                    if let c = SystemControl(rawValue: step.target) {
                        do { try await SystemActions.perform(c) } catch { self.fail(error); return }
                    }
                case .delay:
                    try? await Task.sleep(nanoseconds: UInt64((Double(step.target) ?? 0.5) * 1_000_000_000))
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.job = nil
            self?.updateEscape()
        }
        updateEscape()
    }

    /// Asks for the new base name for "Rename in bulk", suggesting what the files have in common.
    func askRenameBase(for files: [URL]) -> String? {
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        var prefix = names.first ?? ""
        for n in names.dropFirst() { while !n.hasPrefix(prefix) { prefix.removeLast() } }
        prefix = prefix.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let alert = NSAlert()
        alert.messageText = L("Rename %@ files", String(files.count))
        alert.informativeText = L("They'll be named “Name 01”, “Name 02”… in the order you dragged them. Undo puts the old names back.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = prefix.isEmpty ? L("Untitled") : prefix
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func approve(_ action: ActionManifest) {
        if let fp = try? PackManager.fingerprint(of: action) {
            store.update { $0.approvals[action.id] = fp }
        }
    }

    func run(label: String, _ work: @escaping (JobRunner) async throws -> JobResult) {
        job?.cancel()
        let runner = self.runner
        job = Task { @MainActor [weak self] in
            do {
                let r = try await work(runner)
                guard let self else { return }
                self.job = nil
                self.lastResult = r
                if r.outputs.isEmpty {
                    self.chipClose()
                } else {
                    self.chip.show(.done(r))
                }
            } catch is CancellationError {
                self?.job = nil
                self?.chipClose()
            } catch {
                self?.job = nil
                self?.fail(error)
            }
            self?.updateEscape()
        }
        updateEscape()
    }

    func fail(_ error: Error) {
        job = nil
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.error(msg)
        chip.show(.failed(msg))
        updateEscape()
    }
}
