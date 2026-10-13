import PaloAllyKit
import SwiftUI

/// The assistant proposes taking over a conversation that ended on the
/// computer (pals-prd §10, `pal_adopt`): 接管「标题」 and its folder, then
/// 不用 / 接管. Nothing is adopted until 接管, the one button in the theme
/// color. The helper proposal's card, in look and in how it answers
/// (`helper.decide`); once answered it stays, saying so, and the Pal it
/// became opens from here. One the computer couldn't take over says why and
/// stays on offer.
struct PalAdoptCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let proposal: PalAdoptProposal

    @State private var working: HelperDecideAction?
    @State private var error: String?

    /// The Pal it became, once it's on the list.
    private var adoptedPal: Pal? {
        if let id = proposal.palId, let p = store.pal(id: id) { return p }
        return proposal.status == .adopted ? store.pal(sessionId: proposal.sessionId) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProposalHeader(symbol: "clock.arrow.circlepath", title: Copy.spaced("接管「\(proposal.displayTitle)」"),
                           dimmed: proposal.status == .discarded, state: state)

            if !proposal.cwd.isEmpty {
                ProposalFact(name: "目录", value: proposal.shortCwd)
            }

            switch proposal.status {
            case .pending, .failed:
                if proposal.status == .failed, let note = proposal.note, !note.isEmpty {
                    // The last 接管 didn't work: why, and it's still on offer.
                    Text(Copy.spaced("没接成：\(note)"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("接过来以后，它会出现在 Pals 里，在手机上接着聊。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProposalButtons(no: "不用", yes: "接管", yesWorking: "接管中…", working: working,
                                enabled: store.connection.isOnline, decide: decide)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            case .adopted:
                if let pal = adoptedPal {
                    OpenPalButton { model.openPal(pal.id) }
                }
            case .discarded, .unknown:
                // Why it wasn't adopted, when the computer says.
                if let note = proposal.note, !note.isEmpty {
                    ProposalNote(text: note)
                }
            }
        }
        .modifier(ProposalCardStyle(pending: onOffer))
        .animation(.snappy, value: proposal.status)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pal-adopt-\(proposal.id)")
    }

    /// Waiting for 接管 / 不用, or tapped and not taken over (it can be again).
    private var onOffer: Bool { proposal.status == .pending || proposal.status == .failed }

    private var state: String? {
        switch proposal.status {
        case .pending, .failed, .unknown: nil
        case .adopted: "已经接过来了"
        case .discarded: "没接"
        }
    }

    private func decide(_ action: HelperDecideAction) {
        working = action
        error = nil
        Task {
            do {
                try await store.decideAdopt(proposal, action)
            } catch {
                self.error = action == .create ? "没接成：\(Copy.error(error))" : "没发出去：\(Copy.error(error))"
            }
            working = nil
        }
    }
}
