import AppKit
import SwiftUI

/// The glass look shared by Settings and Welcome: a blurred window, a faint wash of the glass
/// colour, and cards drawn with the same colours as the wheel's tiles.
enum GlassWindow {
    /// A window whose whole content, titlebar included, sits on the blurred desktop.
    static func make<V: View>(size: NSSize, style: NSWindow.StyleMask, root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style.union([.titled, .fullSizeContentView]), backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: root)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        window.contentView = effect
        return window
    }
}

/// The glass colour washed faintly over the blur, stronger with the Tint setting.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let strength = 0.05 + 0.13 * Double(Brand.tintStrength)
        ZStack {
            if reduce { Color(nsColor: .windowBackgroundColor) }
            LinearGradient(colors: [Brand.accentColor.opacity(strength * (scheme == .dark ? 1 : 0.8)), Brand.accentColor.opacity(0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

/// A raised pane of glass: the wheel's unselected-tile colours, lighter, with its hairline edge.
struct GlassCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let c = Brand.glassColors(dark: dark, selected: false)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return content
            .padding(padding)
            .background(
                shape.fill(LinearGradient(colors: [Color(nsColor: c.top), Color(nsColor: c.bottom)], startPoint: .top, endPoint: .bottom))
                    .opacity(opaque ? 1 : (dark ? 0.55 : 0.7))
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0 : 0.06), lineWidth: 1))
            .overlay(shape.strokeBorder(Color(nsColor: c.edge).opacity(dark ? 0.6 : 0.9), lineWidth: 0.5))
    }
}

extension View {
    func glassCard(padding: CGFloat = 14, radius: CGFloat = 14) -> some View {
        modifier(GlassCard(padding: padding, radius: radius))
    }

    /// Forms and lists paint an opaque backdrop of their own; let the glass show through.
    func clearScrollBackground() -> some View {
        scrollContentBackground(.hidden)
    }
}

/// A pane's title, a line about it, and its own controls on the right.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A key name drawn as a small glass keycap.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(.body, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassCard(padding: 0, radius: 6)
    }
}

/// A number in an accent-glass circle, for steps.
struct StepBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.onAccentColor)
            .frame(width: 20, height: 20)
            .background(GlassShape(shape: Circle(), selected: true))
    }
}
