import PaloAllyKit
import SwiftUI

/// The assistant proposes an agent (sessions-prd §4.4), on the one card for
/// what waits on the owner (PendingCard): the assistant · what it proposes ·
/// what it'd do, its name and folder, then 不用 / 开吧. Nothing starts until
/// 开吧, the one button in the theme color. Answered, it folds to one line;
/// a started agent opens from there.
struct HelperProposalCard: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let proposal: HelperProposal
    /// What the assistant said with it (the card's question).
    var text: String = ""

    @State private var decision = PendingDecider()

    /// The Pal it opened (pals-prd §6), once it's on the list.
    private var openedPal: Pal? {
        if let id = proposal.palId, let p = store.pal(id: id) { return p }
        guard let sid = proposal.sessionId else { return nil }
        return store.pal(sessionId: sid)
    }

    private var item: PendingItem? { store.pendingItem(for: .proposal(proposal.id)) }
    private var name: String { proposal.name.isEmpty ? String(localized: "agent") : proposal.name }

    var body: some View {
        Group {
            if proposal.isPending { open } else { folded }
        }
        .animation(.snappy, value: proposal.status)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("helper-proposal-\(proposal.id)")
    }

    private var open: some View {
        PendingCard(header: PendingCardHeader(item: item, who: store.assistantName, createdAt: item?.createdAt ?? 0, blocking: false),
                    title: ProposalWords.title(item: item, text: text, fallback: String(localized: "开一个 agent：\(name)")),
                    background: proposal.duty.isEmpty ? nil : proposal.duty,
                    error: decision.error) {
            VStack(alignment: .leading, spacing: 4) {
                ProposalFact(name: String(localized: "名字"), value: name)
                if !proposal.cwd.isEmpty {
                    ProposalFact(name: String(localized: "目录"), value: CCSession.shortPath(proposal.cwd))
                }
            }
            if let note = proposal.note, !note.isEmpty {
                // The last 开吧 didn't start it: why, and it's still on offer.
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            PendingChoiceButtons(choices: ProposalWords.buttons(yes: String(localized: "开吧")), working: decision.working,
                                 enabled: store.connection.isOnline, pick: decide)
        }
    }

    /// 「✓ 已经开了：报销帮手 · 去看看它」, 「没开：…」, 「过期了：…」 (and why, when it says).
    private var folded: some View {
        let state: String = switch proposal.status {
        case .created: String(localized: "已经开了")
        case .discarded: String(localized: "没开")
        default: String(localized: "过期了")
        }
        let note = proposal.status != .created ? (proposal.note ?? "") : ""
        return PendingFoldedLine(text: note.isEmpty ? String(localized: "\(state)：\(name)") : String(localized: "\(state)：\(name) · \(note)"),
                                 done: proposal.status == .created,
                                 action: openedPal.map { pal in (String(localized: "去看看它"), { model.openPal(pal.id) }) })
    }

    private func decide(_ choice: PendingChoice) {
        PendingDecider.run(store, .proposal(proposal.id), choice, into: $decision) { reason in
            choice == .accept ? String(localized: "没开成：\(reason)") : String(localized: "没发出去：\(reason)")
        }
    }
}

// MARK: - what both proposal cards share

enum ProposalWords {
    /// What the card asks: the item's words (the assistant's line), else the card's own.
    static func title(item: PendingItem?, text: String, fallback: String) -> String {
        if let t = item?.title, !t.isEmpty { return t }
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? fallback : said
    }

    /// 不用, then the yes in the theme color.
    static func buttons(yes: String) -> [PendingChoiceButton] {
        [PendingChoiceButton(title: String(localized: "不用"), choice: .decline),
         PendingChoiceButton(title: yes, choice: .accept, primary: true)]
    }
}

/// One fact on a proposal card: what it is, then its value.
struct ProposalFact: View {
    let name: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
