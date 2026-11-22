import PaloAllyKit
import SwiftUI

/// A permission prompt, on the one card for what waits on the owner
/// (PendingCard): who asks · what it wants to do · why, the command or what
/// it touches, then 拒绝 / 允许 (and 以后都允许 when the harness offers a
/// rule). A session's card that waited past the hook's limit stays,
/// untappable, as 「在电脑上等你」 until it's settled there. Decided, it
/// folds to one line; tapping it shows what it was.
struct ApprovalCard: View {
    @Environment(AppStore.self) private var store
    let approval: Approval
    /// Kept for the callers (the session's page no longer differs).
    var linksSource = true
    @State private var decision = PendingDecider()
    @State private var expanded = false
    /// The detail's height as shown, and as it would be whole: folded when
    /// the whole is taller.
    @State private var shownHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    /// A session's card that expired here: the session asks at the computer now.
    private var waitsAtComputer: Bool { store.waitsAtComputer(approval) }
    private var item: PendingItem? { store.pendingItem(for: .approval(approval.id)) }
    /// A long command folds to this many lines until 展开.
    private static let foldedLines = 6

    var body: some View {
        Group {
            if approval.isPending || waitsAtComputer { open } else { folded }
        }
        .animation(.snappy, value: approval.status)
        .accessibilityIdentifier("approval-\(approval.id)")
    }

    private var header: PendingCardHeader {
        PendingCardHeader(item: item, who: approval.source?.name ?? store.assistantName, createdAt: approval.createdAt, blocking: true)
    }

    private var open: some View {
        PendingCard(header: header, title: title, background: background, error: decision.error) {
            detail
            if let taskId = approval.taskId, let task = store.task(id: taskId) {
                Text("为了「\(task.title)」")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if approval.careful {
                Label("这一步需要你仔细看一下。", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } actions: {
            if waitsAtComputer {
                Label(Copy.waitsAtComputer(approval.note), systemImage: "laptopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    PendingChoiceButtons(choices: [PendingChoiceButton(title: String(localized: "拒绝"), choice: .deny),
                                                   PendingChoiceButton(title: String(localized: "允许"), choice: .allow(remember: false), primary: true)],
                                         working: decision.working, pick: decide)
                    if approval.canRemember {
                        Button { decide(.allow(remember: true)) } label: {
                            Text(rememberTitle).font(.footnote).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                        .disabled(decision.working != nil)
                    }
                }
            }
        }
    }

    /// What it wants: the harness' words for the tool.
    private var title: String { approval.title.isEmpty ? String(localized: "需要你点个头") : approval.title }

    /// Why, when the harness says.
    private var background: String? {
        let reason = approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? nil : reason
    }

    /// The command whole (folded when long, 展开全部), or what it touches.
    @ViewBuilder private var detail: some View {
        if !approval.detail.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(approval.detail)
                    .font(detailFont)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    // The tail of a long command is often the part that matters: 展开 shows it.
                    .lineLimit(expanded ? nil : Self.foldedLines)
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
        }
    }

    /// Decided: 「✓ 已允许：运行一条命令」; tapping shows the command.
    private var folded: some View {
        PendingFoldedLine(text: String(localized: "\(Copy.approvalStatus(approval.status))：\(title)"), done: approval.status == .allowed,
                          hasDetail: !approval.detail.isEmpty) {
            Text(approval.detail)
                .font(detailFont)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Folded now, or unfolded by the owner: 展开全部 / 收起.
    private var foldable: Bool { expanded || wholeHeight > shownHeight + 1 }

    /// A command in a code face, smaller so more of it fits a line.
    private var detailFont: Font { Friendly.runsCommand(approval.tool) ? .footnote.monospaced() : .callout }

    private var rememberTitle: String {
        if let scope = approval.friendlyScope {
            return String(localized: "以后都允许：\(scope)")
        }
        return String(localized: "以后这类都允许")
    }

    private func decide(_ choice: PendingChoice) {
        PendingDecider.run(store, .approval(approval.id), choice, into: $decision)
    }
}
