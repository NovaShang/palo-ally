import PaloAllyKit
import SwiftUI

/// What the narrow switcher's capsule shows of a session.
struct TileInfo: Equatable {
    var name: String
    var dot: StatusDotKind = .idle
    var running = 0
}

/// The tiling's measures.
private enum TileMetrics {
    static let switcherHeight: CGFloat = 48
    static let narrowBelow: Double = 700
}

/// A workspace's sessions tiled on one canvas (workbench-prd §5.3,
/// docs/workbench-design/split-final.html): flat panes with hairlines
/// between them, each in a view graph of its own (`PaneCanvasController`).
/// It reports every change of the layout (a divider let go, a pane swapped
/// or docked) so the caller can keep it and send it to the host. Nothing
/// else is decided here.
///
/// On a narrow width (iPad slide over, split view) only two panes show and
/// the rest sit in a row of capsules below; the stored layout is left alone
/// and the dividers and dragging are off.
struct TiledWorkspaceView: View {
    /// The tree to draw (any drift is renormalized here).
    let layout: LayoutTree.Node
    /// The current pane (read only on narrow widths, where it picks what shows).
    let active: () -> String?
    let info: (String) -> TileInfo
    let accent: UIColor
    let handle: PaneCanvasHandle
    let makePane: (String) -> UIViewController
    var onLayoutChange: (LayoutTree.Node) -> Void = { _ in }
    var onActivate: (String) -> Void = { _ in }
    var onMoveFocus: (Bool) -> Void = { _ in }
    var onCornerPane: (String?) -> Void = { _ in }

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("Tiled")
        #endif
        GeometryReader { outer in
            let normalized = LayoutTree.resized(layout)
            let order = LayoutTree.leafOrder(of: normalized)
            let mayNarrow = Double(outer.size.width) < TileMetrics.narrowBelow && order.count > 2
            let narrow = LayoutTree.narrowPolicy(order: order, active: mayNarrow ? active() : nil,
                                                 width: outer.size.width, narrowBelow: TileMetrics.narrowBelow)
            let shown = narrow.isNarrow ? (LayoutTree.keeping(narrow.visible, in: normalized) ?? normalized) : normalized
            VStack(spacing: 0) {
                PaneCanvas(tree: shown, interactive: !narrow.isNarrow, active: active(), accent: accent, handle: handle,
                           makePane: makePane, onLayoutChange: onLayoutChange, onActivate: onActivate,
                           onMoveFocus: onMoveFocus, paneInfo: info, onCornerPane: onCornerPane)
                if narrow.isNarrow {
                    switcher(narrow.switcher)
                        .frame(height: TileMetrics.switcherHeight)
                }
            }
        }
    }

    // MARK: - the narrow switcher

    private func switcher(_ ids: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        TileSwitchButton(id: id, info: info, onActivate: onActivate)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// One capsule of the narrow switcher (reads its session itself).
private struct TileSwitchButton: View {
    let id: String
    let info: (String) -> TileInfo
    let onActivate: (String) -> Void

    var body: some View {
        let i = info(id)
        Button { onActivate(id) } label: {
            HStack(spacing: 6) {
                StatusDot(i.dot, size: 8)
                Text(i.name).font(.subheadline).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("tile-switch-\(id)")
    }
}
