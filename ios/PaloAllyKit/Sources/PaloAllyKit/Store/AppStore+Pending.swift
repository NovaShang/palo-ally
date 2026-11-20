import Foundation

// 等你的事 (host/src/pending.ts; docs/workbench-design/decisions-queue.html):
// what the owner must decide, kept by the host and shared by every
// conversation on the computer. The list's order: a session stopped on it
// first, then the newest.
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

    /// The open items of one agent: the assistant's own (its, a brief's, an
    /// Ally's and the computer's sessions'), or one Pal's.
    public func openPending(forPal id: String?) -> [PendingItem] {
        openPending.filter { item in
            if let id { return item.source.kind == .pal && item.source.id == id }
            return item.source.kind != .pal
        }
    }

    /// What the cards already count leaves out: items that are a question
    /// or a prompt (blocking) are those cards. The assistant's, or a Pal's.
    public func pendingBeyondCards(forPal id: String?) -> Int {
        openPending(forPal: id).filter { !$0.isCard }.count
    }

    /// An item surfaced at the bottom of the conversation is being talked
    /// about now: its card is among the last few messages and still open.
    public var discussingPending: PendingItem? {
        guard let card = messages.suffix(6).last(where: { $0.kind == .pending }), let id = card.pendingId,
              let item = pendingItem(id: id), item.isOpen else { return nil }
        return item
    }

    // MARK: the owner's hand

    /// An option picked, or the owner's own words. The item is marked at
    /// once (the host's answer confirms it).
    public func answerPending(_ item: PendingItem, _ answer: String) async throws {
        var done = item
        done.status = .done
        done.conclusion = answer
        done.resolvedAt = Date().epochMillis
        upsert(pending: done)
        do {
            let r: PendingItemResult = try await rpc.call(RPCMethod.pendingAnswer, params: PendingAnswerParams(id: item.id, answer: answer))
            if let i = r.item { upsert(pending: i) }
        } catch {
            upsert(pending: item)
            throw error
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
