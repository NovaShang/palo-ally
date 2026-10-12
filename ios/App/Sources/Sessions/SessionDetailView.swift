import PaloAllyKit
import SwiftUI

/// One Claude Code session (sessions-prd §5): its conversation, newest at
/// the bottom, older pages on the way up; what it's waiting on the owner
/// for; a box to say something into it; and ⋯ with 在电脑上打开 and, for a
/// helper, 重启 / 停止 / 复活 / 删除 (停止 and 删除 asked in the page). Pushed
/// from anywhere by id.
struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    /// What the bottom of the page holds: the input, or one of these.
    enum Panel: String, Equatable { case none, stop, remove, attach }
    #if DEBUG
    /// `-demoSessionPanel stop|remove|attach`: the page opens on it (snapshots).
    @State private var panel = Panel(rawValue: UserDefaults.standard.string(forKey: "demoSessionPanel") ?? "") ?? .none
    #else
    @State private var panel = Panel.none
    #endif
    @State private var draft = ""
    @State private var loaded = false
    @State private var loadingOlder = false
    @State private var working = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private var history: [CCMessage] { store.sessionHistory(sessionID) }
    private var pending: [SessionPendingSend] { store.pendingSends(sessionID) }
    private var approvals: [Approval] { store.liveEndApprovals.filter { $0.source?.id == sessionID } }
    private var questions: [Question] { store.liveEndQuestions.filter { $0.source?.id == sessionID } }

    var body: some View {
        Group {
            if let session = store.session(id: sessionID) {
                page(session)
            } else {
                ContentUnavailableView("这个会话已经没有了", systemImage: "terminal",
                                       description: Text("它可能在电脑上关掉了。"))
            }
        }
        .onAppear { store.watchSession(sessionID) }
        .onDisappear { store.unwatchSession(sessionID) }
        .task(id: sessionID) {
            _ = try? await store.loadSessionHistory(id: sessionID)
            loaded = true
        }
    }

    private func page(_ session: CCSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header(session)
                    if store.sessionHistoryHasMore[sessionID] == true {
                        Button {
                            Task { await loadOlder(proxy) }
                        } label: {
                            if loadingOlder { ProgressView() } else { Text("看看更早的") }
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .disabled(loadingOlder)
                    }
                    if !loaded && history.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if history.isEmpty && pending.isEmpty {
                        Text("还没有对话。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(Array(history.enumerated()), id: \.element.id) { i, m in
                        if let gap = timeBreak(at: i) {
                            Text(gap)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                        }
                        SessionMessageRow(message: m, assistantName: store.assistantName)
                            .id(m.id)
                    }
                    ForEach(pending) { p in
                        PendingSendRow(pending: p, sessionID: sessionID)
                            .id(p.id)
                    }
                    // What it's waiting on the owner for, the same cards as in the conversation.
                    ForEach(approvals) { a in
                        ApprovalCard(approval: a, linksSource: false).id("approval-\(a.id)")
                    }
                    ForEach(questions) { q in
                        QuestionCard(question: q, linksSource: false).id("question-\(q.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            // New lines at the end keep the end in view; an older page
            // added at the top leaves what's being read where it is.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottom(session)
            }
            .onChange(of: pending.count) { old, new in
                if new > old, let last = pending.last { withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .navigationTitle(session.displayName)
        .navigationSubtitle(Copy.sessionSubtitle(session))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasMenu(session) {
                ToolbarItem(placement: .topBarTrailing) { menu(session) }
            }
        }
        .animation(.snappy, value: panel)
        .animation(.snappy, value: session.status)
    }

    // MARK: header

    /// Where it lives, at the top of its conversation.
    private func header(_ s: CCSession) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                SessionKindTag(kind: s.kind)
                if !s.shortCwd.isEmpty {
                    Text(s.shortCwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    /// A quiet time line where half an hour or more passed between two lines.
    private func timeBreak(at i: Int) -> String? {
        let m = history[i]
        guard m.ts > 0 else { return nil }
        if i == 0 { return Copy.clock(m.ts) }
        let prev = history[i - 1].ts
        return m.ts - prev >= 30 * 60_000 ? Copy.clock(m.ts) : nil
    }

    // MARK: bottom

    @ViewBuilder
    private func bottom(_ s: CCSession) -> some View {
        VStack(spacing: 6) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            switch panel {
            case .stop:
                ConfirmPanel(title: Copy.spaced("停止\(s.displayName)？"),
                             text: "手上的事会停下。对话记录还在，随时能复活。",
                             action: "停止", working: working,
                             cancel: { panel = .none }, confirm: { Task { await control(.stop) } })
            case .remove:
                ConfirmPanel(title: Copy.spaced("删除\(s.displayName)？"),
                             text: "删除后它就不干了，电脑重启也不会再开。对话记录还留着，想用时能复活。",
                             action: "删除", working: working,
                             cancel: { panel = .none }, confirm: { Task { await control(.remove) } })
            case .attach:
                AttachPanel(command: "claude attach \(s.id)") { panel = .none }
            case .none:
                if s.isRunning {
                    inputBar(s)
                } else {
                    stoppedBar(s)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func inputBar(_ s: CCSession) -> some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.connection.isOnline
        return HStack(alignment: .bottom, spacing: 4) {
            TextField(Copy.spaced("跟\(s.displayName)说点什么"), text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.vertical, 11)
                .padding(.leading, 16)
                .accessibilityIdentifier("session-input")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("发送")
            .padding(.trailing, 2)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    /// Stopped: a helper comes back with 复活 (the one action here); the
    /// owner's own sessions just say so.
    private func stoppedBar(_ s: CCSession) -> some View {
        HStack(spacing: 12) {
            Text(s.isHelper ? "它停了。对话记录都在。" : "这个会话停了。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if s.isHelper {
                Button {
                    Task { await control(.revive) }
                } label: {
                    Text(working ? "正在复活…" : "复活")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(working || !store.connection.isOnline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: menu

    private func hasMenu(_ s: CCSession) -> Bool { s.isHelper || s.canAttach }

    private func menu(_ s: CCSession) -> some View {
        Menu {
            if s.canAttach {
                Button("在电脑上打开", systemImage: "laptopcomputer") { panel = .attach }
            }
            if s.isHelper {
                Section {
                    if s.isRunning {
                        Button("重启", systemImage: "arrow.clockwise") { Task { await control(.restart) } }
                        Button("停止", systemImage: "stop.circle") { panel = .stop }
                    } else {
                        Button("复活", systemImage: "arrow.uturn.backward") { Task { await control(.revive) } }
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { panel = .remove }
                }
            }
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
        // Chrome stays neutral; the theme color is for 发送.
        .tint(.primary)
        .disabled(working || !store.connection.isOnline)
    }

    // MARK: actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        error = nil
        Task {
            do {
                try await store.sendToSession(id: sessionID, text: text)
            } catch {
                self.error = "没送到：\(Copy.error(error))"
            }
        }
    }

    private func control(_ action: SessionControlAction) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await store.controlSession(id: sessionID, action: action)
            panel = .none
            if action == .remove { dismiss() }
        } catch {
            self.error = "没成功：\(Copy.error(error))"
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) async {
        loadingOlder = true
        defer { loadingOlder = false }
        let first = history.first?.id
        _ = try? await store.loadSessionHistory(id: sessionID, before: first)
        if let first { proxy.scrollTo(first, anchor: .top) }
    }
}

// MARK: - rows

/// One line of a session's conversation. The owner's words at the computer:
/// a filled bubble on the right. Words that came through PaloAlly: an
/// outlined bubble on the right, 「Palo 转来」 (the owner's, from the app) or
/// 「Palo 说的」 (the assistant's own). The session's replies: plain text on
/// the left. Another session's: on the left under its name, set off by a
/// quiet rule.
struct SessionMessageRow: View {
    let message: CCMessage
    let assistantName: String

    private var paloLabel: String {
        let assistant = assistantName.isEmpty ? "Palo" : assistantName
        let from = message.from?.trimmingCharacters(in: .whitespaces) ?? ""
        if from.isEmpty || from == "主人" || from == "PaloAlly" { return Copy.spaced("\(assistant) 转来") }
        return Copy.spaced("\(from) 说的")
    }

    var body: some View {
        switch message.role {
        case .owner:
            OwnWords(text: message.shownText, outlined: false, label: nil)
        case .palo:
            OwnWords(text: message.shownText, outlined: true, label: paloLabel)
        case .assistant:
            HStack(spacing: 0) {
                MarkdownText(source: message.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AssistantMessageLayout.trailingRoom)
            }
        case .peer:
            PeerWords(from: message.from, text: message.text)
        case .unknown:
            Text(message.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// The owner's words, on the right: filled when typed at the computer,
/// outlined when they came through PaloAlly.
private struct OwnWords: View {
    let text: String
    let outlined: Bool
    let label: String?
    var leading: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 48)
            if let leading { leading }
            VStack(alignment: .trailing, spacing: 4) {
                if let label {
                    Label(label, systemImage: "arrow.turn.down.right")
                        .labelStyle(QuietLabelStyle())
                }
                Text(MarkdownBlock.attributed(text))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                        if outlined {
                            shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                        } else {
                            shape.fill(Color(.secondarySystemFill))
                        }
                    }
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(text) }
                    }
            }
        }
    }
}

/// Another session's words: who sent them, then the words beside a quiet rule.
private struct PeerWords: View {
    let from: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(Copy.spaced("来自\(from.flatMap { $0.isEmpty ? nil : $0 } ?? "另一个会话")"), systemImage: "terminal")
                    .labelStyle(QuietLabelStyle())
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(.quaternary).frame(width: 3)
                    Text(MarkdownBlock.attributed(text))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AssistantMessageLayout.trailingRoom)
        }
    }
}

/// Small glyph and words, quiet: the label over a message or on a card.
struct QuietLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.caption2)
            configuration.title.font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

/// Words sent from here that the session doesn't show yet: outlined like
/// what comes through PaloAlly, with a clock; failed, a way to send again.
private struct PendingSendRow: View {
    @Environment(AppStore.self) private var store
    let pending: SessionPendingSend
    let sessionID: String

    var body: some View {
        OwnWords(text: pending.text, outlined: true, label: nil, leading: AnyView(mark))
            .opacity(pending.state == .failed ? 1 : 0.75)
            .contextMenu {
                if pending.state == .failed {
                    Button("再发一次", systemImage: "arrow.clockwise") { retry() }
                    Button("不发了", systemImage: "xmark", role: .destructive) { store.dropSend(pending, from: sessionID) }
                }
            }
    }

    @ViewBuilder private var mark: some View {
        if pending.state == .failed {
            Button(action: retry) {
                Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("没送到，点一下再发")
        } else {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("正在送过去")
        }
    }

    private func retry() {
        Task { try? await store.retrySend(pending, to: sessionID) }
    }
}

// MARK: - panels

/// 停止 / 删除, asked in the page: what happens, then 算了 and the action.
private struct ConfirmPanel: View {
    let title: String
    let text: String
    let action: String
    let working: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Text("算了").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button(action: confirm) {
                    Text(working ? "\(action)中…" : action).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(working)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

/// 在电脑上打开: the line to run in a terminal, with a copy button.
private struct AttachPanel: View {
    let command: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("在电脑上打开").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关上")
            }
            Text("在电脑的终端里运行这一行，就能接着在电脑上跟它说话。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                CopyButton(text: command, label: "复制这一行")
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }
}
