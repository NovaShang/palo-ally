import PaloAllyKit
import SwiftUI

/// What the title's indicator opens: the one details page (Detail/AgentDetailForm)
/// for the assistant or an agent, as a popover or a sheet. Files and 成果 are
/// the title bar's right button, not here. Reads the store in the environment:
/// a session's own (`palStore`) or the assistant's.
struct AgentDetailView: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.tileDetail) private var tileDetail
    /// The list's content height, so a popover fits it (nil: not measured yet).
    @State private var contentHeight: CGFloat?

    private var asSheet: Bool { AgentDetailPlacement.usesSheet(model: model, store: store) }

    /// The popover's most: 860 pt on the Mac (640 elsewhere), and on the Mac
    /// no more than its window's height less the title bar and a margin.
    private var tallest: CGFloat {
        guard Platform.isMac else { return 640 }
        let window = model.scene?.effectiveGeometry.coordinateSpace.bounds.height ?? 0
        return window > 0 ? min(860, max(240, window - 84)) : 860
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.scope == .palo {
                    AgentDetailForm(agent: nil)
                } else if let id = store.palID {
                    AgentDetailForm(agent: id)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: { _, h in
                contentHeight = h
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if asSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { model.setDetail(false, tile: tileDetail) }.tint(.primary) }
                }
            }
        }
        // A popover takes its content's height with the list's own insets
        // (the bar above, the margin below), within reason. A fixed 52 pt for
        // the bar left the Mac's popover short: its top and bottom were cut (11-19).
        // The Mac's windows are tall: up to 860 pt there (Palo's details run
        // about 700, and at 640 their top or bottom was always scrolled away).
        // On the Mac a popover is a window of its own: in a short window it
        // ran past the bottom (设置 unfolded, 11-22), so it also stays within
        // the window, from the title bar down, and scrolls inside.
        .frame(height: asSheet ? nil : contentHeight.map { min(max($0, 240), tallest) })
        .accessibilityIdentifier("agent-detail")
        // 设置 folded and nothing pushed the next time it opens.
        .onDisappear { model.resetDetailPage() }
    }
}
