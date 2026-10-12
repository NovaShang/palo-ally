import PaloAllyKit
import SwiftUI

/// The computer's Claude Code sessions as a list section: helpers first,
/// then the owner's own (终端 / 后台). Goes in any List; hidden while the
/// computer's PaloAlly doesn't know sessions, or has none.
struct SessionsSection: View {
    @Environment(AppStore.self) private var store
    /// 「会话」 over the rows (not on a page already titled so).
    var showsHeader = true

    var body: some View {
        if store.sessionsSupported == true, !store.sessions.isEmpty {
            Section {
                ForEach(store.sessions) { session in
                    NavigationLink {
                        SessionDetailView(sessionID: session.id).modifier(InSidebarColumn())
                    } label: {
                        SessionRow(session: session)
                    }
                }
            } header: {
                if showsHeader { Text("会话").textCase(nil) }
            }
        }
    }
}

/// The list on a page of its own (the place it lives is still being
/// decided; for now the demo opens it).
struct SessionsListPage: View {
    var body: some View {
        List { SessionsSection(showsHeader: false) }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
    }
}

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
        .accessibilityValue(Copy.contextSize(session.contextTokens).map { "上下文 \($0)" } ?? "")
    }

    /// 「等你 · 想运行 npm run build」.
    private var secondLine: String {
        let line = Copy.sessionLine(session)
        let status = Copy.sessionStatus(session.status)
        return line.isEmpty ? status : "\(status) · \(line)"
    }
}

/// 在忙 green, 等你 orange, 空闲 gray, 已停 an empty ring. A symbol, so it
/// sits on the text's baseline beside a name.
struct SessionStatusDot: View {
    let status: CCSessionStatus
    var size: CGFloat = 9

    var body: some View {
        let open = status == .stopped || status == .unknown
        Image(systemName: open ? "circle" : "circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(open ? Color.secondary : Copy.sessionStatusColor(status))
            .accessibilityHidden(true)
    }
}

/// 帮手 / 终端 / 后台: a small neutral tag.
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

/// 「网站帮手 想运行」 / 「数据清洗 问你」 on top of a session's card; opens
/// that session's page when it's known.
struct SessionSourceLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let text: String
    /// nil: just the words (the session's own page).
    let sessionID: String?

    var body: some View {
        if let sessionID, store.session(id: sessionID) != nil {
            Button { model.openSession(sessionID) } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("看这个会话")
        } else {
            label
        }
    }

    private var label: some View {
        Label(text, systemImage: "terminal")
            .labelStyle(QuietLabelStyle())
            .lineLimit(1)
    }
}
