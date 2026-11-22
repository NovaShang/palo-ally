import PaloAllyKit
import SwiftUI

// 等你的事 (docs/workbench-design/decisions-queue.html): what the owner must
// decide comes to them. It is the right pane's first tab, 等你 (the Mac,
// iPads; on a phone the side page's): the assistant's pane lists everything,
// an agent's only what comes from it. The capsule over the composer, the
// sidebar's counts and ⌘⇧I open it (a phone's assistant: a sheet). 聊这件
// opens the conversation it belongs to with the item quoted in the composer;
// 从头过一遍 has the assistant put the first at the bottom of its
// conversation, where it's answered in place. Every row is the same card as
// in the conversation (PendingCard) and decides the same way; once decided
// it folds to one gray line.

// MARK: - the capsule over the composer

/// 「3 件等你 · 合同第 7 条…」 while something waits and nothing is being
/// talked about at the bottom; gone otherwise.
///
/// In a Pal's conversation it holds that Pal's items only, and opens the
/// 等你 tab of its pane (which lists those).
struct PendingCapsule: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// A Pal's conversation: its items only.
    var palID: String? = nil
    var inTile = false

    var body: some View {
        let open = palID.map { store.openPending(forPal: $0) } ?? store.openPending
        if let first = open.first, store.discussingPending == nil {
            Button {
                model.openPendingList(pal: palID)
            } label: {
                HStack(spacing: 7) {
                    Text(open.count > 99 ? "99+" : "\(open.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(StatusDot.color(.waiting), in: .capsule)
                    Text(String(localized: "件等你"))
                        .font(.subheadline.weight(.semibold))
                    Text("·").foregroundStyle(.secondary)
                    Text(PendingCopy.short(first.title))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 7)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(String(localized: "\(open.count) 件等你：\(first.title)"))
            .accessibilityIdentifier("pending-capsule")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The orb's corner: how many wait (a hint; the capsule is the way in).
struct PendingOrbBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(StatusDot.color(.waiting), in: .capsule)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - the list

/// The list itself: open items (blocking first), 今天处理过 with 放回, 已收起.
/// The sheet and the right pane's tab both show this; an agent's panel
/// shows only its own (`filter`).
struct PendingListView: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Whose items: everyone's (the list), or one agent's (its panel).
    var filter: PendingFilter = .all
    /// The list was opened over something (the sheet): close it after 聊这件.
    var dismiss: (() -> Void)? = nil
    @State private var showSnoozed = false
    @State private var showToday = false
    /// 已收起: hidden until 以后再说 replaces it.
    static let showsSnoozed = false

    private var open: [PendingItem] { filter.items(in: store) }
    private var everything: Bool { filter == .all }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if open.isEmpty {
                    Text(everything ? String(localized: "没有等你的事了") : String(localized: "这里没有等你的事"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 18)
                        .padding(.horizontal, 6)
                } else {
                    sectionTitle(String(localized: "\(open.count) 件"))
                    ForEach(open) { PendingRow(item: $0, dismiss: dismiss) }
                }
                // Handled today: folded, so an answered item visibly leaves the
                // list (it used to reappear just below, 11-20).
                let today = store.pendingHandledToday
                if !today.isEmpty && everything {
                    Button {
                        withAnimation(.snappy) { showToday.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(localized: "今天处理过 · \(today.count)"))
                            Image(systemName: showToday ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 10)
                    }
                    .buttonStyle(.plain)
                    if showToday { ForEach(today) { PendingRow(item: $0, dismiss: dismiss) } }
                }
                // 已收起 is hidden for now (one word for "not now": 以后再说, which puts it in 待办, comes later).
                let snoozed = store.pendingSnoozed
                if Self.showsSnoozed && !snoozed.isEmpty && everything {
                    Button {
                        withAnimation(.snappy) { showSnoozed.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(localized: "已收起（放了很久没动的）· \(snoozed.count)"))
                            Image(systemName: showSnoozed ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 10)
                    }
                    .buttonStyle(.plain)
                    if showSnoozed { ForEach(snoozed) { PendingRow(item: $0, dismiss: dismiss) } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .animation(.snappy, value: store.pendingItems)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

enum PendingFilter: Equatable {
    case all, assistant, pal(String)
    /// A workspace's agents.
    case pals([String])

    /// A pane's: everything in the assistant's, an agent's own in its, a
    /// workspace's agents' in its (what its sidebar count counts).
    @MainActor
    static func pane(key: String, activeSessionID: String?, store: AppStore) -> PendingFilter {
        if key.hasPrefix("ws:") { return .pals(store.workspace(id: String(key.dropFirst(3)))?.memberIds ?? []) }
        let scope = RightPaneScope.resolve(key: key, activeSessionID: activeSessionID, store: store)
        return RightPaneScope.palID(of: scope).map { .pal($0) } ?? .all
    }

    @MainActor
    func items(in store: AppStore) -> [PendingItem] {
        switch self {
        case .all: store.openPending
        case .assistant: store.openPending(forPal: nil)
        case .pal(let id): store.openPending(forPal: id)
        case .pals(let ids): store.openPending.filter { $0.source.kind == .pal && ids.contains($0.source.id ?? "") }
        }
    }
}

/// Phones: the list as a sheet, 从头过一遍 at its top.
struct PendingListSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PendingListView(dismiss: { dismiss() })
                .navigationTitle(String(localized: "等你的事"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "关闭")) { dismiss() }
                    }
                    if let first = store.openPending.first {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "从头过一遍")) {
                                dismiss()
                                model.goThrough(from: first, in: store)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.accentColor)
                            .accessibilityIdentifier("pending-agenda")
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The sheet's place: the assistant's conversation (one per window).
struct PendingSheetHost: ViewModifier {
    @Environment(WindowModel.self) private var model
    let enabled: Bool

    func body(content: Content) -> some View {
        @Bindable var model = model
        if enabled {
            content.sheet(isPresented: $model.showPendingSheet) { PendingListSheet() }
        } else {
            content
        }
    }
}

/// The right pane's 等你 tab (the Mac, iPads; a phone's side page): the
/// assistant's lists everything, with 从头过一遍; an agent's only its own.
struct PendingPaneView: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    var filter: PendingFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if filter == .all, let first = store.openPending.first {
                    Button(String(localized: "从头过一遍")) { model.goThrough(from: first, in: store) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("pending-agenda")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            PendingListView(filter: filter)
        }
        .accessibilityIdentifier("pending-pane")
    }

    private var title: String {
        if case .pal(let id) = filter, let name = store.pal(id: id)?.name, !name.isEmpty {
            return String(localized: "来自\(name)")
        }
        return String(localized: "等你的事")
    }
}

/// One item, as the same card the conversation shows (PendingCard): who ·
/// what to decide · its background, its options (a card's own buttons for
/// a prompt, a proposal or a draft), 其他… for the owner's words; then
/// 聊这件, 以后再说 (when it can wait in a 待办) and 忽略. Handled, one gray
/// line with 放回.
struct PendingRow: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let item: PendingItem
    var dismiss: (() -> Void)? = nil
    @State private var decision = PendingDecider()
    @State private var typing = false

    var body: some View {
        Group {
            if item.isOpen { open } else { handled }
        }
        .accessibilityIdentifier("pending-row-\(item.id)")
    }

    private var open: some View {
        PendingCard(header: PendingCardHeader(item: item, who: "", createdAt: item.createdAt, blocking: item.blocking),
                    title: item.title, background: item.context, error: decision.error, compact: true) {
            let choices = item.choices
            if !choices.isEmpty {
                PendingChoiceButtons(choices: choices, working: decision.working, large: false, pick: decide)
            }
            if item.takesWords {
                PendingOwnWords(typing: $typing, label: choices.isEmpty ? String(localized: "直接回答") : String(localized: "其他…")) {
                    decide(.option($0))
                }
            }
        } actions: {
            HStack(spacing: 10) {
                Button(String(localized: "聊这件")) {
                    dismiss?()
                    model.talk(about: item, in: store)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("pending-talk-\(item.id)")
                Spacer(minLength: 0)
                PendingLaterButton(item: item) { decide(.later) }
                Button(String(localized: "忽略")) { decide(.ignore) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
    }

    /// 「✓ 已定：订静安的全季 · 上海的酒店… · 放回」
    private var handled: some View {
        PendingFoldedLine(text: "\(PendingCopy.outcome(item)) · \(item.title)", done: item.status == .done,
                          action: item.isCard ? nil : (String(localized: "放回"), { decide(.reopen) }))
            .padding(.horizontal, 12)
    }

    private func decide(_ choice: PendingChoice) {
        PendingDecider.run(store, item.subject, choice, into: $decision) { $0 }
    }
}

// MARK: - the card in the conversation

/// An item surfaced at the bottom (聊这件, 从头过一遍), as the one card
/// (PendingCard): who · what to decide · its background · its options;
/// 看原文 goes back to where it came from. Once decided it folds to
/// 「✓ 已定：… · 撤回」.
struct PendingChatCard: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let id: String
    @State private var decision = PendingDecider()

    var body: some View {
        if let item = store.pendingItem(id: id) {
            Group {
                if item.isOpen { open(item) } else { folded(item) }
            }
            .animation(.snappy, value: item.status)
            .accessibilityIdentifier("pending-card-\(item.id)")
        }
    }

    private func open(_ item: PendingItem) -> some View {
        PendingCard(header: PendingCardHeader(item: item, who: "", createdAt: item.createdAt, blocking: item.blocking),
                    title: item.title, background: item.context, error: decision.error) {
            if item.choices.isEmpty {
                Text(String(localized: "没有固定选项：直接打字说你的想法就行"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } actions: {
            VStack(alignment: .leading, spacing: 6) {
                if !item.choices.isEmpty {
                    PendingChoiceButtons(choices: item.choices, working: decision.working) { decide(item, $0) }
                }
                if canShowOrigin(item) {
                    Button(String(localized: "看原文 ↑")) { model.showOrigin(of: item, in: store) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func folded(_ item: PendingItem) -> some View {
        let text = item.status == .done ? String(localized: "已定：\(item.conclusion ?? item.title)")
            : item.status == .ignored ? String(localized: "已忽略") : String(localized: "已收起")
        return PendingFoldedLine(text: text, done: item.status == .done,
                                 action: item.isCard ? nil : (item.status == .done ? String(localized: "撤回") : String(localized: "放回"),
                                                              { decide(item, .reopen) }))
    }

    private func canShowOrigin(_ item: PendingItem) -> Bool {
        if item.pal != nil { return true }
        guard let mid = item.messageId else { return false }
        return store.messages.contains { $0.id == mid }
    }

    private func decide(_ item: PendingItem, _ choice: PendingChoice) {
        PendingDecider.run(store, item.subject, choice, into: $decision) { $0 }
    }
}

// MARK: - words

enum PendingCopy {
    /// 已定：… / 已忽略 / 已收起
    static func outcome(_ item: PendingItem) -> String {
        switch item.status {
        case .done: String(localized: "已定：\(item.conclusion ?? "")")
        case .ignored: String(localized: "已忽略")
        case .snoozed: String(localized: "已收起")
        default: ""
        }
    }

    /// 聊这件's quote: what to decide, and its background.
    static func quote(_ item: PendingItem) -> String {
        let context = item.context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return context.isEmpty ? item.title : "\(item.title)\n\(context)"
    }

    /// The capsule's glimpse of the first item: a couple of dozen characters.
    static func short(_ title: String) -> String {
        title.count > 22 ? String(title.prefix(21)) + "…" : title
    }
}

// MARK: - where things go

extension WindowModel {
    /// The capsule, the sidebar's counts, ⌘⇧I: the 等你 tab of the open
    /// page's pane (the Mac, iPads), listing what that page's agent waits on
    /// (`pal`: the tile the capsule is in, in a workspace). Phones: over the
    /// assistant's conversation the sheet; over an agent's its side page,
    /// on 等你.
    func openPendingList(pal: String? = nil) {
        if libraryBeside {
            if let pal, case .workspace(let w)? = selection, store?.workspace(id: w)?.memberIds.contains(pal) == true {
                activeTiles[w] = pal
            }
            openInPane { $0.openPending($1) }
        } else if (selection ?? .palo) == .palo {
            showPendingSheet = true
        } else {
            PhonePaneState.shared.segment = .pending
            paneCover = true
        }
    }

    /// 聊这件: to the conversation it belongs to (a Pal's, a session's, the
    /// assistant's) with the item quoted in the composer, the owner's words
    /// to follow; a question, a permission prompt or one of the assistant's
    /// cards is brought into view instead, to be answered where it is.
    func talk(about item: PendingItem, in store: AppStore) {
        let quote = ReplyTo(messageId: "pending:\(item.id)", excerpt: PendingCopy.quote(item))
        if let pal = item.pal ?? (item.source.kind == .pal ? item.source.id : nil) {
            openPal(pal)
            store.palStore(pal).replyDraft = quote
            return
        }
        if item.source.kind == .session, let id = item.source.id {
            openSession(id)
            return
        }
        if item.isCard {
            openPalo()
            if let q = item.questionId { focusQuestionID = q } else if let a = item.approvalId { focusApprovalID = a }
            return
        }
        // A proposal card or an Ally draft: the card itself, answered in place.
        if item.link?.kind == .proposal || item.link?.kind == .allyDraft,
           let mid = item.messageId, let m = store.messages.first(where: { $0.id == mid }) {
            openPalo()
            focusMessageSeq = m.seq
            return
        }
        openPalo()
        store.replyDraft = quote
    }

    /// 从头过一遍: the assistant puts the first item at the bottom of its
    /// conversation, says what it thinks, and goes on from there.
    func goThrough(from item: PendingItem, in store: AppStore) {
        openPalo()
        Task { try? await store.surfacePending(item) }
    }

    /// 看原文: the message it came from (or its Pal's conversation).
    func showOrigin(of item: PendingItem, in store: AppStore) {
        if let pal = item.pal {
            openPal(pal)
            return
        }
        guard let mid = item.messageId, let m = store.messages.first(where: { $0.id == mid }) else { return }
        focusMessageSeq = m.seq
    }
}
