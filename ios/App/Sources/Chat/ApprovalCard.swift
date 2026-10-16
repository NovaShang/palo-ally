import PaloAllyKit
import SwiftUI

/// "Needs your OK" card. Shown inline in the chat and in the 审批 tab. One
/// from a Claude Code session on the computer says so on top (「网站帮手
/// 想运行」); once it waited past the hook's limit it stays, untappable, as
/// 「在电脑上等你」 until it's settled there.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let approval: Approval
    /// The source label opens that session's page (not on the page itself).
    var linksSource = true
    @State private var working = false
    @State private var error: String?
    @State private var expanded = false
    /// The detail's height as shown, and as it would be whole: folded when
    /// the whole is taller.
    @State private var shownHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    /// A session's card that expired here: the session asks at the computer now.
    private var waitsAtComputer: Bool { store.waitsAtComputer(approval) }
    private var fromSession: Bool { approval.source?.isSession == true }
    /// A session's long command folds to this many lines until 展开.
    private static let foldedLines = 6
    /// A session's command: its label already says 「X 想运行」, so no title
    /// row repeats it (unless the harness marked it as needing care).
    private var sessionCommand: Bool {
        fromSession && !approval.careful && Friendly.runsCommand(approval.tool) && (approval.isPending || waitsAtComputer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let asks = Copy.sessionAsks(approval) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    SessionSourceLabel(text: asks, sessionID: linksSource ? approval.source?.id : nil)
                    Spacer(minLength: 4)
                    if approval.isPending {
                        Text(Copy.relative(approval.createdAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !sessionCommand {
                HStack(spacing: 8) {
                    Image(systemName: approval.careful ? "exclamationmark.shield.fill" : "hand.raised.fill")
                        .foregroundStyle(approval.careful ? Color.orange : Color.secondary)
                    Text(approval.title.isEmpty ? String(localized: "需要你点个头") : approval.title)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if !approval.isPending && !waitsAtComputer {
                        Text(Copy.approvalStatus(approval.status))
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                }
            }

            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(detailFont)
                    .foregroundStyle(sessionCommand && approval.isPending ? .primary : .secondary)
                    .textSelection(.enabled)
                    // While pending show everything: the tail of a long
                    // command is often the part that matters. A session's
                    // long command folds, with 展开 to see it whole.
                    .lineLimit(expanded ? nil : (approval.isPending ? (fromSession ? Self.foldedLines : nil) : 3))
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                    .background(alignment: .topLeading) {
                        // The whole text, unseen, to know whether it folded.
                        Text(approval.detail)
                            .font(detailFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wholeHeight = $0 }
                    }
                if foldable {
                    Button(expanded ? String(localized: "收起") : String(localized: "展开全部")) { withAnimation(.snappy) { expanded.toggle() } }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                }
            }

            // A session's command needs no tool line: its label says it,
            // with the time.
            if !sessionCommand {
                HStack(spacing: 6) {
                    let tool = Copy.tool(approval.tool)
                    if !tool.isEmpty { Text(tool) }
                    if let taskId = approval.taskId, let task = store.task(id: taskId) {
                        Text("· 为了「\(task.title)」")
                    }
                    if approval.isPending && !fromSession { Text("· \(Copy.relative(approval.createdAt))") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            if waitsAtComputer {
                Label(Copy.waitsAtComputer(approval.note), systemImage: "laptopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if approval.isPending {
                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if approval.careful {
                    Label("这一步需要你仔细看一下。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        answer(allow: false)
                    } label: {
                        Text("拒绝").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary) // lighter than 允许; only the primary action carries the theme color

                    Button {
                        answer(allow: true)
                    } label: {
                        Text("允许").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(working)

                if approval.canRemember {
                    Button {
                        answer(allow: true, remember: true)
                    } label: {
                        Text(rememberTitle)
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .disabled(working)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(approval.isPending ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
        }
        .animation(.snappy, value: approval.status)
    }

    /// Folded now, or unfolded by the owner: 展开全部 / 收起.
    private var foldable: Bool { expanded || wholeHeight > shownHeight + 1 }

    /// A session's command in a code face, smaller so more of it fits a line.
    private var detailFont: Font { fromSession ? .footnote.monospaced() : .callout }

    private var rememberTitle: String {
        if let scope = approval.friendlyScope {
            return String(localized: "以后都允许：\(scope)")
        }
        return String(localized: "以后这类都允许")
    }

    private var statusColor: Color {
        switch approval.status {
        case .allowed: .green
        case .denied, .expired: .secondary
        default: .secondary
        }
    }

    private func answer(allow: Bool, remember: Bool = false) {
        working = true
        error = nil
        Task {
            do {
                try await store.answer(approval, allow: allow, remember: remember)
            } catch {
                self.error = String(localized: "没发出去：\(Friendly.message(error))")
            }
            working = false
        }
    }
}
