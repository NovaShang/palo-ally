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

