import Foundation

// 待办 (host/src/backlog.ts; docs/workbench-design/backlog.html): what the
// owner wants done later, one list per folder, shared by the agents working
// in it; the assistant's is its own folder's. The host keeps the lists and
// sends a folder's whole list when it changes (`backlog.updated`); the
// owner's hand on one shows at once and is put right by the host's answer.
// 下一件: an agent that finished its turn with nothing waiting on the owner
// is offered the first item in line for it; 换一件 steps past it, and
// putting the offer away keeps it away from that agent for the rest of the day.
/// New words for an item, until the host has them: whose list, and what changed (nil: as it is; an empty note: none).
struct BacklogEdit {
    var owner: String?
    var folder: String?
    var text: String?
    var note: String?
    /// Grows with each change; the host's answer to an older one doesn't end it.
    var revision = 0
    var sending = false
}

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
        // What was typed here and the host hasn't taken yet stands over the list it sends.
        let b = withEdits(b)
        if shared.backlogs[b.folder] != b { shared.backlogs[b.folder] = b }
        if b.assistant == true, shared.backlogFolders["palo"] != b.folder { shared.backlogFolders["palo"] = b.folder }
        // An agent in that folder whose list wasn't asked for yet: it's this one.
        for p in pals where p.cwd == b.folder && shared.backlogFolders[p.id] == nil { shared.backlogFolders[p.id] = b.folder }
    }

    private func withEdits(_ b: Backlog) -> Backlog {
        guard !shared.backlogEdits.isEmpty else { return b }
        var b = b
        for i in b.items.indices {
            guard let e = shared.backlogEdits[b.items[i].id], e.folder == nil || e.folder == b.folder else { continue }
            if let t = e.text { b.items[i].text = t }
            if let n = e.note { b.items[i].note = n.isEmpty ? nil : n }
        }
        return b
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
            resendBacklogEdits()
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") { shared.backlogSupported = false }
        }
    }

    // MARK: the owner's hand

    /// A new item at the end of the queue.
    @discardableResult
    public func addBacklog(_ text: String, note: String? = nil, forPal pal: String?) async throws -> BacklogItem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let r: BacklogResult = try await rpc.call(RPCMethod.backlogAdd, params: BacklogParams(pal: pal, text: t, note: note))
        if let b = r.backlog { remember(b, for: pal) }
        return r.item
    }

    /// Its words or its note, changed in place (nil: as it is; an empty note
    /// takes it away). Shown at once; sent now, or again once the computer is
    /// reached, and until then no list from the host puts the old words back.
    public func editBacklog(id: String, text: String? = nil, note: String? = nil, forPal pal: String?) {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text?.isEmpty != true, text != nil || note != nil else { return }
        var e = shared.backlogEdits[id] ?? BacklogEdit(owner: pal, folder: shared.backlogFolders[backlogOwner(pal)])
        if let text { e.text = text }
        if let note { e.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        e.revision += 1
        shared.backlogEdits[id] = e
        if let b = backlog(forPal: pal) { apply(backlog: b) }
        sendBacklogEdit(id)
    }

    /// What the host hasn't taken, once it's reached again.
    func resendBacklogEdits() {
        for id in shared.backlogEdits.keys { sendBacklogEdit(id) }
    }

    /// One item's words at a time, the newest until the host has them.
    private func sendBacklogEdit(_ id: String) {
        guard shared.backlogEdits[id]?.sending == false else { return }
        shared.backlogEdits[id]?.sending = true
        Task {
            while let e = shared.backlogEdits[id] {
                do {
                    let r: BacklogResult = try await rpc.call(RPCMethod.backlogUpdate, params: BacklogParams(pal: e.owner, id: id, text: e.text, note: e.note))
                    if shared.backlogEdits[id]?.revision == e.revision { shared.backlogEdits[id] = nil }
                    if let b = r.backlog { remember(b, for: e.owner) }
                } catch {
                    // Refused (it's gone from the list): nothing to send. Not reached: kept.
                    if case .remote? = error as? RPCError {
                        shared.backlogEdits[id] = nil
                        await loadBacklog(forPal: e.owner)
                    } else {
                        shared.backlogEdits[id]?.sending = false
                    }
                    return
                }
            }
        }
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

    /// 撤回 of 做完了: `item` as it was (queued or being done), at its place in the queue.
    public func undoDoneBacklog(_ item: BacklogItem, place: Int, forPal pal: String?) async throws {
        guard item.state == .doing else { return try await moveBacklog(item, to: place, forPal: pal) }
        try await change(pal, optimistic: { $0.starting(item.id, by: item.pal, name: item.palName) },
                         RPCMethod.backlogStart, BacklogParams(pal: pal, id: item.id, agent: item.pal))
    }

    /// 撤回 of a removal: `item` as it was, at its place among the ones in its state.
    public func restoreBacklog(_ item: BacklogItem, place: Int, forPal pal: String?) async throws {
        do {
            try await change(pal, optimistic: { $0.restoring(item, to: place) },
                             RPCMethod.backlogRestore, BacklogParams(pal: pal, to: place, item: item))
        } catch {
            guard case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") else { throw error }
            // A host from before it: the same words again, in the same place, for the same agent.
            guard let again = try await addBacklog(item.text, note: item.note, forPal: pal) else { return }
            switch item.state {
            case .done:
                try await doneBacklog(again, forPal: pal)
            case .doing:
                try await change(pal, optimistic: { $0.starting(again.id, by: item.pal, name: item.palName) },
                                 RPCMethod.backlogStart, BacklogParams(pal: pal, id: again.id, agent: item.pal))
            default:
                try await moveBacklog(again, to: place, forPal: pal)
                if let agent = item.pal { try await assignBacklog(again, to: agent, forPal: pal) }
            }
        }
    }

    /// 开始: the item goes to `agent` (or the assistant, nil) as the
    /// owner's words, quoting it, and is being done by it from now on.
    /// `owner`: whose list it's on (nil: the assistant's), which needn't be
    /// the agent's own folder's. `words`: what the owner says under the quote (开始做这件).
    public func startBacklog(_ item: BacklogItem, by agent: String?, forPal owner: String?, words: String) {
        let target = agent.map { palStore($0) } ?? (parent ?? self)
        if let agent { shared.backlogSkips[agent] = 0 }
        // Marked first: when the agent looks at its list, it's there as its own.
        markBacklogStarted(item, by: agent, forPal: owner)
        let saved = target.replyDraft
        target.replyDraft = ReplyTo(messageId: "backlog:\(item.id)", excerpt: Self.backlogQuote(item))
        target.send(words)
        target.replyDraft = saved
    }

    /// Being done by `agent` (the assistant, nil), its words on their way some other way (a new agent's first message).
    public func markBacklogStarted(_ item: BacklogItem, by agent: String?, forPal owner: String?) {
        let name = agent.flatMap { pal(id: $0)?.displayName }
        Task {
            try? await change(owner, optimistic: { $0.starting(item.id, by: agent, name: name) },
                              RPCMethod.backlogStart, BacklogParams(pal: owner, id: item.id, agent: agent))
        }
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
