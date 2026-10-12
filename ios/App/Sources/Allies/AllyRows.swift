import PaloAllyKit
import SwiftUI

/// One Ally: who, the tag, the last exchange, and a dot while they're online.
struct AllyRow: View {
    let ally: AllyInfo
    /// The owner's assistant, for its words on the last line.
    var assistant = ""

    var body: some View {
        HStack(spacing: 12) {
            AllyAvatar(ally: ally, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ally.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    AllyKindTag(kind: ally.kind)
                    Spacer(minLength: 4)
                    if let ts = ally.lastEntry?.ts, ts > 0 {
                        Text(Copy.relative(ts))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(Copy.allyLastLine(ally, assistant: assistant))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Copy.allyPresence(ally))
    }
}

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
