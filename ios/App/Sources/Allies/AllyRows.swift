import PaloAllyKit
import SwiftUI

/// The round initial standing in for a photo, with a green dot while they're online.
struct AllyAvatar: View {
    let ally: AllyInfo
    var size: CGFloat = 40
    /// What the dot is cut out of: the background behind the avatar.
    var ring = Color(.secondarySystemGroupedBackground)

    var body: some View {
        Text(ally.initial)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.fill.tertiary, in: .circle)
            .overlay(alignment: .bottomTrailing) {
                if ally.online {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .overlay(Circle().strokeBorder(ring, lineWidth: max(1.5, size * 0.05)))
                        .offset(x: size * 0.02, y: size * 0.02)
                }
            }
            .accessibilityHidden(true)
    }
}

/// 家人朋友 / 我的: a small neutral tag.
struct AllyKindTag: View {
    let kind: AllyKind

    var body: some View {
        Text(Copy.allyKind(kind))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: .capsule)
    }
}
