import Foundation

// 待办 (host/src/backlog.ts; docs/workbench-design/backlog.html): what the
// owner wants done later, one list per folder, shared by the agents working
// in it; the assistant's is its own folder's. The host keeps the lists and
// sends a folder's whole list when it changes (`backlog.updated`); the
// owner's hand on one shows at once and is put right by the host's answer.
// 下一件: an agent that finished its turn with nothing waiting on the owner
// is offered the first item in line for it; 换一件 steps past it, and
// putting the offer away keeps it away from that agent for the rest of the day.
extension AppStore {
    /// "palo" or a Pal's id: whose list.
    private func backlogOwner(_ pal: String?) -> String { pal ?? "palo" }

    /// The list of the assistant (nil) or of an agent's folder, once loaded.
    public func backlog(forPal pal: String?) -> Backlog? {
        guard let folder = shared.backlogFolders[backlogOwner(pal)] else { return nil }
        return shared.backlogs[folder]
    }

    /// false for a host from before 待办; nil until asked.
    public var backlogSupported: Bool? { shared.backlogSupported }

    /// The agents of this list's folder (the ones it can be meant for).
    public func backlogAgents(forPal pal: String?) -> [Pal] {
        guard let folder = backlog(forPal: pal)?.folder ?? pal.flatMap({ self.pal(id: $0)?.cwd }) else { return [] }
        return pals.filter { $0.cwd == folder || shared.backlogFolders[$0.id] == folder }
    }

    func apply(backlog b: Backlog) {
        if shared.backlogs[b.folder] != b { shared.backlogs[b.folder] = b }
        if b.assistant == true, shared.backlogFolders["palo"] != b.folder { shared.backlogFolders["palo"] = b.folder }
        // An agent in that folder whose list wasn't asked for yet: it's this one.
        for p in pals where p.cwd == b.folder && shared.backlogFolders[p.id] == nil { shared.backlogFolders[p.id] = b.folder }
    }

    private func remember(_ b: Backlog, for pal: String?) {
        if shared.backlogFolders[backlogOwner(pal)] != b.folder { shared.backlogFolders[backlogOwner(pal)] = b.folder }
        apply(backlog: b)
    }

    /// The list of the assistant (nil) or an agent, from the host.
    public func loadBacklog(forPal pal: String?) async {
        do {
            let r: BacklogResult = try await rpc.call(RPCMethod.backlogList, params: BacklogParams(pal: pal))
            if shared.backlogSupported != true { shared.backlogSupported = true }
            if let b = r.backlog { remember(b, for: pal) }
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") { shared.backlogSupported = false }
        }
    }

    // MARK: the owner's hand

    /// A new item at the end of the queue.
    public func addBacklog(_ text: String, note: String? = nil, forPal pal: String?) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let r: BacklogResult = try await rpc.call(RPCMethod.backlogAdd, params: BacklogParams(pal: pal, text: t, note: note))
        if let b = r.backlog { remember(b, for: pal) }
    }

    /// Dragged to place `to` of the queue (0 = top).
    public func moveBacklog(_ item: BacklogItem, to: Int, forPal pal: String?) async throws {
        try await change(pal, optimistic: { $0.moving(item.id, to: to) },
                         RPCMethod.backlogMove, BacklogParams(pal: pal, id: item.id, to: to))
    }

    /// Meant for one agent of the folder, or (nil) anyone's.
    public func assignBacklog(_ item: BacklogItem, to agent: String?, forPal pal: String?) async throws {
        try await change(pal, optimistic: { b in
            var b = b
            if let i = b.items.firstIndex(where: { $0.id == item.id }) {
                b.items[i].pal = agent
                b.items[i].palName = agent.flatMap { self.pal(id: $0)?.displayName }
            }
            return b
        }, RPCMethod.backlogAssign, BacklogParams(pal: pal, id: item.id, agent: agent))
    }

    /// 做完了, or back in the queue.
    public func doneBacklog(_ item: BacklogItem, done: Bool = true, forPal pal: String?) async throws {
        try await change(pal, optimistic: { b in
            var b = b
            guard let i = b.items.firstIndex(where: { $0.id == item.id }) else { return b }
            var it = b.items.remove(at: i)
            if done {
                it.state = .done
                it.doneAt = Date().epochMillis
                b.items.append(it)
            } else {
                it.state = .queued; it.doneAt = nil; it.pal = nil; it.palName = nil
                b.items.insert(it, at: b.items.firstIndex { $0.state == .queued } ?? b.items.firstIndex { $0.state == .done } ?? b.items.count)
            }
            return b
        }, RPCMethod.backlogDone, BacklogParams(pal: pal, id: item.id, done: done))
    }

    public func removeBacklog(_ item: BacklogItem, forPal pal: String?) async throws {
        try await change(pal, optimistic: { b in
            var b = b
            b.items.removeAll { $0.id == item.id }
            return b
        }, RPCMethod.backlogRemove, BacklogParams(pal: pal, id: item.id))
    }

    /// 开始: the item goes to `agent` (or the assistant, nil) as the
    /// owner's words, quoting it, and is being done by it from now on.
    /// `words`: what the owner says under the quote (开始做这件).
    public func startBacklog(_ item: BacklogItem, by agent: String?, words: String) {
        let target = agent.map { palStore($0) } ?? (parent ?? self)
        if let agent { shared.backlogSkips[agent] = 0 }
        Task {
            // Marked first: when the agent looks at its list, it's there as its own.
            if let b = try? await self.startCall(item, agent: agent) { self.remember(b, for: agent) }
        }
        let saved = target.replyDraft
        target.replyDraft = ReplyTo(messageId: "backlog:\(item.id)", excerpt: Self.backlogQuote(item))
        target.send(words)
        target.replyDraft = saved
    }

    private func startCall(_ item: BacklogItem, agent: String?) async throws -> Backlog? {
        let r: BacklogResult = try await rpc.call(RPCMethod.backlogStart, params: BacklogParams(pal: agent, id: item.id, agent: agent))
        return r.backlog
    }

    /// What 开始 quotes: the item and its note.
    public static func backlogQuote(_ item: BacklogItem) -> String {
        let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return note.isEmpty ? item.text : "\(item.text)\n\(note)"
    }

    private func change(_ pal: String?, optimistic: (Backlog) -> Backlog, _ method: String, _ params: BacklogParams) async throws {
        let before = backlog(forPal: pal)
        if let before { apply(backlog: optimistic(before)) }
        do {
            let r: BacklogResult = try await rpc.call(method, params: params)
            if let b = r.backlog { remember(b, for: pal) }
        } catch {
            if let before { shared.backlogs[before.folder] = before }
            throw error
        }
    }

    // MARK: 下一件

    /// What an agent is offered above its composer now: it has finished a
    /// turn, nothing of it waits on the owner, it isn't doing an item of
    /// the list already, and the offer wasn't put away today.
    public func nextBacklog(forPal pal: String) -> BacklogItem? {
        guard let p = self.pal(id: pal), p.finishedAt != nil, !p.inTurn, p.status != .starting,
              p.attention == .done || p.attention == .idle,
              openPending(forPal: pal).isEmpty,
              !nextBacklogDismissedToday(pal),
              let b = backlog(forPal: pal), !b.doing.contains(where: { $0.pal == pal }) else { return nil }
        return b.next(for: pal, skip: shared.backlogSkips[pal] ?? 0)
    }

    /// 换一件: the one after it (the order stays).
    public func skipNextBacklog(forPal pal: String) {
        shared.backlogSkips[pal, default: 0] += 1
    }

    /// Put away: not offered to this agent again today.
    public func dismissNextBacklog(forPal pal: String) {
        let day = Self.dayKey(Date())
        shared.backlogDismissed[pal] = day
        UserDefaults.standard.set(day, forKey: Self.dismissKey(pal))
    }

    func nextBacklogDismissedToday(_ pal: String) -> Bool {
        let today = Self.dayKey(Date())
        if let d = shared.backlogDismissed[pal] { return d == today }
        let stored = UserDefaults.standard.string(forKey: Self.dismissKey(pal))
        return stored == today
    }

    static func dismissKey(_ pal: String) -> String { "backlog.next.dismissed.\(pal)" }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: 以后再说

    /// An item of 等你的事 put off: it goes on the 待办 of the folder it came
    /// from and leaves the list (shown at once; the host's answer confirms).
    public func laterPending(_ item: PendingItem, conclusion: String) async throws {
        var next = item
        next.status = .done
        next.conclusion = conclusion
        next.resolvedAt = Date().epochMillis
        upsert(pending: next)
        do {
            let r: PendingItemResult = try await rpc.call(RPCMethod.pendingUpdate, params: PendingUpdateParams(id: item.id, action: "later"))
            if let i = r.item { upsert(pending: i) }
        } catch {
            upsert(pending: item)
            throw error
        }
    }

    /// Whether 以后再说 is offered: an open item nothing is stopped on, not a card's.
    public static func canPutOff(_ item: PendingItem) -> Bool {
        item.isOpen && !item.blocking && !item.isCard && item.link == nil
    }
}
