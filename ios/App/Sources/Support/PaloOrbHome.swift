import SwiftUI

/// Where the Palo orb rests when it isn't listening: the sidebar's Palo
/// item, or the collapsed sidebar's capsule. On the Palo page the listening
/// orb flies out from here and back (docs/workbench-prd.md §11).
@MainActor @Observable
final class PaloOrbHome {
    static let shared = PaloOrbHome()
    /// In global coordinates; nil while nothing on screen holds it.
    var frame: CGRect?
}

extension View {
    /// Marks this view as the orb's resting place. Only one is on screen at
    /// a time: the sidebar's Palo item, or the collapsed capsule.
    func paloOrbHome() -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            PaloOrbHome.shared.frame = frame
        }
        .onDisappear { PaloOrbHome.shared.frame = nil }
    }
}
