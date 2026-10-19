import PaloAllyKit
import SwiftUI

/// One session: its state as a dot, the name and kind, its context size,
/// and what it waits for or said last.
struct SessionRow: View {
    let session: CCSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SessionStatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    SessionKindTag(kind: session.kind)
                    Spacer(minLength: 4)
                    if let size = Copy.contextSize(session.contextTokens) {
                        Text(size)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(secondLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Copy.contextSize(session.contextTokens).map { String(localized: "上下文 \($0)") } ?? "")
    }

    /// 「等你 · 想运行 npm run build」.
    private var secondLine: String {
        let line = Copy.sessionLine(session)
        let status = Copy.sessionStatus(session.status)
        return line.isEmpty ? status : "\(status) · \(line)"
    }
}

/// The session's state as the one status dot (StatusDot).
struct SessionStatusDot: View {
    let status: CCSessionStatus
    var size: CGFloat = 9

    var body: some View {
        StatusDot(StatusDotKind(status), size: size - 1)
    }
}

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
