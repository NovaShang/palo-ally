import PaloAllyKit
import SwiftUI

/// The list (pals-prd §3): the assistant on top; Pals (the ones PaloAlly
/// hosts, then the computer's other live Claude Code sessions, dimmer, with
/// 接管, then 最近的对话 for the ones that ended); Allies, with 添加; and
/// last, quietly, 电脑与设备 (docs/devices-prd.md). Each row says on its
/// right how many things wait on the owner there. With several computers
/// paired, the assistant's name on the first row switches between them.
/// Phones: one step back from a conversation, like Messages; iPads and the
/// Mac: the sidebar.
struct ConversationList: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// 重命名 asked from a Pal's row (pals-prd §13).
    @State private var renaming: Pal?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            PaloRow()
                .tag(AppModel.Conversation.palo)
                .accessibilityIdentifier("row-palo")

            if store.palsSupported == true {
                Section {
                    // Awake ones first, then those asleep; a long list just scrolls.
                    ForEach(store.listedPals) { pal in
                        PalRow(pal: pal)
                            .tag(AppModel.Conversation.pal(pal.id))
                            .accessibilityIdentifier("row-pal-\(pal.id)")
                            .contextMenu {
                                Button("重命名", systemImage: "pencil") { renaming = pal }
                                    .disabled(!store.connection.isOnline)
                            }
                    }
                    // Tapped: its conversation, read only, with 接管 there (§14).
                    ForEach(store.otherSessions) { session in
                        OtherSessionRow(session: session)
                            .tag(AppModel.Conversation.session(session.id))
                    }
                    RecentListRow()
                        .tag(AppModel.Conversation.recent)
                        .accessibilityIdentifier("row-recent")
                } header: {
                    Text("Pals").textCase(nil)
                } footer: {
                    if store.pals.isEmpty && store.otherSessions.isEmpty {
                        Text("电脑上开着的 Claude Code 会出现在这里。接管以后，在手机上接着跟它说。")
                    }
                }
            }

            if store.alliesSupported != false {
                Section {
                    ForEach(store.allies) { ally in
                        AllyListRow(ally: ally)
                            .tag(AppModel.Conversation.ally(ally.id))
                            .accessibilityIdentifier("row-ally-\(ally.id)")
                    }
                    Button {
                        model.showAllyInvite = true
                    } label: {
                        // Neutral: the theme color is for 发送.
                        Label {
                            Text("添加").foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: "plus").foregroundStyle(Color.primary)
                        }
                    }
                    .tint(.primary)
                    .disabled(!store.connection.isOnline)
                } header: {
                    Text("Allies").textCase(nil)
                } footer: {
                    if store.allies.isEmpty {
                        Text("当面扫个码，你的助理就能和对方的助理互相传话、约时间。")
                    }
                }
            }

            // The computers and the devices paired with them: quiet, last.
            Section {
                DevicesListRow()
                    .tag(AppModel.Conversation.devices)
                    .accessibilityIdentifier("row-devices")
            }
        }
        // The Mac's sidebar has no title of its own; phones and iPads name the app.
        .navigationTitle(Platform.barInWindowToolbar ? "" : "PaloAlly")
        .toolbar(Platform.barInWindowToolbar ? .hidden : .automatic, for: .navigationBar)
        .modifier(MacSidebarToggle())
        .palRename($renaming)
        .animation(.snappy, value: store.pals)
        .animation(.snappy, value: store.otherSessions)
        .animation(.snappy, value: store.adoptions)
    }
}

/// The Mac: the window toolbar has the system sidebar toggle (MacToolbar);
/// the column doesn't add a second one.
private struct MacSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

// MARK: - rows

/// How many things wait on the owner in a conversation: an orange count on
/// the row's right (orange is what 「等你」 looks like everywhere in the app).
struct WaitingBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 22)
                .background(.orange, in: .capsule)
                .accessibilityLabel("\(count) 件等你")
        }
    }
}

/// The assistant: its avatar and name; what it's doing when it isn't idle,
/// else what was said last; what waits on the owner.
private struct PaloRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        let line = store.agentStatusLine
        HStack(spacing: 12) {
            AssistantAvatar(theme: model.currentTheme, hostID: model.activeHostID, bleed: 1.3)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.hasSeveralHosts {
                        AssistantSwitcher(name: name)
                    } else {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let ts = lastMessage?.ts, ts > 0 {
                        Text(Copy.relative(ts))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(secondLine(line))
                        .font(.subheadline)
                        .foregroundStyle(line.kind == .offline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    WaitingBadge(count: waiting)
                }
            }
        }
        .padding(.vertical, 4)
        // Several computers: the switcher in it is a control of its own.
        .accessibilityElement(children: model.hasSeveralHosts ? .contain : .combine)
    }

    private var name: String { store.assistantName.isEmpty ? "Palo" : store.assistantName }

    private var lastMessage: ChatMessage? {
        store.messages.last { $0.seq > 0 && $0.kind != .approval }
    }

    /// Working or offline: the state, as the orb's caption says it.
    /// Otherwise what was said last (what waits on the owner is the count).
    private func secondLine(_ line: AgentStatusLine) -> String {
        guard line.kind != .working, line.kind != .offline, let m = lastMessage else {
            return line.kind == .needsYou ? String(localized: "等你") : line.text
        }
        let text = m.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return line.text }
        return m.role == .user ? String(localized: "你：\(text)") : text
    }

    /// Cards, drafts and proposals waiting in its conversation, and tasks
    /// that need the owner.
    private var waiting: Int {
        store.pendingApprovals.count + store.pendingQuestions.count + store.pendingAllyDrafts.count
            + store.pendingProposalCount + store.tasks.filter { $0.status == .needsInput }.count
    }
}

/// Several computers paired: the assistant's name with a ⌄, a system menu
/// of every assistant (the current one ticked, a dot on one with something
/// new or waiting) and 电脑与设备… (docs/devices-prd.md §2).
private struct AssistantSwitcher: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(model.hostIDs, id: \.self) { id in
                    Button {
                        withAnimation(.snappy) { model.switchTo(id) }
                    } label: {
                        let label = model.assistantLabel(id)
                        let waiting = model.pendingCount(id)
                        let unread = model.unreadCount(id)
                        if id == model.activeHostID {
                            Label(label, systemImage: "checkmark")
                        } else if waiting > 0 || unread > 0 {
                            // A small dot, and what it is under the name.
                            Text(label)
                            Text(waiting > 0 ? String(localized: "\(waiting) 件等你") : String(localized: "有新消息"))
                            Image(systemName: "circlebadge.fill")
                        } else {
                            Text(label)
                        }
                    }
                    .accessibilityIdentifier("switch-\(id)")
                }
                Divider()
                Button("电脑与设备…", systemImage: "desktopcomputer") { model.open(.devices) }
            } label: {
                if Platform.isMac {
                    // The Mac draws a menu's label as a button's title, and
                    // its own ⌄ after it (menuIndicator).
                    Text(name).font(.body.weight(.semibold))
                } else {
                    HStack(spacing: 3) {
                        Text(name).font(.body.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .contentShape(.rect)
                }
            }
            .menuIndicator(Platform.isMac ? .visible : .hidden)
            .buttonStyle(.borderless)
            .tint(.primary)
            .fixedSize()
            .accessibilityIdentifier("assistant-switcher")
            .accessibilityLabel("\(name)，切换助理")
            // Something new or waiting on another assistant.
            if model.othersNeedAttention {
                Circle().fill(.orange).frame(width: 6, height: 6).accessibilityHidden(true)
            }
        }
    }
}

/// 电脑与设备: the last row, quiet (secondary), like 最近的对话.
private struct DevicesListRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 40)
                .accessibilityHidden(true)
            Text("电脑与设备")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 最近的对话 (pals-prd §10): the conversations that ended on the computer
/// lately, to take over. A plain row, neutral like 添加; its glyph and words
/// line up with the Pals' tiles and names above.
private struct RecentListRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .frame(width: 40)
                .accessibilityHidden(true)
            Text("最近的对话")
                .foregroundStyle(Color.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The round tile on a Pal's or a session's row: a terminal glyph, its
/// state as a dot; asleep, a quiet moon in its place.
struct PalTile: View {
    let dot: Color?
    var asleep = false
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "apple.terminal")
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.fill.tertiary, in: .circle)
            .overlay(alignment: .bottomTrailing) {
                if asleep {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: size * 0.24, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .background(Color(.secondarySystemGroupedBackground), in: .circle)
                        .offset(x: size * 0.08, y: size * 0.08)
                } else if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: max(1.5, size * 0.05)))
                        .offset(x: size * 0.02, y: size * 0.02)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A Pal: its name and folder, its state and last words, what waits on the owner.
private struct PalRow: View {
    @Environment(AppStore.self) private var store
    let pal: Pal

    var body: some View {
        HStack(spacing: 12) {
            PalTile(dot: Copy.palStatusColor(pal.status), asleep: pal.isAsleep)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pal.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(pal.shortCwd)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                HStack(spacing: 6) {
                    Text(Copy.palLine(pal))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    WaitingBadge(count: store.palPendingCount(pal.id))
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// One of the computer's other live sessions: dimmer, with its state, and
/// 接管. Adopting it happens in place: a moment's wait, or (a terminal
/// session) the line asking the owner to quit it there, with 取消.
private struct OtherSessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let session: CCSession

    var body: some View {
        let adoption = store.adoptions[session.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PalTile(dot: Copy.sessionStatusColor(session.status) == .clear ? nil : Copy.sessionStatusColor(session.status))
                    .opacity(0.7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.displayName)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        SessionKindTag(kind: session.kind)
                    }
                    Text(secondLine(adoption))
                        .font(.subheadline)
                        .foregroundStyle(failed(adoption) ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                        .lineLimit(failed(adoption) ? 3 : 1)
                }
                Spacer(minLength: 4)
                trailing(adoption)
            }
            if store.waitsForExit(session) {
                waitingForExit
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row-session-\(session.id)")
    }

    private func failed(_ a: PalAdoption?) -> Bool { if case .failed? = a { return true } else { return false } }

    private func secondLine(_ a: PalAdoption?) -> String {
        switch a {
        case .working?: return String(localized: "正在接管…")
        case .failed(let why)?: return why
        default:
            let line = Copy.sessionLine(session)
            let status = Copy.sessionStatus(session.status)
            return line.isEmpty ? status : "\(status) · \(line)"
        }
    }

    @ViewBuilder
    private func trailing(_ a: PalAdoption?) -> some View {
        switch a {
        case .working?:
            ProgressView()
        case .waitingForExit?:
            EmptyView()
        case nil where store.waitsForExit(session):
            EmptyView()
        case .failed?:
            Button("好") { store.clearAdoption(sessionId: session.id) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.secondary)
        case nil:
            Button("接管") { adopt() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.primary)
                .disabled(!store.connection.isOnline)
                .accessibilityIdentifier("adopt-\(session.id)")
                .accessibilityHint("让 PaloAlly 接着跑它，在手机上跟它说话")
        }
    }

    /// A terminal session: quit it there first; PaloAlly carries on by itself.
    private var waitingForExit: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("请在终端里输入 /exit 退出它，退出后自动接管")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // The host stops waiting too: quitting it later adopts nothing.
            Button("取消") { Task { await store.cancelAdoption(sessionId: session.id) } }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.secondary)
                .accessibilityIdentifier("adopt-cancel-\(session.id)")
        }
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adopt-waiting-\(session.id)")
    }

    private func adopt() {
        Task {
            if case .adopted(let pal)? = try? await store.adopt(sessionId: session.id) {
                model.openPal(pal.id)
            }
        }
    }
}

/// An Ally, with their drafts waiting for 发送.
private struct AllyListRow: View {
    @Environment(AppStore.self) private var store
    let ally: AllyInfo

    var body: some View {
        HStack(spacing: 8) {
            AllyRow(ally: ally, assistant: store.assistantName)
            WaitingBadge(count: store.pendingAllyDrafts.filter { $0.allyId == ally.id }.count)
        }
    }
}
