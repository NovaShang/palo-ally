import PaloAllyKit
import SwiftUI

/// Palo 开的 / 终端 / 后台: a small neutral tag.
struct SessionKindTag: View {
    let kind: CCSessionKind

    var body: some View {
        Text(Copy.sessionKind(kind))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: .capsule)
    }
}

/// 「问卷数据清洗 问你」 on top of a card from one of the computer's other
/// sessions (not a Pal: those have no page; 接管 in the list makes one).
struct SessionSourceLabel: View {
    let text: String
    /// Kept for the callers; the label doesn't open anything.
    let sessionID: String?

    var body: some View {
        Label(text, systemImage: "terminal")
            .labelStyle(QuietLabelStyle())
            .lineLimit(1)
    }
}
