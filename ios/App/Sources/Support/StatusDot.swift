import PaloAllyKit
import SwiftUI

/// The one status dot every list, row and title uses (workbench-prd §3), in
/// Bento Term's palette: blue with a soft halo while it works, amber when it
/// waits on the owner (the only loud one), green when it finished something
/// not yet looked at, gray otherwise. Not the theme color.
struct StatusDot: View {
    let kind: StatusDotKind
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ kind: StatusDotKind, size: CGFloat = 8) { self.kind = kind; self.size = size }
    init(_ pal: Pal, size: CGFloat = 8) { self.init(pal.dot, size: size) }

    var body: some View {
        Circle()
            .fill(Self.color(kind))
            .frame(width: size, height: size)
            // The halo is drawn outside the layout: rows don't grow for it.
            .background {
                if kind == .working {
                    // Breathing in a view graph of its own (IsolatedHost): a
                    // forever animation in the window's graph re-rendered the
                    // whole window every frame.
                    IsolatedHost { StatusHalo(size: size, still: reduceMotion) }
                        .frame(width: size * 2.1, height: size * 2.1)
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: kind)
            .accessibilityElement()
            .accessibilityLabel(Self.label(kind))
    }


    static func color(_ kind: StatusDotKind) -> Color {
        switch kind {
        case .working: Color(rgb: 0x0A85FF)
        case .waiting: Color(rgb: 0xFF9F0A)
        case .done: Color(rgb: 0x30D158)
        case .idle: Color(rgb: 0x8E8E93)
        }
    }

    /// 在干 / 等你 / 做完了 / 闲着.
    static func label(_ kind: StatusDotKind) -> String {
        switch kind {
        case .working: String(localized: "在干")
        case .waiting: String(localized: "等你")
        case .done: String(localized: "做完了")
        case .idle: String(localized: "闲着")
        }
    }
}

extension Color {
    /// 0xRRGGBB in sRGB.
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

/// The working dot's soft halo, breathing.
private struct StatusHalo: View {
    let size: CGFloat
    let still: Bool
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(StatusDot.color(.working).opacity(breathing ? 0.22 : 0.38))
            .frame(width: size * 2.1, height: size * 2.1)
            .blur(radius: size * 0.3)
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
            }
    }
}
