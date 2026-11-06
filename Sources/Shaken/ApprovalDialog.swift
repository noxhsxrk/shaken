import AppKit
import ShakenCore

/// Shown before a pack action runs for the first time, or after any of its files
/// changed (R9). Lists every file with its contents so the user sees what will run.
enum ApprovalDialog {
    static func ask(for action: ActionManifest, reviewOnly: Bool = false) -> Bool {
        guard let dir = action.directory else { return false }
        let files = ((try? Fingerprint.tree(dir)) ?? [:]).keys.sorted()

        let body = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let head = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for rel in files {
            body.append(NSAttributedString(string: "── \(rel) ──\n", attributes: [.font: head, .foregroundColor: NSColor.labelColor]))
            let url = dir.appendingPathComponent(rel)
            let data = (try? Data(contentsOf: url)) ?? Data()
            let text: String
            if data.count > 64_000 {
                text = L("(large file, %@ — not shown)", ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
            } else if let s = String(data: data, encoding: .utf8) {
                text = s
            } else {
                text = L("(binary file, %@ — not shown)", ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
            }
            body.append(NSAttributedString(string: text + "\n\n", attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        }

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.textStorage?.setAttributedString(body)
            tv.textContainerInset = NSSize(width: 6, height: 6)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Allow “%@” to run?", action.displayName)
        var info = L("This command comes from the pack “%@”. Its scripts run as you: they can read and change every file you can access.", packName(action))
        info += "\n\n" + L("Shaken can only move and undo files the script writes into $SHAKEN_OUTPUT. If it changes other files itself, Shaken can't undo that.")
        info += "\n\n" + L("If any of these files change later, Shaken will ask again.")
        alert.informativeText = info
        alert.accessoryView = scroll
        alert.addButton(withTitle: reviewOnly ? L("Allow") : L("Allow and Run"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func packName(_ a: ActionManifest) -> String {
        if case .pack(let n) = a.source { return n }
        return "—"
    }
}
