import PaloAllyKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's drag and drop (the owner's manual order). What a drop means is
/// `SidebarDrop` in the Kit; this is the part that watches the pointer.
///
/// Why `onDrag` / `onDrop(delegate:)` on the rows rather than `List.onMove`:
/// on UIKit lists (iPad, Mac Catalyst) `onMove` only works in edit mode and can
/// only reorder within one `ForEach`, but this needs dropping onto a row (make
/// a workspace, go into one) and across sections (in and out of a workspace).
/// A `DropDelegate` also reports the pointer's position while it moves, which
/// is what tells "before", "onto" and "after" apart and draws the line.
@MainActor @Observable
final class SidebarDragState {
    /// What is in the air (set when a drag starts; a drag that is cancelled
    /// leaves it, harmlessly, until the next one starts).
    var item: SidebarDrop.Item?
    var hover: (target: SidebarDrop.Target, zone: SidebarDrop.Zone)?
}

private struct SidebarRowDragDrop: ViewModifier {
    /// What this row lets go of when dragged (nil: it only receives).
    let drags: SidebarDrop.Item?
    let target: SidebarDrop.Target
    let state: SidebarDragState
    let tree: SidebarTree
    let sessionOrder: [String]?
    let perform: (SidebarDrop.Move) -> Void
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        let delegate = Delegate(target: target, height: height, state: state, tree: tree, sessionOrder: sessionOrder, perform: perform)
        let base = content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay { Marker(target: target, state: state) }
        if let drags {
            base
                .onDrag {
                    state.item = drags
                    return NSItemProvider(object: drags.token as NSString)
                }
                .onDrop(of: [.plainText], delegate: delegate)
        } else {
            base.onDrop(of: [.plainText], delegate: delegate)
        }
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
            SidebarDrop.zone(y: info.location.y, height: height, allowsOnto: SidebarDrop.allowsOnto(item, on: target))
        }

        func validateDrop(info: DropInfo) -> Bool {
            guard let item = state.item else { return false }
            return SidebarDrop.accepts(item, on: target)
        }

        func dropEntered(info: DropInfo) { update(info) }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            update(info)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            if state.hover?.target == target { state.hover = nil }
        }

        func performDrop(info: DropInfo) -> Bool {
            defer { state.hover = nil; state.item = nil }
            guard let item = state.item else { return false }
            guard let move = SidebarDrop.plan(item, on: target, zone: zone(info, item), tree: tree, sessionOrder: sessionOrder) else { return false }
            perform(move)
            return true
        }

        private func update(_ info: DropInfo) {
            guard let item = state.item, SidebarDrop.accepts(item, on: target) else { return }
            let z = zone(info, item)
            // Nothing to show where the drop would change nothing.
            let useful = SidebarDrop.plan(item, on: target, zone: z, tree: tree, sessionOrder: sessionOrder) != nil
            let next: (target: SidebarDrop.Target, zone: SidebarDrop.Zone)? = useful ? (target, z) : nil
            if state.hover?.target != next?.target || state.hover?.zone != next?.zone { state.hover = next }
        }
    }
}

extension View {
    func sidebarDragDrop(drags: SidebarDrop.Item?, target: SidebarDrop.Target, state: SidebarDragState, tree: SidebarTree,
                         sessionOrder: [String]?, perform: @escaping (SidebarDrop.Move) -> Void) -> some View {
        modifier(SidebarRowDragDrop(drags: drags, target: target, state: state, tree: tree, sessionOrder: sessionOrder, perform: perform))
    }
}
