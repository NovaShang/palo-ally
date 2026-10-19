import PaloAllyKit
import SwiftUI

/// The assistant proposes a helper (sessions-prd §4.4): its name, folder,
/// what it's for and its daily limit, then 不用 / 开吧. Nothing starts until
/// 开吧, the one button in the theme color. Once answered it stays, saying
/// so; a started helper opens from here.
struct HelperProposalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let proposal: HelperProposal

    @State private var working: HelperDecideAction?
    @State private var error: String?

    /// The Pal it opened (pals-prd §6), once it's on the list.
    private var openedPal: Pal? {
        if let id = proposal.palId, let p = store.pal(id: id) { return p }
        guard let sid = proposal.sessionId else { return nil }
        return store.pal(sessionId: sid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProposalHeader(symbol: "person.badge.plus", title: proposal.name.isEmpty ? String(localized: "帮手") : proposal.name,
                           dimmed: proposal.status == .discarded, state: state)

            VStack(alignment: .leading, spacing: 6) {
                if !proposal.cwd.isEmpty {
                    ProposalFact(name: String(localized: "目录"), value: CCSession.shortPath(proposal.cwd))
                }
                if !proposal.duty.isEmpty {
                    ProposalFact(name: String(localized: "负责"), value: proposal.duty)
                }
                if let limit = Copy.dailyLimit(proposal.dailyUsd) {
                    ProposalFact(name: String(localized: "花费"), value: limit)
                }
            }

            if proposal.isPending {
                if let note = proposal.note, !note.isEmpty {
                    // The last 开吧 didn't start it: why, and it's still on offer.
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("开了以后，它是电脑上的一个后台会话，随时能停。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProposalButtons(no: String(localized: "不用"), yes: String(localized: "开吧"), yesWorking: String(localized: "正在开…"), working: working,
                                enabled: store.connection.isOnline, decide: decide)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else if proposal.status != .created, let note = proposal.note, !note.isEmpty {
                // Why it didn't start.
                ProposalNote(text: note)
            } else if proposal.status == .created, let pal = openedPal {
                OpenPalButton { model.openPal(pal.id) }
            }
        }
        .modifier(ProposalCardStyle(pending: proposal.isPending))
        .animation(.snappy, value: proposal.status)
    }

    private var state: String? {
        switch proposal.status {
        case .pending, .unknown: nil
        case .created: String(localized: "已经开了")
        case .discarded: String(localized: "没开")
        case .expired: String(localized: "过期了")
        }
    }

    private func decide(_ action: HelperDecideAction) {
        working = action
        error = nil
        Task {
            do {
                try await store.decideHelper(proposal, action)
            } catch {
                self.error = action == .create ? String(localized: "没开成：\(Copy.error(error))") : String(localized: "没发出去：\(Copy.error(error))")
            }
            working = nil
        }
    }
}

// MARK: - the pieces both proposal cards are made of

/// A proposal card's look: on the conversation's secondary background, with
/// a thin outline while it waits on the owner. Content, not chrome: no glass.
struct ProposalCardStyle: ViewModifier {
    let pending: Bool

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(pending ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
            }
    }
}

/// A glyph, what's proposed, and once answered how it went (small, on the right).
struct ProposalHeader: View {
    let symbol: String
    let title: String
    var dimmed = false
    let state: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let state {
                Text(state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentTransition(.opacity)
            }
        }
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

/// No, then yes: yes is the one button in the theme color.
struct ProposalButtons: View {
    let no: String
    let yes: String
    let yesWorking: String
    let working: HelperDecideAction?
    let enabled: Bool
    let decide: (HelperDecideAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                decide(.discard)
            } label: {
                Text(no).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            Button {
                decide(.create)
            } label: {
                Text(working == .create ? yesWorking : yes).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(working != nil || !enabled)
    }
}

/// Why it didn't happen, in the computer's words.
struct ProposalNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 「去看看它 ›」: the Pal it became.
struct OpenPalButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label("去看看它", systemImage: "chevron.right")
                .labelStyle(TrailingIconLabelStyle())
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .tint(.primary)
    }
}

/// Words first, then the glyph: 「去看看它 ›」.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.caption.weight(.semibold))
        }
    }
}
