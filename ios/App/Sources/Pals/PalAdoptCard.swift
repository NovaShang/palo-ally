import PaloAllyKit
import SwiftUI

/// The assistant proposes taking over a conversation that ended on the
/// computer (pals-prd §10, `pal_adopt`), on the one card for what waits on
/// the owner (PendingCard): 接管「标题」 and its folder, then 不用 / 接管.
/// Nothing is adopted until 接管, the one button in the theme color; it
/// answers as the helper proposal does (`helper.decide`). One the computer
/// couldn't take over says why and stays on offer. Answered, it folds to one
/// line; the agent it became opens from there.
struct PalAdoptCard: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let proposal: PalAdoptProposal

    @State private var decision = PendingDecider()

    /// The Pal it became, once it's on the list.
    private var adoptedPal: Pal? {
        if let id = proposal.palId, let p = store.pal(id: id) { return p }
        return proposal.status == .adopted ? store.pal(sessionId: proposal.sessionId) : nil
    }

    private var item: PendingItem? { store.pendingItem(for: .proposal(proposal.id)) }

    /// Waiting for 接管 / 不用, or tapped and not taken over (it can be again).
    private var onOffer: Bool { proposal.status == .pending || proposal.status == .failed }

    var body: some View {
        Group {
            if onOffer { open } else { folded }
        }
        .animation(.snappy, value: proposal.status)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pal-adopt-\(proposal.id)")
    }

    private var open: some View {
        PendingCard(header: PendingCardHeader(item: item, who: store.assistantName, createdAt: item?.createdAt ?? 0, blocking: false),
                    title: Copy.spaced(String(localized: "接手「\(proposal.displayTitle)」")),
                    background: String(localized: "接过来以后，它在这里接着聊。"),
                    error: decision.error) {
            if !proposal.cwd.isEmpty {
                ProposalFact(name: String(localized: "目录"), value: proposal.shortCwd)
            }
            if proposal.status == .failed, let note = proposal.note, !note.isEmpty {
                // The last 接管 didn't work: why, and it's still on offer.
                Text(Copy.spaced(String(localized: "没接成：\(note)")))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            PendingChoiceButtons(choices: ProposalWords.buttons(yes: String(localized: "接手")), working: decision.working,
                                 enabled: store.connection.isOnline, pick: decide)
        }
    }

    /// 「✓ 已经接过来了：标题 · 去看看它」, 「没接：…」, 「过期了：…」.
    private var folded: some View {
        let state: String = switch proposal.status {
        case .adopted: String(localized: "已经接过来了")
        case .discarded: String(localized: "没接")
        default: String(localized: "过期了")
        }
        let note = proposal.status != .adopted ? (proposal.note ?? "") : ""
        let title = proposal.displayTitle
        return PendingFoldedLine(text: Copy.spaced(note.isEmpty ? String(localized: "\(state)：\(title)") : String(localized: "\(state)：\(title) · \(note)")),
                                 done: proposal.status == .adopted,
                                 action: adoptedPal.map { pal in (String(localized: "去看看它"), { model.openPal(pal.id) }) })
    }

    private func decide(_ choice: PendingChoice) {
        PendingDecider.run(store, .proposal(proposal.id), choice, into: $decision) { reason in
            choice == .accept ? String(localized: "没接成：\(reason)") : String(localized: "没发出去：\(reason)")
        }
    }
}
