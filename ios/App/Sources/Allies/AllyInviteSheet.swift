import PaloAllyKit
import SwiftUI

/// 添加: an invite from this computer as a QR code, made on the device, for
/// the other person to scan with their iPhone's Camera. Ten minutes, one use.
/// Says so the moment they've been added.
struct AllyInviteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var invite: AllyInviteResult?
    @State private var code: UIImage?
    @State private var loading = false
    @State private var error: String?
    /// Who was there once the list had come in: someone new after that means
    /// they scanned it.
    @State private var known: Set<String>?
    @State private var added: AllyInfo?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let added {
                        done(added)
                    } else {
                        Text("让对方用 iPhone 相机扫")
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let expired = invite.map { ctx.date.epochMillis >= $0.expiresAt } ?? false
                            VStack(spacing: 14) {
                                qr(expired: expired)
                                Text(expiryLine(now: ctx.date))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if expired && !loading {
                                    Button("再生成一个") { Task { await load() } }
                                        .buttonStyle(.bordered)
                                        .buttonBorderShape(.capsule)
                                        .tint(.primary)
                                }
                            }
                        }
                        Text("对方扫了以后，在 TA 的 PaloAlly 里点一下确认，你们的助理就能互相传话、约时间了。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        if let error {
                            VStack(spacing: 10) {
                                Text(error)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                Button("再试一次") { Task { await load() } }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .tint(.primary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("添加 Ally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .tint(.primary)
                }
            }
        }
        .presentationSizing(.form)
        .task {
            if store.alliesSupported == true { known = Set(store.allies.map(\.id)) }
        }
        // Made as soon as this device is connected to the computer.
        .task(id: store.connection.isOnline) {
            if store.connection.isOnline && invite == nil && !loading { await load() }
        }
        .onChange(of: store.allies.map(\.id)) { _, ids in
            guard added == nil else { return }
            // The list's first arrival is what was there, not a new Ally.
            guard let known else { known = Set(ids); return }
            guard let new = ids.first(where: { !known.contains($0) }) else { return }
            withAnimation(.snappy) { added = store.ally(id: new) }
        }
    }

    private func qr(expired: Bool) -> some View {
        ZStack {
            // White behind the code in either appearance: cameras read dark on light.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
            if let code {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .opacity(expired ? 0.12 : 1)
                    .accessibilityLabel("邀请二维码")
            } else if loading {
                ProgressView().tint(.gray)
            }
            if expired {
                Text("已过期")
                    .font(.headline)
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .frame(width: 260, height: 260)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func done(_ ally: AllyInfo) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("加好了")
                .font(.title3.weight(.semibold))
            Text("\(ally.assistantLabel)已经在你的 Allies 里了。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    /// 「18:12 前有效，只能用一次」; the last minute counts down.
    private func expiryLine(now: Date) -> String {
        guard let invite, invite.expiresAt > 0 else {
            if loading { return String(localized: "正在生成…") }
            return store.connection.isOnline ? " " : String(localized: "还没连上你的电脑，连上就生成")
        }
        let left = Double(invite.expiresAt - now.epochMillis) / 1000
        if left <= 0 { return String(localized: "这个二维码过期了") }
        if left < 60 { return String(localized: "还剩 \(Int(left.rounded(.up))) 秒，只能用一次") }
        return String(localized: "\(Copy.clock(invite.expiresAt)) 前有效，只能用一次")
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let r = try await store.inviteAlly()
            invite = r
            code = QRCode.image(for: r.link)
        } catch {
            self.error = String(localized: "没生成出来：\(Copy.error(error))")
        }
    }
}
