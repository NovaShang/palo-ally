import PaloAllyKit
import SwiftUI

/// An Ally's invite, opened from the system Camera (`paloally://ally?…`).
struct PendingAllyInvite: Identifiable, Equatable {
    let id = UUID()
    let link: String
    var parsed: AllyInviteLink? { AllyInviteLink.parse(link) }
}

/// 「加「X的助理」为 Ally？」 with the tag (家人朋友 / 我的), then this
/// computer pairs with theirs both ways. Progress and failures in plain words.
struct AllyAcceptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pending: PendingAllyInvite

    private enum Phase: Equatable { case asking, working, added(AllyInfo), failed(String) }
    @State private var phase = Phase.asking
    @State private var kind = AllyKind.family

    private var invite: AllyInviteLink? { pending.parsed }
    private var label: String { AllyInfo.assistantLabel(invite?.name ?? "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let invite {
                        content(invite)
                    } else {
                        problem("这个链接不完整", "请对方在 TA 的 PaloAlly 里重新点「添加」，再扫一次新的二维码。")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("添加 Ally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .added = phase {
                        EmptyView()
                    } else {
                        Button("取消") { dismiss() }
                            .tint(.primary)
                    }
                }
                if case .added = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .tint(.primary)
                    }
                }
            }
        }
        .presentationSizing(.form)
        .interactiveDismissDisabled(phase == .working)
    }

    @ViewBuilder
    private func content(_ invite: AllyInviteLink) -> some View {
        Text(String((invite.name.isEmpty ? "?" : invite.name).prefix(1)))
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 72, height: 72)
            .background(.fill.tertiary, in: .circle)
            .accessibilityHidden(true)

        switch phase {
        case .added(let ally):
            VStack(spacing: 10) {
                Label("加好了", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                Text(Copy.spaced("以后想跟\(ally.displayName)说什么、约什么时间，告诉\(store.assistantName)就行。发出去的每句话都先给你看。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        default:
            if invite.isExpired() && phase == .asking {
                problem("这个二维码过期了", "请对方重新点「添加」，生成一个新的再扫。")
            } else {
                question(invite)
            }
        }
    }

    @ViewBuilder
    private func question(_ invite: AllyInviteLink) -> some View {
        VStack(spacing: 8) {
            Text("加「\(label)」为 Ally？")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(Copy.spaced("加好以后，\(store.assistantName)和 TA 的助理可以互相传话、约时间。发出去的每句话都先给你看。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.hasSeveralHosts {
                Text("加到「\(store.assistantName)」").font(.footnote).foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("标为").font(.footnote).foregroundStyle(.secondary)
            Picker("标为", selection: $kind) {
                Text("家人朋友").tag(AllyKind.family)
                Text("我的").tag(AllyKind.mine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(kind == .mine ? "你自己的另一台电脑。" : "别人的助理，比如家里人、朋友。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(phase == .working)

        VStack(spacing: 12) {
            Button {
                Task { await accept(invite) }
            } label: {
                Text(phase == .working ? "正在加…" : "加为 Ally").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(phase == .working || !store.connection.isOnline)

            if phase == .working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在和对方的电脑互相认识，一般几秒钟…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let message) = phase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if !store.connection.isOnline {
                Text("还没连上你的电脑，连上就能加。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func problem(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func accept(_ invite: AllyInviteLink) async {
        guard !invite.isExpired() else {
            phase = .failed("这个二维码刚刚过期了，请对方重新生成一个。")
            return
        }
        phase = .working
        do {
            if let ally = try await store.acceptAlly(link: invite.link, kind: kind) {
                withAnimation(.snappy) { phase = .added(ally) }
            } else {
                phase = .failed("没加上：电脑没说加好了没有，等一下看看列表里有没有 TA。")
            }
        } catch {
            phase = .failed("没加上：\(Copy.error(error))")
        }
    }
}
