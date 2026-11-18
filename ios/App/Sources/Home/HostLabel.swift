import PaloAllyKit
import SwiftUI

/// Several computers paired: which one the page in front is on, small at
/// its top (「家里」 with that computer's color as a dot), so words aren't
/// sent to the wrong one (docs/workbench-design/multi-host-sidebar.html).
/// Neutral chrome; the color only on the dot. One computer: nothing.
struct HostLabel: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        if model.hasSeveralHosts, let id = model.activeHostID {
            let name = model.displayName(id)
            HStack(spacing: 5) {
                Circle()
                    .fill(model.theme(for: id).color)
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "在「\(name)」上"))
            .accessibilityIdentifier("host-label")
        }
    }
}

/// Where the label goes. The Mac: in the title bar row at the conversation
/// column's left (the row's middle has the page's own drop, its right the
/// toolbar's items), past the traffic lights and the sidebar's button
/// while the sidebar is away; it takes no clicks (the row still drags the
/// window). Phones and iPads: the navigation bar's leading side, after back.
struct HostLabelPlacement: ViewModifier {
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        if !model.hasSeveralHosts {
            content
        } else if Platform.barInWindowToolbar {
            content.overlay(alignment: .topLeading) {
                HostLabel()
                    .background(Color.primary.opacity(0.07), in: .capsule)
                    .frame(height: 22)
                    .padding(.top, max(0, MacTitlebar.midY - 11))
                    .padding(.leading, model.sidebarCollapsed ? SidebarChrome.shared.leadingEnd + 46 : 14)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HostLabel()
                }
            }
        }
    }
}
