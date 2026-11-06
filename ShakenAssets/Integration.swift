import AppKit
import SwiftUI

// Keep this owner alive for as long as the menu-bar item should remain visible.
final class ShakenStatusItem {
    let item: NSStatusItem

    init(menu: NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let source = NSImage(named: "ShakenMenuBarTemplate"),
           let image = source.copy() as? NSImage {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = "Shaken"
            item.button?.setAccessibilityLabel("Shaken")
        }
        item.menu = menu
    }
}

// Slot 0 points upward. Coordinate system matches the supplied SVG files.
struct ShakenSector: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 420
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = 202 * scale
        let inner = 72 * scale
        let start = Double(index) * 60 - 90 - 28.8
        let end = start + 57.6
        func point(_ radius: CGFloat, _ degrees: Double) -> CGPoint {
            CGPoint(x: center.x + radius * cos(degrees * .pi / 180),
                    y: center.y + radius * sin(degrees * .pi / 180))
        }
        var p = Path()
        p.move(to: point(outer, start))
        p.addArc(center: center, radius: outer,
                 startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        p.addLine(to: point(inner, end))
        p.addArc(center: center, radius: inner,
                 startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}

// Illustration of native material, hover and separate labels.
// Route keyboard, drop handling, focus and accessibility order in your app controller.
struct ShakenWheel: View {
    let onAction: (Int) -> Void
    let onShelf: () -> Void
    @State private var hovered: Int?
    private let names = ["Convert", "Compress", "Metadata", "Preview", "CopyName", "Downloads"]
    private let labels = ["Convert", "Compress", "Remove metadata", "Preview", "Copy name", "Downloads"]

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let scale = side / 420
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    let angle = (Double(index) * 60 - 90) * .pi / 180
                    let sector = ShakenSector(index: index)
                    Button { onAction(index) } label: {
                        ZStack {
                            sector.fill(.ultraThinMaterial)
                            if hovered == index {
                                sector.fill(Color(red: 125/255, green: 137/255, blue: 237/255))
                            }
                            sector.strokeBorderCompatible()
                            VStack(spacing: 8 * scale) {
                                Image(names[index])
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24 * scale, height: 24 * scale)
                                Text(labels[index])
                                    .font(.system(size: 12 * scale, weight: .medium))
                                    .multilineTextAlignment(.center)
                                    .frame(width: 95 * scale)
                            }
                            .foregroundStyle(hovered == index ? Color.white : Color.primary)
                            .position(x: side / 2 + CGFloat(cos(angle)) * 141 * scale,
                                      y: side / 2 + CGFloat(sin(angle)) * 141 * scale)
                        }
                        .contentShape(sector)
                    }
                    .buttonStyle(.plain)
                    .contentShape(sector)
                    .onHover { inside in
                        if inside { hovered = index }
                        else if hovered == index { hovered = nil }
                    }
                    .accessibilityLabel(labels[index])
                }
                Button(action: onShelf) {
                    VStack(spacing: 5 * scale) {
                        Image("Stack").renderingMode(.template)
                            .resizable().scaledToFit()
                            .frame(width: 24 * scale, height: 24 * scale)
                        Text("2 images").font(.system(size: 13 * scale, weight: .semibold))
                        Text("Drop to shelf").font(.system(size: 10 * scale))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 134 * scale, height: 134 * scale)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Put images on shelf")
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private extension ShakenSector {
    func strokeBorderCompatible() -> some View {
        self.stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
    }
}
