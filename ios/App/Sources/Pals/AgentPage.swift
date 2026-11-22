import PaloAllyKit
import SwiftUI

/// An agent's page (one kind of agent): a Claude Code session, whether the
/// host runs it (a Pal) or not yet (one of the computer's other sessions: in
/// a terminal, in the background, or a conversation that ended). Its
/// conversation is the assistant's conversation view on the agent's scoped
/// store (`palStore`, by the Pal's id or the session's): streaming, the
/// paced reveal, following the end, cards, the composer and voice, all the
/// same; what the owner types goes in as typed. A Pal's title is the
/// capsule that opens the details (rename, files, model, 归档…).
/// Typing to one that isn't a Pal takes it over (the host's `pals.send`);
/// one still open in a terminal is said so above the composer, and what's
/// typed waits until it's quit there (「终端那边退出后发出 · 取消这条」).
/// Once it's a Pal (here, from a card, on another device) its page opens.
struct AgentPage: View {
    enum Agent: Hashable {
        /// A Pal, by its id.
        case pal(String)
        /// One of the computer's sessions that isn't a Pal, by its session id.
        case session(String)
    }
    let agent: Agent
    /// In a workspace's tile: the tile's own header replaces the page's chrome.
    var inTile = false
    /// The assistant's store, which makes and feeds the agent's.
    @Environment(AppStore.self) private var store

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("AgentPage")
        #endif
        switch agent {
        case .pal(let id):
            AgentConversation(id: id, external: false, inTile: inTile)
                .environment(store.palStore(id))
        case .session(let id):
            AgentConversation(id: id, external: true, inTile: false)
                .environment(store.palStore(id))
        }
    }
}

private struct AgentConversation: View {
    /// The Pal's id, or the session id of one that isn't a Pal.
    let id: String
    /// Not a Pal (yet): one of the computer's other sessions.
    let external: Bool
    let inTile: Bool
    @Environment(WindowModel.self) private var model
    /// The agent's own store.
    @Environment(AppStore.self) private var store

    enum Panel: Equatable {
        case none
        /// Something didn't work: why.
        case notice(String)
    }
    @State private var panel = Panel.none
    /// The Pal as last seen: it leaves the list once archived or gone.
    @State private var last: Pal?

    private var pal: Pal? { external ? nil : store.singlePal(id: id) ?? last }
    /// One of the computer's sessions: what the lists say of it.
    private var session: (name: String, cwd: String, live: CCSession?)? { external ? store.viewedSession(id) : nil }
    /// No longer on the list (archived here or elsewhere, or gone at the computer).
    private var gone: Bool { !external && store.singlePalName(id: id) == nil && store.palsSupported == true }
    /// Words sent to it asleep: it's being woken (§12).
    private var waking: Bool { store.status?.busy == true && store.status?.activity == AppStore.wakingActivity }

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("AgentConversation")
        #endif
        ChatView(bottomPanel: bottom, aboveComposer: external ? terminalLine : nil,
                 pageTop: inTile ? nil : .init(subtitle: subtitle, dot: dot, capsule: !external),
                 inTile: inTile)
            .navigationSubtitle(external ? subtitle : "")
            // A tile shows nothing of it but its conversation: it doesn't
            // follow the session's every tick (its status line, context).
            .onChange(of: inTile || external ? nil : store.singlePal(id: id), initial: true) { _, p in if let p { last = p } }
            .onChange(of: inTile ? store.singlePalName(id: id) : nil, initial: true) {
                // Read after the update: read in it, the whole Pal was followed again.
                guard inTile else { return }
                Task { @MainActor in if let p = store.singlePal(id: id) { last = p } }
            }
            // Opened, or finished while it is open: seen, on every device.
            .onChange(of: external ? nil : store.singlePalAttention(id: id), initial: true) { _, a in
                if a == .done { store.markSeen(id: id) }
            }
            // Not a Pal: what it says while the page is open (the host doesn't run it, so nothing streams).
            .task(id: external && store.connection.isOnline) {
                guard external, store.connection.isOnline else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await store.reloadPalHistory()
                }
            }
            // Taken over (here, from its row, on another device): its Pal's page.
            .onChange(of: external ? store.pal(sessionId: id)?.id : nil, initial: true) { _, palID in
                if let palID { model.openPal(palID) }
            }
            // Typing to it failed (it wouldn't stop, it's gone): why, in place of the composer.
            .onChange(of: external ? store.messages.last(where: { $0.delivery == .failed })?.id : nil) { _, failed in
                if failed != nil, let why = store.lastError, !why.isEmpty { panel = .notice(why) }
            }
            .animation(.snappy, value: panel)
            .animation(.snappy, value: store.heldMessages.count)
            #if DEBUG
            .task {
                // `-demoUnfold <message id>`: that long message opens unfolded.
                if let id = UserDefaults.standard.string(forKey: "demoUnfold") { store.setUnfolded(id, true) }
            }
            // `-demoPalFiles YES`: the page opens with its 文件 (snapshots).
            .task {
                guard !external, UserDefaults.standard.bool(forKey: "demoPalFiles") else { return }
                try? await Task.sleep(for: .seconds(1))
                model.openPalFiles(id)
            }
            #endif
    }

    private var dot: StatusDotKind? {
        if external { return session?.live.map { StatusDotKind($0.status) } }
        return waking ? .working : pal?.dot
    }

    /// Its state and folder (在忙 / 空闲 / 睡着 / 等你 / 终端里开着), under its name.
    private var subtitle: String {
        if external {
            guard let s = session else { return "" }
            let folder = CCSession.shortPath(s.cwd)
            guard let live = s.live else { return String(localized: "已退出 · \(folder)") }
            if live.isOpenInTerminal { return String(localized: "终端里开着 · \(folder)") }
            return "\(Copy.sessionStatus(live.status)) · \(folder)"
        }
        return pal.map { Copy.palSubtitle($0, waking: waking) } ?? ""
    }

    // MARK: above the composer (one that isn't a Pal)

    /// Still open in a terminal: what typing does, before anything is typed;
    /// what's typed waits until it's quit there, and can be called off.
    private var terminalLine: AnyView? {
        let held = store.heldMessages.count
        let live = session?.live
        if held > 0 {
            return AnyView(ComposerNote(icon: "clock", text: String(localized: "终端那边退出后发出"),
                                        action: held > 1 ? String(localized: "取消这 \(held) 条") : String(localized: "取消这条")) {
                Task { await store.cancelAdoption(sessionId: id) }
            }
            .accessibilityIdentifier("agent-held"))
        }
        if live?.isOpenInTerminal == true {
            return AnyView(ComposerNote(icon: "terminal", text: String(localized: "终端里还开着。发的话会等那边退出（/exit）后发出，之后在这里接着聊。"))
                .accessibilityIdentifier("agent-in-terminal"))
        }
        if live?.kind == .background, live?.isRunning == true {
            return AnyView(ComposerNote(icon: "arrow.triangle.branch", text: String(localized: "在后台跑着。发一句话会先停下它，在这里接着跑。")))
        }
        return nil
    }

    // MARK: bottom

    /// In place of the composer: what's being asked, or why something didn't work.
    private var bottom: AnyView? {
        let content: AnyView
        switch panel {
        case .none:
            guard gone else { return nil }
            let name = pal?.displayName ?? String(localized: "它")
            content = AnyView(
                NoticePanel(text: Copy.spaced(String(localized: "\(name)已经不在 agent 里了。对话记录还在主机上。")), action: String(localized: "回到列表")) {
                    model.showList()
                })
        case .notice(let why):
            content = AnyView(NoticePanel(text: Copy.spaced(String(localized: "没发出去：\(why)")), action: String(localized: "好")) {
                panel = .none
                store.lastError = nil
            })
        }
        return AnyView(
            content
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: ChatView.readableWidth)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity)))
    }
}

/// A quiet line over the composer: an icon, a few words, and an action when
/// there is one (no theme color: it's information, not the main action).
struct ComposerNote: View {
    let icon: String
    let text: String
    var action: String? = nil
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Text(verbatim: "·").font(.footnote).foregroundStyle(.tertiary)
                Button(action, action: perform)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("agent-held-cancel")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: ChatView.readableWidth)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

/// 重命名 (pals-prd §13): the system's alert with the name filled in. Claude
/// Code's title for the session changes too; a name another Pal has comes
/// back with a number. Used by the Pal's page and its row on the list.
struct PalRenameAlert: ViewModifier {
    @Binding var pal: Pal?
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var failure: String?

    func body(content: Content) -> some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("PalRenameAlert")
        #endif
        content
            .alert("重命名", isPresented: Binding(get: { pal != nil }, set: { if !$0 { pal = nil } })) {
                TextField("名字", text: $text)
                    .accessibilityIdentifier("pal-rename-field")
                Button("取消", role: .cancel) { pal = nil }
                Button("好") {
                    let id = pal?.id
                    let name = text
                    pal = nil
                    guard let id else { return }
                    Task {
                        do {
                            try await store.renamePal(id: id, name: name)
                        } catch {
                            failure = String(localized: "没改成：\(Copy.error(error))")
                        }
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("主机上的 Claude Code 里也会是这个名字。")
            }
            .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            }
            .onChange(of: pal?.id) { _, id in if id != nil { text = pal?.displayName ?? "" } }
    }
}

extension View {
    /// 重命名 a Pal: set `pal` to ask.
    func palRename(_ pal: Binding<Pal?>) -> some View { modifier(PalRenameAlert(pal: pal)) }
}
