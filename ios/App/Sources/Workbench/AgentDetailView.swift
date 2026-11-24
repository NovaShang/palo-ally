import PaloAllyKit
import SwiftUI

/// What the title's indicator opens: the one details page
/// (Detail/DetailTiles) for the assistant or an agent, as a popover (the
/// Mac and iPad) or a sheet as high as its tiles (a phone), and the pages
/// they push. Files and 成果 are the title bar's right button, not here.
/// Reads the store in the environment: a session's own (`palStore`) or the
/// assistant's.
struct AgentDetailView: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// The tiles' height, so the popover or the sheet fits them (nil: not measured yet).
    @State private var height: CGFloat?
    /// The phone's sheet is as high as the screen: no glass round the tiles
    /// then (the system fills it in), so they stand on gray.
    @State private var full = false

    static var width: CGFloat {
        #if DEBUG
        // `-demoDetailPhone YES`: a phone's card, 390 pt less its margins (snapshots).
        if UserDefaults.standard.bool(forKey: "demoDetailPhone") { return 374 }
        #endif
        return 380
    }
    /// A pushed page's height in the popover.
    private static let pageHeight: CGFloat = 540

    private var asSheet: Bool { AgentDetailPlacement.usesSheet(model: model) }
    private var pushed: Bool { model.detailPage != nil }

    /// The popover's most: 860 pt on the Mac (640 elsewhere), and on the Mac
    /// no more than its window's height less the title bar and a margin (a
    /// popover is a window of its own there: in a short one it ran past the
    /// bottom, 11-22); it scrolls inside.
    private var tallest: CGFloat {
        guard Platform.isMac else { return 640 }
        let window = model.scene?.effectiveGeometry.coordinateSpace.bounds.height ?? 0
        return window > 0 ? min(860, max(240, window - 84)) : 860
    }

    /// A sheet's height is over the bottom safe area (and the keyboard); a
    /// popover's has its arrow's room too.
    private func fit(_ content: CGFloat, _ insets: CGFloat) {
        height = asSheet ? content : content + insets
    }

    private var popoverHeight: CGFloat? {
        if pushed { return min(max(height ?? 0, Self.pageHeight), tallest) }
        return height.map { min($0, tallest) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.scope == .palo {
                    DetailTiles(agent: nil, onHeight: fit)
                } else if let id = store.palID {
                    DetailTiles(agent: id, onHeight: fit)
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
        .environment(\.detailOnGlass, !(asSheet && (full || pushed)))
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { h in
            let window = model.scene?.effectiveGeometry.coordinateSpace.bounds.height ?? 0
            full = window > 0 && h > window * 0.85
        }
        #if DEBUG
        .modifier(DemoTypeSize())
        #endif
        .modifier(Fitted(sheet: asSheet, pushed: pushed, height: height, popover: popoverHeight))
        .accessibilityIdentifier("agent-detail")
        // Nothing pushed the next time it opens.
        .onDisappear { model.resetDetailPage() }
    }

    private struct Fitted: ViewModifier {
        let sheet: Bool
        let pushed: Bool
        let height: CGFloat?
        let popover: CGFloat?

        func body(content: Content) -> some View {
            if sheet {
                content
                    .presentationDetents(pushed ? [.large] : [height.map { .height($0) } ?? .medium])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(pushed ? nil : 42)
            } else {
                content.frame(width: AgentDetailView.width, height: popover)
            }
        }
    }
}
