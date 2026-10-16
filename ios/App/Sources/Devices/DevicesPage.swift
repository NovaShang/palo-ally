import PaloAllyKit
import SwiftUI

/// 电脑与设备 (docs/devices-prd.md §3), the list's last row: the computers
/// paired here, each its own assistant (tap: switch; 重命名 and 解除配对 on a
/// long press, a right click or a swipe, unpairing asked in place), 添加另一台
/// 电脑; and the owner's devices paired with the current computer (this one
/// marked; another taken off after asking in place), 添加设备 with its QR code.
struct DevicesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    @State private var devices: [PairedDevice] = []
    @State private var loaded = false
    @State private var devicesError: String?
    /// 解除配对 asked in place, for this computer.
    @State private var confirmUnpair: String?
    @State private var unpairing: String?
    /// 移除 asked in place, for this device.
    @State private var confirmRemove: String?
    @State private var removing: String?
    @State private var problem: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var showInvite = false

    var body: some View {
        List {
            Section {
                ForEach(model.hostIDs, id: \.self) { id in
                    hostRow(id)
                    if confirmUnpair == id {
                        ConfirmPanel(title: "解除和「\(model.displayName(id))」的配对？",
                                     text: "之后要重新配对才能连回来。那台电脑上的对话和记忆不受影响。",
                                     action: "解除配对", working: unpairing == id, glass: false,
                                     cancel: { confirmUnpair = nil },
                                     confirm: { Task { await unpair(id) } })
                            .transition(.opacity)
                    }
                }
                if model.mode == .demo {
                    Button("退出演示，去配对") { model.exitDemo() }
                        .tint(.primary)
                } else {
                    Button {
                        model.startPairing(.add)
                    } label: {
                        Label { Text("添加另一台电脑").foregroundStyle(Color.primary) } icon: { Image(systemName: "plus").foregroundStyle(Color.primary) }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("add-computer")
                }
            } header: {
                Text("我的助理")
            } footer: {
                if !model.hasSeveralHosts {
                    Text("每台电脑上是一个独立的助理：各自的对话、记忆和任务。")
                }
            }

            Section {
                if !loaded && devicesError == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(devices) { d in
                    deviceRow(d)
                    if confirmRemove == d.deviceId {
                        ConfirmPanel(title: "移除「\(d.label)」？",
                                     text: "它会断开，要重新配对才能连回来。",
                                     action: "移除", working: removing == d.deviceId, glass: false,
                                     cancel: { confirmRemove = nil },
                                     confirm: { Task { await remove(d) } })
                            .transition(.opacity)
                    }
                }
                if let devicesError {
                    Text(devicesError).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    showInvite = true
                } label: {
                    Label { Text("添加设备").foregroundStyle(Color.primary) } icon: { Image(systemName: "plus").foregroundStyle(Color.primary) }
                }
                .tint(.primary)
                .disabled(!store.connection.isOnline)
                .accessibilityIdentifier("add-device")
            } header: {
                Text("连着这台电脑的设备")
            } footer: {
                if model.hasSeveralHosts {
                    Text("这台电脑是「\(model.displayName(model.activeHostID ?? ""))」。")
                }
            }

            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .navigationTitle("电脑与设备")
        .navigationBarTitleDisplayMode(.inline)
        .macPageTop("电脑与设备")
        .animation(.snappy, value: confirmUnpair)
        .animation(.snappy, value: confirmRemove)
        .animation(.snappy, value: devices)
        .task(id: "\(model.activeHostID ?? "")-\(store.connection.isOnline)") { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showInvite, onDismiss: { Task { await load() } }) {
            DeviceInviteSheet(known: Set(devices.map(\.deviceId))).environment(store)
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("好") {
                if let id = renaming { model.rename(id, to: newName) }
                renaming = nil
            }
        } message: {
            Text("只改这台设备上看到的名字，比如「家里的 Mac」「云端」。留空就用电脑自己的名字。")
        }
        #if DEBUG
        // `-demoDevicesInvite YES`: opens on 添加设备 (snapshots).
        .task {
            if UserDefaults.standard.bool(forKey: "demoDevicesInvite") {
                try? await Task.sleep(for: .seconds(1))
                showInvite = true
            }
        }
        #endif
    }

    // MARK: rows

    private func hostRow(_ id: String) -> some View {
        let current = id == model.activeHostID
        let online = model.isOnline(id)
        let name = model.stores[id]?.assistantName.trimmingCharacters(in: .whitespaces) ?? ""
        return Button {
            withAnimation(.snappy) { model.switchTo(id) }
        } label: {
            HStack(spacing: 12) {
                AssistantAvatar(theme: model.theme(for: id), hostID: id, bleed: 1.3)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Palo" : name)
                        .font(.body.weight(current ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                    HStack(spacing: 5) {
                        Circle().fill(online ? Color.green : Color(.systemGray3)).frame(width: 6, height: 6)
                        Text("\(model.displayName(id)) · \(hostState(id))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if unpairing == id {
                    ProgressView()
                } else if current {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .accessibilityLabel("当前")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("host-\(id)")
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu { hostActions(id) }
        .swipeActions { hostActions(id) }
    }

    @ViewBuilder private func hostActions(_ id: String) -> some View {
        Button("重命名", systemImage: "pencil") {
            newName = model.displayName(id)
            renaming = id
        }
        if model.mode == .paired {
            Button("解除配对", systemImage: "link.badge.minus", role: .destructive) { confirmUnpair = id }
        }
    }

    private func hostState(_ id: String) -> String {
        guard let s = model.stores[id] else { return "离线" }
        if s.displayedConnection.isOnline { return model.mode == .demo ? "演示中" : "在线" }
        return Copy.connectionShort(s.displayedConnection)
    }

    private func deviceRow(_ d: PairedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: d.platform == "mac" ? "laptopcomputer" : d.platform == "ios" ? "iphone" : "display")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.label).foregroundStyle(Color.primary)
                    if d.current {
                        Text("这台")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                Text(deviceLine(d))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if removing == d.deviceId { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device-\(d.deviceId)")
        .contextMenu {
            if !d.current {
                Button("移除", systemImage: "minus.circle", role: .destructive) { confirmRemove = d.deviceId }
            }
        }
        .swipeActions {
            if !d.current {
                Button("移除", role: .destructive) { confirmRemove = d.deviceId }
            }
        }
    }

    /// 「iOS · 最后在线 3 小时前」.
    private func deviceLine(_ d: PairedDevice) -> String {
        let platform = d.platform == "mac" ? "Mac" : d.platform == "ios" ? "iOS" : ""
        let seen: String
        if d.current || d.online { seen = "在线" }
        else if let t = d.lastSeen, t > 0 { seen = "最后在线 \(Copy.relative(t))" }
        else { seen = "还没连过" }
        return [platform, seen].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: actions

    private func load() async {
        guard store.connection.isOnline else { return }
        do {
            devices = try await store.listDevices()
            devicesError = nil
        } catch {
            // An older computer doesn't list them.
            devicesError = "电脑上的 PaloAlly 更新以后，这里能看到连着它的设备。"
        }
        loaded = true
    }

    private func unpair(_ id: String) async {
        unpairing = id
        await model.unpair(id)
        unpairing = nil
        confirmUnpair = nil
    }

    private func remove(_ d: PairedDevice) async {
        removing = d.deviceId
        defer { removing = nil }
        do {
            try await store.removeDevice(id: d.deviceId)
            confirmRemove = nil
            devices.removeAll { $0.deviceId == d.deviceId }
            problem = nil
        } catch {
            problem = "没移除成：\(Copy.error(error))"
        }
    }
}

/// 添加设备: a link from this computer for one more of the owner's devices
/// (pair.invite, 5 minutes, one device), as a QR code and as the link to copy
/// or share. Says so once a new device shows up.
struct DeviceInviteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The devices there before: a new one means it worked.
    let known: Set<String>

    @State private var invite: PairInviteResult?
    @State private var code: UIImage?
    @State private var loading = false
    @State private var error: String?
    @State private var added: PairedDevice?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let added {
                        done(added)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let expired = invite.map { ctx.date.epochMillis >= $0.expiresAt } ?? false
                            VStack(spacing: 14) {
                                qr(expired: expired)
                                Text(expiryLine(now: ctx.date))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .accessibilityIdentifier("invite-expiry")
                                if expired && !loading {
                                    Button("再生成一个") { Task { await load() } }
                                        .buttonStyle(.bordered)
                                        .buttonBorderShape(.capsule)
                                        .tint(.primary)
                                }
                            }
                        }
                        Text("用另一台设备扫码，或者在那台设备上点开链接")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                        if let invite {
                            linkBox(invite.link)
                        }
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
            .navigationTitle("添加设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .tint(.primary)
                }
            }
        }
        .presentationSizing(.form)
        .task(id: store.connection.isOnline) {
            if store.connection.isOnline && invite == nil && !loading { await load() }
        }
        // A new device paired while the code is up: say so.
        .task(id: invite?.link) {
            guard invite != nil else { return }
            while !Task.isCancelled && added == nil {
                try? await Task.sleep(for: .seconds(3))
                if let list = try? await store.listDevices(), let new = list.first(where: { !known.contains($0.deviceId) && !$0.current }) {
                    withAnimation(.snappy) { added = new }
                }
            }
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
                    .accessibilityLabel("配对二维码")
                    .accessibilityIdentifier("device-qr")
            } else if loading {
                ProgressView().tint(.gray)
            }
            if expired {
                Text("已过期")
                    .font(.headline)
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .frame(width: 240, height: 240)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func linkBox(_ link: String) -> some View {
        VStack(spacing: 10) {
            Text(link)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = link
                    copied = true
                } label: {
                    Label(copied ? "拷贝好了" : "拷贝", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("invite-copy")
                ShareLink(item: link) { Label("共享", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
        }
    }

    private func done(_ d: PairedDevice) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("加好了")
                .font(.title3.weight(.semibold))
            Text("「\(d.label)」已经连上这台电脑。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    /// 「还剩 4:32，只能用一次」.
    private func expiryLine(now: Date) -> String {
        guard let invite, invite.expiresAt > 0 else {
            if loading { return "正在生成…" }
            return store.connection.isOnline ? " " : "还没连上你的电脑，连上就生成"
        }
        let left = Int((Double(invite.expiresAt - now.epochMillis) / 1000).rounded(.up))
        if left <= 0 { return "这个二维码过期了" }
        return "还剩 \(left / 60):\(String(format: "%02d", left % 60))，只能用一次"
    }

    private func load() async {
        loading = true
        error = nil
        copied = false
        defer { loading = false }
        do {
            let r = try await store.pairInvite()
            invite = r
            code = QRCode.image(for: r.link)
        } catch {
            self.error = "没生成出来：\(Copy.error(error))"
        }
    }
}
