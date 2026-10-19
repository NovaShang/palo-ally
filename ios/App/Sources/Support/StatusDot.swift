import PaloAllyKit
import SwiftUI

/// The one status dot every list, row and title uses (workbench-prd §3):
/// cyan with a soft halo while it works, orange when it waits on the owner
/// (the only loud one), green when it finished something not yet looked at,
/// gray otherwise. Not the theme color.
struct StatusDot: View {
    let kind: StatusDotKind
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    init(_ kind: StatusDotKind, size: CGFloat = 8) { self.kind = kind; self.size = size }
    init(_ pal: Pal, size: CGFloat = 8) { self.init(pal.dot, size: size) }

    var body: some View {
        Circle()
            .fill(Self.color(kind))
            .frame(width: size, height: size)
            // The halo is drawn outside the layout: rows don't grow for it.
            .background {
                if kind == .working {
                    Circle()
                        .fill(Self.color(.working).opacity(breathing ? 0.22 : 0.38))
                        .frame(width: size * 2.1, height: size * 2.1)
                        .blur(radius: size * 0.3)
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: kind)
            .onAppear { startBreathing() }
            .onChange(of: kind) { startBreathing() }
            .accessibilityElement()
            .accessibilityLabel(Self.label(kind))
    }

    private func startBreathing() {
        guard kind == .working, !reduceMotion else { breathing = false; return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
    }

    static func color(_ kind: StatusDotKind) -> Color {
        switch kind {
        case .working: .cyan
        case .waiting: .orange
        case .done: .green
        case .idle: Color(.systemGray3)
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
