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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                Text(proposal.name.isEmpty ? "帮手" : proposal.name)
                    .font(.headline)
                    .foregroundStyle(proposal.status == .discarded ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let state {
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if !proposal.cwd.isEmpty {
                    row("目录", CCSession.shortPath(proposal.cwd))
                }
                if !proposal.duty.isEmpty {
                    row("负责", proposal.duty)
                }
                if let limit = Copy.dailyLimit(proposal.dailyUsd) {
                    row("花费", limit)
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
                HStack(spacing: 10) {
                    Button {
                        decide(.discard)
                    } label: {
                        Text("不用").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    Button {
                        decide(.create)
                    } label: {
                        Text(working == .create ? "正在开…" : "开吧").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(working != nil || !store.connection.isOnline)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else if proposal.status != .created, let note = proposal.note, !note.isEmpty {
                // Why it didn't start.
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if proposal.status == .created, let pal = openedPal {
                Button {
                    model.openPal(pal.id)
                } label: {
                    Label("去看看它", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(proposal.isPending ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
        }
        .animation(.snappy, value: proposal.status)
    }

    private func row(_ name: String, _ value: String) -> some View {
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

    private var state: String? {
        switch proposal.status {
        case .pending, .unknown: nil
        case .created: "已经开了"
        case .discarded: "没开"
        case .expired: "过期了"
        }
    }

    private func decide(_ action: HelperDecideAction) {
        working = action
        error = nil
        Task {
            do {
                try await store.decideHelper(proposal, action)
            } catch {
                self.error = action == .create ? "没开成：\(Copy.error(error))" : "没发出去：\(Copy.error(error))"
            }
            working = nil
        }
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
