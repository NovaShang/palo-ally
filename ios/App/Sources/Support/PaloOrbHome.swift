import SwiftUI

/// Where the Palo orb rests when it isn't listening: the sidebar's Palo
/// item, or the collapsed sidebar's capsule. On the Palo page the listening
/// orb flies out from here and back (docs/workbench-prd.md §11). One per
/// window (`WindowModel.orbHome`): each window has its own coordinates.
@MainActor @Observable
final class PaloOrbHome {
    /// In global coordinates; nil while nothing on screen holds it.
    var frame: CGRect?
    /// Whoever set `frame` last, so a place that goes away only clears its own.
    var owner: UUID?
    /// True while the flying orb is out: the resting orb steps aside.
    var flying = false
}

extension View {
    /// Marks this view as the orb's resting place. Only one is on screen at
    /// a time: the sidebar's Palo item, the collapsed capsule, or (phones) the
    /// title bar's indicator. `owner` tells them apart when one comes up as
    /// another goes (a page push).
    func paloOrbHome(owner: UUID = UUID()) -> some View {
        modifier(PaloOrbHomeMark(owner: owner))
    }
}

private struct PaloOrbHomeMark: ViewModifier {
    @State var owner: UUID
    @Environment(WindowModel.self) private var model

    init(owner: UUID) { _owner = State(initialValue: owner) }

    func body(content: Content) -> some View {
        let home = model.orbHome
        return content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                home.frame = frame
                home.owner = owner
            }
            .onDisappear {
                if home.owner == owner {
                    home.frame = nil
                    home.owner = nil
                }
            }
            .opacity(home.flying ? 0 : 1)
    }
}
