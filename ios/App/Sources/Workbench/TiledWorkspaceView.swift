import PaloAllyKit
import SwiftUI

/// What the narrow switcher's capsule shows of a session.
struct TileInfo: Equatable {
    var name: String
    var dot: StatusDotKind = .idle
    var running = 0
    /// A document's card: its mark instead of a state.
    var symbol: String? = nil
}

/// The tiling's measures.
private enum TileMetrics {
    /// A pane narrower than this is too cramped to read and type in: the
    /// panes that don't fit go to the row of capsules below (the owner,
    /// 11-06: on an iPad three panes were squeezed side by side).
    static let minPaneWidth: Double = 340
    static let gap: Double = 8
}

/// A workspace's sessions tiled on one canvas (workbench-prd §5.3,
/// docs/workbench-design/split-final.html): flat panes with hairlines
/// between them, each in a view graph of its own (`PaneCanvasController`).
/// It reports every change of the layout (a divider let go, a pane swapped
/// or docked) so the caller can keep it and send it to the host. Nothing
/// else is decided here.
///
/// When the panes can't all stand side by side at `minPaneWidth` (an iPad,
/// a narrow window), only as many as fit show, the current one among them,
/// and the rest sit in a row of capsules below; the stored layout is left
/// alone and the dividers and dragging are off. Whole columns fold, each
/// kept one with its rows and proportions; the folded panes are tabs in
/// the title bar row (`onFolded`), not a row of their own (the owner, 11-06).
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
    /// The panes that don't fit (shown as tabs in the title bar row).
    var onFolded: ([String]) -> Void = { _ in }

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("Tiled")
        #endif
        GeometryReader { outer in
            let normalized = LayoutTree.resized(layout)
            let fit = LayoutTree.fitting(width: Double(outer.size.width), minWidth: TileMetrics.minPaneWidth, gap: TileMetrics.gap)
            let folded = LayoutTree.foldingColumns(normalized, active: LayoutTree.columns(of: normalized) > fit ? active() : nil, fit: fit)
            // Folded, a kept column narrower than a pane may be is evened out.
            let narrowest = LayoutTree.fractions(of: folded.shown).values.map(\.w).min() ?? 1
            let shown = folded.tiling.isNarrow && narrowest * Double(outer.size.width) < TileMetrics.minPaneWidth
                ? LayoutTree.evenColumns(folded.shown) : folded.shown
            PaneCanvas(tree: shown, interactive: !folded.tiling.isNarrow, accent: accent, handle: handle,
                       makePane: makePane, onLayoutChange: onLayoutChange, onActivate: onActivate,
                       onMoveFocus: onMoveFocus, paneInfo: info, onCornerPane: onCornerPane)
                .onChange(of: folded.tiling.switcher, initial: true) { _, ids in onFolded(ids) }
        }
    }
}

/// A folded pane's tab in the title bar row: its state and name; picked,
/// its column comes into view.
struct TileSwitchButton: View {
    let id: String
    let info: (String) -> TileInfo
    let onActivate: (String) -> Void

    var body: some View {
        let i = info(id)
        Button { onActivate(id) } label: {
            HStack(spacing: 6) {
                if let symbol = i.symbol {
                    Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                } else {
                    StatusDot(i.dot, size: 8)
                }
                Text(i.name).font(.subheadline).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("tile-switch-\(id)")
    }
}
