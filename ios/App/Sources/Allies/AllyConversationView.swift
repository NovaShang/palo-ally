import PaloAllyKit
import SwiftUI

/// An Ally's page (allies-prd §11.3): the conversation with them. Their
/// words on the left, labelled with who said them (the person, or their
/// assistant); the owner's own on the right; what the owner's assistant
/// said for them on the right too, as 「Palo 代你说」. At 每句要你看 those
/// first wait here as draft cards. What the owner types below goes out as
/// it is (`ally.say`), no card. ⋯ has the trust level (能对话 / 每句要你看)
/// and 解除, asked in the page.
struct AllyConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.chatDraft) private var draft
    let allyID: String

    enum Panel: Equatable { case none, remove }
    #if DEBUG
    /// `-demoAllyRemove YES`: the page opens on 解除's confirmation (snapshots).
    @State private var panel: Panel = UserDefaults.standard.bool(forKey: "demoAllyRemove") ? .remove : .none
    #else
    @State private var panel = Panel.none
    #endif
    @State private var loaded = false
    @State private var loadingOlder = false
    @State private var working = false
    @State private var error: String?
    /// The Ally as last seen (they leave the list once removed).
    @State private var last: AllyInfo?

    private var log: [AllyEntry] { store.allyLog(allyID) }

    var body: some View {
        Group {
            if let ally = store.ally(id: allyID) ?? last {
                page(ally)
            } else {
                ContentUnavailableView("已经解除了", systemImage: "person.2.slash",
                                       description: Text("要再加，得当面扫码。"))
            }
        }
        .onChange(of: store.ally(id: allyID), initial: true) { _, a in if let a { last = a } }
        .task(id: allyID) {
            _ = try? await store.loadAllyLog(id: allyID)
            loaded = true
        }
    }

    private func page(_ ally: AllyInfo) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header(ally)
                if store.allyLogHasMore[allyID] == true {
                    Button {
                        Task { await loadOlder() }
                    } label: {
                        if loadingOlder { ProgressView() } else { Text("看看更早的") }
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .disabled(loadingOlder)
                }
                if !loaded && log.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if log.isEmpty {
                    Text(Copy.spaced(String(localized: "还没有来往。在下面打字，直接发给\(ally.displayName)。")))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                let lastOut = log.last { $0.dir == .outgoing && !$0.isPendingDraft }?.id
                ForEach(Array(log.enumerated()), id: \.element.id) { i, e in
                    if let gap = timeBreak(at: i) {
                        Text(gap)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    AllyEntryRow(entry: e, ally: ally, assistant: store.assistantName, showsState: e.id == lastOut)
                        .id(e.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: ChatView.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        // New words at the end keep the end in view; an older page added at
        // the top leaves what's being read where it is.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottom(ally) }
        .navigationTitle(ally.displayName)
        .navigationSubtitle(Copy.allyPresence(ally))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(BarMenu { menu(ally) })
        // The Mac: to the window's top, its name and menu floating (MacPageStrip).
        .macPageTop(ally.displayName, subtitle: Copy.allyPresence(ally), trailing: AnyView(menu(ally)))
        .refreshable { _ = try? await store.loadAllyLog(id: allyID) }
        .animation(.snappy, value: panel)
        .animation(.snappy, value: log.count)
    }

    // MARK: header

    /// Who they are, and how each side's assistant answers the other.
    private func header(_ ally: AllyInfo) -> some View {
        VStack(spacing: 8) {
            AllyAvatar(ally: ally, size: 56, ring: Color(.systemBackground))
            HStack(spacing: 6) {
                AllyKindTag(kind: ally.kind)
                let a = ally.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty, a != ally.displayName {
                    Text(Copy.spaced(String(localized: "TA 的助理叫\(a)")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Label {
                Text(Copy.allyTrustNote(ally.effectiveTrust, assistant: store.assistantName, ally: ally.displayName))
            } icon: {
                Image(systemName: ally.effectiveTrust == .converse ? "bubble.left.and.bubble.right" : "hand.raised")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ally-trust")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    /// A quiet time line where half an hour or more passed between two exchanges.
    private func timeBreak(at i: Int) -> String? {
        let e = log[i]
        guard e.ts > 0 else { return nil }
        if i == 0 { return Copy.clock(e.ts) }
        return e.ts - log[i - 1].ts >= 30 * 60_000 ? Copy.clock(e.ts) : nil
    }

    // MARK: bottom

    @ViewBuilder
    private func bottom(_ ally: AllyInfo) -> some View {
        VStack(spacing: 6) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            switch panel {
            case .remove:
                ConfirmPanel(title: Copy.spaced(String(localized: "和\(ally.displayName)解除？")),
                             text: String(localized: "解除后，你们两边的列表里都不再有对方。要再加，得当面扫码。"),
                             action: String(localized: "解除"), working: working,
                             cancel: { panel = .none }, confirm: { Task { await remove() } })
            case .none:
                if store.ally(id: allyID) != nil {
                    WordsInputBar(placeholder: Copy.spaced(String(localized: "跟\(ally.displayName)说点什么")), text: draft,
                                  enabled: store.connection.isOnline, send: send, identifier: "ally-input")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: ChatView.readableWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: menu

    private func menu(_ ally: AllyInfo) -> some View {
        PageMenu(label: String(localized: "更多")) {
            Section("你的助理怎么回 TA") {
                ForEach([AllyTrust.converse, .review], id: \.self) { t in
                    Button {
                        Task { await setTrust(t) }
                    } label: {
                        if ally.effectiveTrust == t {
                            Label(Copy.allyTrust(t), systemImage: "checkmark")
                        } else {
                            Text(Copy.allyTrust(t))
                        }
                    }
                }
            }
            Section {
                Button("解除", systemImage: "person.2.slash", role: .destructive) { panel = .remove }
            }
        }
        .disabled(working || store.ally(id: allyID) == nil || !store.connection.isOnline)
        .accessibilityIdentifier("ally-menu")
    }

    // MARK: actions

    private func send() {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft.wrappedValue = ""
        error = nil
        Task {
            do {
                try await store.say(to: allyID, text: text)
            } catch {
                self.error = String(localized: "没发出去：\(Copy.error(error))")
                if draft.wrappedValue.isEmpty { draft.wrappedValue = text }
            }
        }
    }

    private func setTrust(_ t: AllyTrust) async {
        error = nil
        do { try await store.setTrust(t, for: allyID) } catch { self.error = String(localized: "没改成：\(Copy.error(error))") }
    }

    private func remove() async {
        working = true
        error = nil
        do {
            try await store.removeAlly(id: allyID)
            panel = .none
            model.showList()
        } catch {
            self.error = String(localized: "没解除成：\(Copy.error(error))")
        }
        working = false
    }

    private func loadOlder() async {
        loadingOlder = true
        defer { loadingOlder = false }
        _ = try? await store.loadAllyLog(id: allyID, before: log.first?.ts)
    }
}

/// One exchange in an Ally's conversation.
private struct AllyEntryRow: View {
    let entry: AllyEntry
    let ally: AllyInfo
    let assistant: String
    /// The newest of this side's words: its state shows under it.
    let showsState: Bool

    var body: some View {
        if entry.isPendingDraft {
            // 每句要你看: the assistant's words wait for 发送 / 改一下 / 不发.
            AllyDraftCard(entry: entry, name: ally.displayName)
        } else if entry.dir == .incoming {
            TheirWords(entry: entry, label: theirLabel)
        } else {
            OwnWords(text: entry.text,
                     outlined: !entry.byOwner,
                     label: entry.byOwner ? nil : Copy.saysForYou(assistant),
                     labelSymbol: "sparkles",
                     caption: caption)
                .opacity(entry.status == .rejected ? 0.6 : 1)
            if let slots = entry.slots, !slots.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    AllySlotList(slots: slots)
                }
            }
        }
    }

    /// Who said it: the person themselves, or their assistant for them.
    private var theirLabel: String {
        entry.author == .owner ? ally.displayName : ally.assistantLabel
    }

    /// The state under this side's words: the newest's, and any that didn't go out as it should.
    private var caption: String? {
        guard showsState || entry.status == .queued || entry.status == .rejected else { return nil }
        return Copy.allyStatus(entry)
    }
}

/// Their words: who said them, then the words beside a quiet rule (the
/// owner's assistant's replies look this way in its own conversation).
private struct TheirWords: View {
    let entry: AllyEntry
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(label, systemImage: entry.author == .owner ? "person.fill" : "person.2.fill")
                        .labelStyle(QuietLabelStyle())
                    if entry.urgent {
                        Text("急").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(.quaternary).frame(width: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .contextMenu {
                                Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(entry.text) }
                            }
                        if let slots = entry.slots, !slots.isEmpty {
                            AllySlotList(slots: slots)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AssistantMessageLayout.trailingRoom)
        }
        .accessibilityElement(children: .combine)
    }
}
