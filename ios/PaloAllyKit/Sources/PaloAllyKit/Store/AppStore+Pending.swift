import Foundation

// 等你的事 (host/src/pending.ts; docs/workbench-design/decisions-queue.html):
// what the owner must decide, kept by the host and shared by every
// conversation on the computer. It holds everything that waits on the
// owner (questions and prompts, proposal cards, Ally drafts, tasks that need
// them), so every waiting badge is a count of its open items. The list's
// order: a session stopped on it first, then the newest.
extension AppStore {
    /// Every item the host lists: open, put away, and the ones closed lately.
    public internal(set) var pendingItems: [PendingItem] {
        get { shared.pendingItems }
        set { shared.pendingItems = newValue }
    }

    func upsert(pending item: PendingItem) {
        if let i = pendingItems.firstIndex(where: { $0.id == item.id }) { pendingItems[i] = item } else { pendingItems.append(item) }
    }

    func setPending(_ items: [PendingItem]) { pendingItems = items }

    /// Open items, blocking ones first, then the newest.
    public var openPending: [PendingItem] {
        pendingItems.filter(\.isOpen).sorted { ($0.blocking ? 1 : 0, $0.createdAt) > ($1.blocking ? 1 : 0, $1.createdAt) }
    }

    /// Decided or ignored today (今天处理过), the latest first.
    public var pendingHandledToday: [PendingItem] {
        let start = Calendar.current.startOfDay(for: Date()).epochMillis
        return pendingItems.filter { ($0.status == .done || $0.status == .ignored) && ($0.resolvedAt ?? 0) >= start }
            .sorted { ($0.resolvedAt ?? 0) > ($1.resolvedAt ?? 0) }
    }

    /// Put away (已收起): open a long while, mentioned, then set aside.
    public var pendingSnoozed: [PendingItem] {
        pendingItems.filter { $0.status == .snoozed }.sorted { $0.createdAt > $1.createdAt }
    }

    public func pendingItem(id: String) -> PendingItem? { pendingItems.first { $0.id == id } }

    /// The open items of one agent: the assistant's own (its, a brief's and
    /// an Ally's), or one agent's: a Pal's, or one of the computer's other
    /// sessions' (by its session id; asked through the hooks).
    public func openPending(forPal id: String?) -> [PendingItem] {
        openPending.filter { item in
            let agent = item.source.kind == .pal || item.source.kind == .session
            if let id { return agent && item.source.id == id }
            return !agent
        }
    }

    /// What waits on the owner in this conversation: the assistant's own
    /// (its, a brief's, a contact's, the computer's sessions'), one Pal's, or
    /// one session's.
    public var openPendingHere: [PendingItem] {
        switch scope {
        case .palo: openPending(forPal: nil)
        case .pal(let id): openPending(forPal: id)
        }
    }

    /// What waits on the owner from one Ally: its drafts' items.
    public func allyPendingCount(_ id: String) -> Int {
        openPending.filter { $0.source.kind == .ally && $0.source.id == id }.count
    }

    /// An item surfaced at the bottom of the conversation is being talked
    /// about now: its card is among the last few messages and still open.
    public var discussingPending: PendingItem? {
        guard let card = messages.suffix(6).last(where: { $0.kind == .pending }), let id = card.pendingId,
              let item = pendingItem(id: id), item.isOpen else { return nil }
        return item
    }

    /// The item a card stands for (the open one first, then the latest).
    public func pendingItem(for subject: PendingSubject) -> PendingItem? {
        let match: (PendingItem) -> Bool = switch subject {
        case .approval(let id): { $0.approvalId == id }
        case .question(let id): { $0.questionId == id }
        case .proposal(let id): { $0.link?.kind == .proposal && $0.link?.id == id }
        case .allyDraft(let id): { $0.link?.kind == .allyDraft && $0.link?.id == id }
        case .task(let id): { $0.link?.kind == .task && $0.link?.id == id }
        case .item(let id): { $0.id == id }
        }
        return pendingItems.filter(match).max { ($0.isOpen ? 1 : 0, $0.createdAt) < ($1.isOpen ? 1 : 0, $1.createdAt) }
    }

    // MARK: the owner's hand

    /// Every decision on something that waits on the owner, from a card in a
    /// conversation or a row of the list: one way. The item closes at once
    /// with what was decided (the counts drop) and the card's own state
    /// shows the answer; both are put back if the host didn't take it. A
    /// card's choice goes through the card's own method (its 以后都允许, a
    /// question's several answers, a draft's changed words); an option the
    /// store has no card for, or the owner's own words, go through the item
    /// (`pending.answer`), which the host hands on as the card's button.
    public func decide(_ subject: PendingSubject, _ choice: PendingChoice) async throws {
        let item = pendingItem(for: subject)
        switch choice {
        case .ignore, .reopen:
            guard let item else { return }
            try await updatePending(item, action: choice == .ignore ? "ignore" : "reopen")
            return
        default: break
        }
        let before = item
        if var shown = item, shown.isOpen {
            shown.status = .done
            shown.conclusion = Self.conclusion(of: choice, item: shown)
            shown.resolvedAt = Date().epochMillis
            upsert(pending: shown)
        }
        do {
            try await carryOut(subject, choice, item: before)
        } catch {
            if let before { upsert(pending: before) }
            throw error
        }
    }

    /// The same, for an item (a row of the list).
    public func decide(_ item: PendingItem, _ choice: PendingChoice) async throws {
        try await decide(item.subject, choice)
    }

    /// An option picked, or the owner's own words, on an item.
    public func answerPending(_ item: PendingItem, _ answer: String) async throws {
        try await decide(item.subject, .option(answer))
    }

    private func carryOut(_ subject: PendingSubject, _ choice: PendingChoice, item: PendingItem?) async throws {
        let root = parent ?? self
        switch (subject, choice) {
        case (.approval(let id), .allow(let remember)):
            if let a = approval(id: id) { return try await answer(a, allow: true, remember: remember) }
        case (.approval(let id), .deny):
            if let a = approval(id: id) { return try await answer(a, allow: false) }
        case (.question(let id), .answers(let answers)):
            if let q = question(id: id) { return try await answer(q, answers: answers) }
        case (.question(let id), .option(let words)):
            // The list's options are its one question's.
            if let q = question(id: id), q.items.count == 1, let first = q.items.first {
                return try await answer(q, answers: [first.question: words])
            }
        case (.proposal(let id), .accept), (.proposal(let id), .decline):
            let action: HelperDecideAction = choice == .accept ? .create : .discard
            if let m = root.messages.first(where: { $0.proposal?.id == id }), let p = root.helperProposal(in: m) {
                _ = try await root.decideHelper(p, action)
                return
            }
            if let m = root.messages.first(where: { $0.adoption?.id == id }), let p = root.adoptProposal(in: m) {
                _ = try await root.decideAdopt(p, action)
                return
            }
        case (.allyDraft(let id), .accept):
            if let e = root.allyEntry(id: id) { return try await root.send(draft: e) }
        case (.allyDraft(let id), .sendEdited(let words)):
            if let e = root.allyEntry(id: id) { return try await root.send(draft: e, text: words) }
        case (.allyDraft(let id), .decline):
            if let e = root.allyEntry(id: id) { _ = try await root.decide(e, .discard); return }
        default: break
        }
        // No card here to answer: the item, in the words of its option.
        guard let item, let words = Self.words(of: choice, item: item) else { throw PendingDecideError.nothingToAnswer }
        let r: PendingItemResult = try await rpc.call(RPCMethod.pendingAnswer, params: PendingAnswerParams(id: item.id, answer: words))
        if let i = r.item { upsert(pending: i) }
    }

    /// What the item's option says for a card's choice (the host maps it back).
    nonisolated static func words(of choice: PendingChoice, item: PendingItem) -> String? {
        switch choice {
        case .option(let w): return w
        case .answers(let a): return a.isEmpty ? nil : a.sorted { $0.key < $1.key }.map(\.value).joined(separator: "、")
        case .allow, .deny, .accept, .decline:
            return item.choices.first { $0.choice == choice || (choice == .allow(remember: true) && $0.choice == .allow(remember: false)) }?.title
        case .sendEdited, .ignore, .reopen: return nil
        }
    }

    /// The decided line an item shows at once (the host's own follows).
    nonisolated static func conclusion(of choice: PendingChoice, item: PendingItem) -> String {
        if let w = words(of: choice, item: item) { return w }
        switch choice {
        case .allow: return loc("允许")
        case .deny: return loc("拒绝")
        case .answers: return loc("跳过了")
        case .accept: return loc("好")
        case .decline: return loc("不用")
        case .sendEdited: return loc("发了")
        default: return ""
        }
    }

    /// 忽略 / 撤回 / 放回 / 收起.
    public func updatePending(_ item: PendingItem, action: String) async throws {
        var next = item
        switch action {
        case "ignore": next.status = .ignored; next.resolvedAt = Date().epochMillis
        case "snooze": next.status = .snoozed; next.resolvedAt = Date().epochMillis
        case "reopen": next.status = .open; next.resolvedAt = nil; next.conclusion = nil
        default: break
        }
        upsert(pending: next)
        do {
            let r: PendingItemResult = try await rpc.call(RPCMethod.pendingUpdate, params: PendingUpdateParams(id: item.id, action: action))
            if let i = r.item { upsert(pending: i) }
        } catch {
            upsert(pending: item)
            throw error
        }
    }

    /// 聊这件: the host puts its card at the bottom of the assistant's
    /// conversation and asks the assistant to add its view.
    public func surfacePending(_ item: PendingItem) async throws {
        let _: ChatSendResult = try await rpc.call(RPCMethod.pendingSurface, params: PendingIDParams(id: item.id))
    }

    /// The list again (after a reconnect the sync brings it; this is for a host that didn't).
    public func loadPending() async {
        guard let r: PendingListResult = try? await rpc.call(RPCMethod.pendingList, params: EmptyParams()) else { return }
        setPending(r.items)
    }
}

/// A decision with nothing to carry it: no card here and no words for the item.
public struct PendingDecideError: LocalizedError, Equatable {
    public static let nothingToAnswer = PendingDecideError()
    public var errorDescription: String? { loc("这件已经不在了") }
}
