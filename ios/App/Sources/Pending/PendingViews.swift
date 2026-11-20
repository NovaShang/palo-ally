import PaloAllyKit
import SwiftUI

// 等你的事 (docs/workbench-design/decisions-queue.html): what the owner must
// decide comes to them. A capsule over the composer opens the list (a sheet
// on phones, a tab of the right pane on the Mac and iPads); 聊这件 opens the
// conversation it belongs to with the item quoted in the composer; 从头过一遍
// has the assistant put the first at the bottom of its conversation, where
// it's answered in place; once decided its card folds to one gray line.

// MARK: - the capsule over the composer

/// 「3 件等你 · 合同第 7 条…」 while something waits and nothing is being
/// talked about at the bottom; gone otherwise.
///
/// In a Pal's conversation it holds that Pal's items only, and opens its
/// details (they list them, answerable there); anything else in a tile,
/// where the details are the tile's own, opens the list.
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
                if palID != nil && !inTile { model.setDetail(true, tile: nil) } else { model.openPendingList() }
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

    private var open: [PendingItem] {
        switch filter {
        case .all: store.openPending
        case .assistant: store.openPending(forPal: nil)
        case .pal(let id): store.openPending(forPal: id)
        }
    }
    private var everything: Bool { filter == .all }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if open.isEmpty {
                    Text(String(localized: "没有等你的事了"))
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
                let snoozed = store.pendingSnoozed
                if !snoozed.isEmpty && everything {
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

enum PendingFilter: Equatable { case all, assistant, pal(String) }

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

/// The right pane's tab (the Mac, iPads): a header with 从头过一遍, then the list.
struct PendingPaneView: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "等你的事")).font(.headline)
                Spacer()
                if let first = store.openPending.first {
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
            PendingListView()
        }
    }
}

/// One item: who it's from, what to decide, a line of background, who
/// waits and how long; 聊这件, its options, 忽略 (or 放回 once handled).
struct PendingRow: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let item: PendingItem
    var dismiss: (() -> Void)? = nil
    @State private var error: String?
    @State private var typing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                PendingSourceIcon(source: item.source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let c = item.context, !c.isEmpty, item.isOpen {
                        Text(c)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    meta
                }
                Spacer(minLength: 0)
            }
            actions
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
        .opacity(item.isOpen ? 1 : 0.6)
        .accessibilityIdentifier("pending-row-\(item.id)")
    }

    private var meta: some View {
        HStack(spacing: 0) {
            if item.blocking && item.isOpen {
                Text(String(localized: "卡着「\(item.source.name)」"))
                    .foregroundStyle(StatusDot.color(.waiting))
                Text(" · ")
            }
            Text(item.blocking && item.isOpen ? Copy.relative(item.createdAt) : PendingCopy.sourceAndAge(item))
            if !item.isOpen {
                Text(" · ")
                Text(PendingCopy.outcome(item))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var actions: some View {
        if item.isOpen {
            // Its options one under another, as wide as the row, wrapping:
            // a long one reads whole (chips cut them, 11-20); 其他… for the
            // owner's own words.
            if let options = item.options, !options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button { answer(option) } label: {
                            Text(option)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    // An approval is yes or no; a question or an item takes words too.
                    if item.approvalId == nil { ownWords }
                }
            }
            HStack(spacing: 10) {
                Button(String(localized: "聊这件")) {
                    dismiss?()
                    model.talk(about: item, in: store)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("pending-talk-\(item.id)")
                if item.options?.isEmpty ?? true, !typing {
                    Button(String(localized: "直接回答")) { typing = true }
                        .buttonStyle(.plain)
                        .font(.footnote)
                }
                Spacer(minLength: 0)
                Button(String(localized: "忽略")) { update("ignore") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            if item.options?.isEmpty ?? true, typing { field }
        } else if !item.isCard {
            HStack {
                Button(String(localized: "放回")) { update("reopen") }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                Spacer(minLength: 0)
            }
        }
    }

    /// 其他…: a line to type the owner's own answer in.
    @ViewBuilder private var ownWords: some View {
        if typing {
            field
        } else {
            Button { typing = true } label: {
                Text(String(localized: "其他…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "写你的回答"), text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                .onSubmit(sendOwn)
            Button(action: sendOwn) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendOwn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        typing = false
        answer(text)
    }

    private func answer(_ option: String) {
        error = nil
        Task {
            do { try await store.answerPending(item, option) } catch { self.error = Friendly.message(error) }
        }
    }

    private func update(_ action: String) {
        error = nil
        Task {
            do { try await store.updatePending(item, action: action) } catch { self.error = Friendly.message(error) }
        }
    }
}

/// Who put it there, as a small mark (no color of its own: the list stays neutral).
struct PendingSourceIcon: View {
    let source: PendingSource
    var body: some View {
        Image(systemName: Self.symbol(source.kind))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.08), in: .circle)
            .accessibilityHidden(true)
    }

    static func symbol(_ kind: PendingSourceKind) -> String {
        switch kind {
        case .palo: "sparkles"
        case .pal, .session: "terminal"
        case .brief: "sun.max"
        case .ally: "person.2"
        case .unknown: "circle"
        }
    }
}

// MARK: - the card in the conversation

/// An item surfaced at the bottom (聊这件): where it's from, what to decide,
/// its background and options; 看原文 goes back to where it came from. Once
/// decided it folds to 「✓ 已定：… · 撤回」.
struct PendingChatCard: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let id: String
    @State private var error: String?

    var body: some View {
        if let item = store.pendingItem(id: id) {
            Group {
                if item.isOpen { open(item) } else { folded(item) }
            }
            .animation(.snappy, value: item.status)
        }
    }

    private func open(_ item: PendingItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(StatusDot.color(.waiting)).frame(width: 7, height: 7)
                Text(PendingCopy.cardLine(item))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(item.title)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let c = item.context, !c.isEmpty {
                Text(c)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let options = item.options, !options.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { optionButtons(item, options) }
                    VStack(alignment: .leading, spacing: 6) { optionButtons(item, options) }
                }
                .padding(.top, 4)
            } else {
                Text(String(localized: "没有固定选项：直接打字说你的想法就行"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            if canShowOrigin(item) {
                Button(String(localized: "看原文 ↑")) { model.showOrigin(of: item, in: store) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityIdentifier("pending-card-\(item.id)")
    }

    @ViewBuilder private func optionButtons(_ item: PendingItem, _ options: [String]) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { i, option in
            Button {
                answer(item, option)
            } label: {
                Text(option).frame(minWidth: 60)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .buttonBorderShape(.capsule)
        }
    }

    private func folded(_ item: PendingItem) -> some View {
        HStack(spacing: 6) {
            if item.status == .done {
                Image(systemName: "checkmark").foregroundStyle(.green)
                Text(String(localized: "已定：\(item.conclusion ?? item.title)"))
            } else {
                Image(systemName: "arrow.uturn.backward")
                Text(item.status == .ignored ? String(localized: "已忽略") : String(localized: "已收起"))
            }
            if !item.isCard {
                Text("·")
                Button(item.status == .done ? String(localized: "撤回") : String(localized: "放回")) {
                    Task {
                        do { try await store.updatePending(item, action: "reopen") } catch { self.error = Friendly.message(error) }
                    }
                }
                .buttonStyle(.plain)
                .underline()
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .accessibilityIdentifier("pending-card-\(item.id)")
    }

    private func canShowOrigin(_ item: PendingItem) -> Bool {
        if item.pal != nil { return true }
        guard let mid = item.messageId else { return false }
        return store.messages.contains { $0.id == mid }
    }

    private func answer(_ item: PendingItem, _ option: String) {
        error = nil
        Task {
            do { try await store.answerPending(item, option) } catch { self.error = Friendly.message(error) }
        }
    }
}

// MARK: - words

enum PendingCopy {
    /// 「合同审阅 · 40 分钟前」
    static func sourceAndAge(_ item: PendingItem) -> String {
        let name = item.source.name.isEmpty ? String(localized: "助理") : item.source.name
        return "\(name) · \(Copy.relative(item.createdAt))"
    }

    /// 已定：… / 已忽略 / 已收起
    static func outcome(_ item: PendingItem) -> String {
        switch item.status {
        case .done: String(localized: "已定：\(item.conclusion ?? "")")
        case .ignored: String(localized: "已忽略")
        case .snoozed: String(localized: "已收起")
        default: ""
        }
    }

    /// The card's first line: who, whether it's stopped on it, when.
    static func cardLine(_ item: PendingItem) -> String {
        let name = item.source.name.isEmpty ? String(localized: "助理") : item.source.name
        let age = Copy.relative(item.createdAt)
        return item.blocking ? String(localized: "\(name) · 卡着它 · \(age)") : "\(name) · \(age)"
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
    /// The capsule, the orb's badge, ⌘⇧I: the list. Beside the conversation
    /// (the Mac, iPads) a tab of the right pane; phones a sheet.
    func openPendingList() {
        if libraryBeside {
            openInPane { $0.openPending($1) }
        } else {
            showPendingSheet = true
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
