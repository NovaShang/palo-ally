import PaloAllyKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's drag and drop (the owner's own order): reorder sessions,
/// workspaces and a workspace's sessions; drop a session onto a workspace to
/// put it in, onto 会话 or among the ordinary sessions to take it out, onto
/// another ordinary session to make a workspace of the two. What a drop means
/// is `SidebarDrop` in the Kit; this is the part that watches the pointer.
///
/// Where a drag starts: on the Mac the list's own (`itemProvider`), so a row
/// still selects on a click as any Mac list's does (a gesture of our own on
/// the row, `onDrag`, took the clicks there); on iPads and phones `onDrag`
/// (a long press), which on iPads also carries the row out of the window to
/// open it in a new one, as `OpenInNewWindow` did.
/// Where it lands: `onDrop` on the rows, with a `DropDelegate`, whose pointer
/// position tells "before", "onto" and "after" apart and draws the line or
/// the outline. `List.onMove` can't: it reorders one `ForEach` only, never
/// onto a row, and on iPads and phones only in edit mode.
@MainActor @Observable
final class SidebarDragState {
    /// One drag at a time, whichever window it starts in.
    static let shared = SidebarDragState()

    struct Hover: Equatable {
        var target: SidebarDrop.Target
        var zone: SidebarDrop.Zone
    }

    /// What is in the air (set when a drag starts; a drag that is cancelled
    /// leaves it, harmlessly, until the next one starts).
    var item: SidebarDrop.Item?
    var hover: Hover?
}

extension UTType {
    /// A sidebar row being dragged (declared in Info.plist): only the
    /// sidebar takes it, so a row let go over the composer types nothing.
    static let paloAllySidebarItem = UTType(exportedAs: "com.novashang.paloally.sidebar-item", conformingTo: .data)
}

private struct SidebarRowDragDrop: ViewModifier {
    /// What this row lets go of when dragged (nil: it only receives).
    let drags: SidebarDrop.Item?
    /// The row's conversation, for a drag out of the window (iPads).
    let conversation: WindowModel.Conversation?
    let target: SidebarDrop.Target
    let tree: SidebarTree
    let sessionOrder: [String]?
    let perform: (SidebarDrop.Move) -> Void
    @Environment(WindowModel.self) private var model
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        let state = SidebarDragState.shared
        let delegate = Delegate(target: target, height: height, state: state, tree: tree, sessionOrder: sessionOrder, perform: perform)
        source(content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay { Marker(target: target, state: state) })
            .onDrop(of: [.paloAllySidebarItem], delegate: delegate)
    }

    @ViewBuilder private func source(_ content: some View) -> some View {
        if let drags {
            #if targetEnvironment(macCatalyst)
            content.itemProvider { provider(drags) }
            #else
            content.onDrag { provider(drags) }
            #endif
        } else {
            content
        }
    }

    private func provider(_ item: SidebarDrop.Item) -> NSItemProvider {
        SidebarDragState.shared.item = item
        SidebarDragState.shared.hover = nil
        let provider = NSItemProvider()
        // iPads: let go outside the window, it opens in a new one.
        if let conversation, UIApplication.shared.supportsMultipleScenes, !Platform.isMac {
            provider.registerObject(WindowTarget.activity(for: conversation, host: model.activeHostID), visibility: .all)
        }
        let data = Data(item.token.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.paloAllySidebarItem.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// The line or outline that shows where a drop would land.
    private struct Marker: View {
        let target: SidebarDrop.Target
        let state: SidebarDragState

        var body: some View {
            if let hover = state.hover, hover.target == target {
                switch hover.zone {
                case .before: line.frame(maxHeight: .infinity, alignment: .top)
                case .after: line.frame(maxHeight: .infinity, alignment: .bottom)
                case .onto:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
        }

        private var line: some View {
            Capsule().fill(Color.primary.opacity(0.6)).frame(height: 2).padding(.horizontal, 2).allowsHitTesting(false)
        }
    }

    private struct Delegate: DropDelegate {
        let target: SidebarDrop.Target
        let height: CGFloat
        let state: SidebarDragState
        let tree: SidebarTree
        let sessionOrder: [String]?
        let perform: (SidebarDrop.Move) -> Void

        private func zone(_ info: DropInfo, _ item: SidebarDrop.Item) -> SidebarDrop.Zone {
            SidebarDrop.zone(item, on: target, y: info.location.y, height: height)
        }

        func validateDrop(info: DropInfo) -> Bool {
            guard let item = state.item else { return false }
            return SidebarDrop.accepts(item, on: target)
        }

        func dropEntered(info: DropInfo) { update(info) }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            update(info)
            guard let item = state.item, SidebarDrop.plan(item, on: target, zone: zone(info, item), tree: tree, sessionOrder: sessionOrder) != nil
            else { return DropProposal(operation: .forbidden) }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            if state.hover?.target == target { state.hover = nil }
        }

        func performDrop(info: DropInfo) -> Bool {
            defer { state.hover = nil; state.item = nil }
            guard let item = state.item,
                  let move = SidebarDrop.plan(item, on: target, zone: zone(info, item), tree: tree, sessionOrder: sessionOrder)
            else { return false }
            perform(move)
            return true
        }

        private func update(_ info: DropInfo) {
            guard let item = state.item, SidebarDrop.accepts(item, on: target) else { return }
            let z = zone(info, item)
            // Nothing to show where the drop would change nothing.
            let useful = SidebarDrop.plan(item, on: target, zone: z, tree: tree, sessionOrder: sessionOrder) != nil
            let next = useful ? SidebarDragState.Hover(target: target, zone: z) : nil
            if state.hover != next { state.hover = next }
        }
    }
}

extension View {
    /// A sidebar row that can be dragged (`drags`) and dropped on (`target`).
    func sidebarDragDrop(drags: SidebarDrop.Item?, conversation: WindowModel.Conversation? = nil, target: SidebarDrop.Target,
                         tree: SidebarTree, sessionOrder: [String]?, perform: @escaping (SidebarDrop.Move) -> Void) -> some View {
        modifier(SidebarRowDragDrop(drags: drags, conversation: conversation, target: target, tree: tree, sessionOrder: sessionOrder,
                                    perform: perform))
    }
}

extension View {
    /// `sidebarDragDrop` when the host has workspaces (`on`); otherwise the
    /// row as before, still draggable out of the window on iPads.
    @ViewBuilder func sidebarRowDrag(_ on: Bool, drags: SidebarDrop.Item?, conversation: WindowModel.Conversation?,
                                     target: SidebarDrop.Target, tree: SidebarTree, sessionOrder: [String]?,
                                     perform: @escaping (SidebarDrop.Move) -> Void) -> some View {
        if on {
            sidebarDragDrop(drags: drags, conversation: conversation, target: target, tree: tree, sessionOrder: sessionOrder, perform: perform)
        } else if let conversation {
            modifier(OpenInNewWindow(conversation: conversation))
        } else {
            self
        }
    }
}
