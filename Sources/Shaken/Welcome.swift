import AppKit
import ApplicationServices
import ShakenCore
import Combine
import SwiftUI

/// First-launch guide: how to shake, how to open the wheel without dragging,
/// what permissions are for, and a couple of preferences. Reopen from Help › Show Welcome.
final class WelcomeWindowController: NSWindowController {
    init(app: AppController) {
        // The view needs a way to close the window, which doesn't exist yet when the view is made.
        var close: () -> Void = {}
        let window = GlassWindow.make(size: NSSize(width: 560, height: 490), style: [.closable],
                                      root: WelcomeView(app: app, close: { close() }))
        window.title = L("Welcome to Shaken")
        window.isMovableByWindowBackground = true
        close = { [weak window] in window?.close() }
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let app: AppController
    let close: () -> Void
    @State var page = 0
    @State private var trusted = AXIsProcessTrusted()
    @State private var launchAtLogin = false
    @State private var checkUpdates = true
    private let pages = 4
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: shakePage
                case 1: keysPage
                case 2: permissionPage
                default: donePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 30)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == page ? Brand.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(L("Step %@ of %@", String(page + 1), String(pages)))
                Spacer()
                if page > 0 { Button(L("Back")) { page -= 1 } }
                if page < pages - 1 {
                    Button(L("Continue")) { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Start Using Shaken")) { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .animation(.easeOut(duration: 0.18), value: page)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        }
        .frame(width: 560, height: 490)
        .background(GlassBackdrop())
        .tint(Brand.accentColor)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
        .onAppear {
            launchAtLogin = app.launchAtLogin
            checkUpdates = app.store.settings.checkForUpdates
        }
    }

    // MARK: pages

    private var shakePage: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text(L("Shake mid-drag")).font(.system(size: 26, weight: .bold))
            Text(L("Start dragging a file, photo, link or text. Give the mouse a quick shake. A wheel of commands opens under the pointer."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step("1", L("Drag something, and shake left and right two or three times"))
                step("2", L("Slide onto a slot and let go"))
                step("3", L("Drag the result chip into the next app. Esc or the undo button takes it back"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 16)
            .padding(.top, 4)
            Button(L("Try It with a Sample Photo")) { revealSample() }
                .help(L("Shows a sample photo in Finder. Drag it and shake."))
                .padding(.top, 4)
        }
    }

    private var keysPage: some View {
        VStack(spacing: 16) {
            hero { SlotIcon(name: "glyph:Keyboard", size: 30).foregroundStyle(Brand.accentColor) }
            Text(L("No drag? Press a key")).font(.system(size: 26, weight: .bold))
            Text(L("Press %@ anywhere to open the wheel as a launcher: apps, snippets, shortcuts, system controls.", app.store.settings.hotKey.display))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                keyRow("← →", L("Move around the wheel"))
                keyRow(L("Return"), L("Pick the highlighted slot"))
                keyRow("1 – 6", L("Pick a slot directly"))
                keyRow("⌘← ⌘→", L("Switch wheels (or swipe with two fingers)"))
                keyRow("Esc", L("Close"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 16)
            .padding(.top, 4)
        }
    }

    private var permissionPage: some View {
        VStack(spacing: 16) {
            hero {
                Image(systemName: trusted ? "checkmark.shield.fill" : "hand.raised.fill")
                    .font(.system(size: 34)).foregroundStyle(trusted ? Color.green : Brand.accentColor)
            }
            Text(L("Permissions")).font(.system(size: 26, weight: .bold))
            Text(L("Shaking, the wheel, commands, apps, Shortcuts and scripts need no permission at all."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("Text snippets, keyboard shortcuts and a few system controls type into other apps. For those, macOS asks for Accessibility. You can allow it now, or later when you first use one."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if trusted {
                Label(L("Accessibility is allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(L("Allow Accessibility…")) { _ = Typing.ensureTrusted() }
            }
        }
    }

    private var donePage: some View {
        VStack(spacing: 16) {
            hero { Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green) }
            Text(L("You're set")).font(.system(size: 26, weight: .bold))
            Text(L("Shaken lives in the menu bar. Set up your wheels in Settings whenever you like."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L("Open Shaken at login"), isOn: Binding(get: { launchAtLogin }, set: {
                    app.launchAtLogin = $0
                    launchAtLogin = app.launchAtLogin
                }))
                Toggle(L("Check for updates automatically"), isOn: Binding(get: { checkUpdates }, set: { v in
                    checkUpdates = v
                    app.store.update { $0.checkForUpdates = v }
                }))
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 16)
            .padding(.top, 4)
            Button(L("Open Settings…")) { finish(); app.openSettings() }
        }
    }

    // MARK: pieces

    /// A page's symbol on a tile of the wheel's glass.
    private func hero<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: 72, height: 72)
            .glassCard(padding: 0, radius: 20)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StepBadge(text: n)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyRow(_ keys: String, _ text: String) -> some View {
        GridRow {
            KeyCap(text: keys)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: AppController.welcomeShownKey)
        close()
    }

    /// Writes a sample photo into Shaken's folder and shows it in Finder, ready to drag.
    private func revealSample() {
        let dir = ShakenPaths.support.appendingPathComponent("Sample", isDirectory: true)
        let url = dir.appendingPathComponent("Try Shaken.png")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path),
           let tiff = NSApp.applicationIconImage.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
