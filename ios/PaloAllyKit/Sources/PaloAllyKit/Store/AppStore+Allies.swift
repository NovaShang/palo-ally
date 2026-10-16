import Foundation

/// Allies (allies-prd §5, §7.5): the list, each one's exchanges, and the
/// owner's answers to draft cards.
extension AppStore {
    // MARK: reading

    public func ally(id: String) -> AllyInfo? { allies.first { $0.id == id } }

    /// One Ally's exchanges held here, oldest first.
    public func allyLog(_ id: String) -> [AllyEntry] { allyLogs[id] ?? [] }

    public func allyEntry(id: String) -> AllyEntry? {
        for log in allyLogs.values {
            if let e = log.first(where: { $0.id == id }) { return e }
        }
        return looseAllyEntries[id]
    }

    /// Drafts waiting for the owner's 发送 / 改一下 / 不发, oldest first.
    public var pendingAllyDrafts: [AllyEntry] {
        var all = allyLogs.values.flatMap { $0 }
        all += looseAllyEntries.values
        return all.filter(\.isPendingDraft).sorted { $0.ts < $1.ts }
    }

    /// Pending drafts with no message in the conversation to show them at:
    /// they wait at its live end, where approvals do.
    public var unanchoredPendingDrafts: [AllyEntry] {
        // Only the assistant's conversation shows them (and each Ally's page).
        guard scope == .palo else { return [] }
        let drafts = pendingAllyDrafts
        guard !drafts.isEmpty else { return [] }
        let anchored = Set(messages.compactMap { $0.kind == .ally ? $0.entryId : nil })
        return drafts.filter { !anchored.contains($0.id) }
    }

    /// The Ally an exchange belongs to.
    public func allyID(ofEntry id: String) -> String? {
        allyLogs.first { $0.value.contains { $0.id == id } }?.key
    }

    // MARK: loading

    /// After every catch-up: the list, then each Ally's latest exchanges
    /// (drafts and statuses that changed while the app was away). A host
    /// that doesn't know Allies says so once, and they stay hidden.
    public func loadAllies() async {
        do {
            try await refreshAllies()
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") {
                alliesSupported = false
            }
            return
        }
        for a in allies { _ = try? await loadAllyLog(id: a.id) }
    }

    public func refreshAllies() async throws {
        let r: AlliesResult = try await rpc.call(RPCMethod.allyList, params: EmptyParams())
        allies = r.allies
        alliesSupported = true
    }

    /// One page of an Ally's exchanges (the newest, or those before
    /// `before`), merged into what's held.
    @discardableResult
    public func loadAllyLog(id: String, before: Int64? = nil, limit: Int = 50) async throws -> [AllyEntry] {
        let r: AllyEntriesResult = try await rpc.call(RPCMethod.allyLog,
                                                      params: AllyLogParams(id: id, beforeTs: before, limit: limit))
        var log = allyLogs[id] ?? []
        for var e in r.entries {
            e.allyId = id
            looseAllyEntries[e.id] = nil
            if let i = log.firstIndex(where: { $0.id == e.id }) { log[i] = e } else { log.append(e) }
        }
        log.sort { $0.ts < $1.ts }
        allyLogs[id] = log
        allyLogHasMore[id] = r.entries.count >= limit
        return r.entries
    }

    // MARK: changes from the host

    func apply(allyUpdate u: AllyUpdate) {
        switch u {
        case .list(let list):
            allies = list
            alliesSupported = true
        case .upsert(let a):
            if let i = allies.firstIndex(where: { $0.id == a.id }) { allies[i] = a } else { allies.append(a) }
            alliesSupported = true
        case .removed(let id):
            forgetAlly(id)
        case .refetch:
            Task { try? await self.refreshAllies() }
        }
    }

    /// An exchange arrived or changed: into its Ally's log, and the list's
    /// last line when it's the newest (in any state, as the host keeps it).
    func upsert(allyEntry incoming: AllyEntry, allyId: String?) {
        var e = incoming
        guard let owner = allyId ?? e.allyId ?? allyID(ofEntry: e.id) else {
            looseAllyEntries[e.id] = e
            return
        }
        e.allyId = owner
        looseAllyEntries[e.id] = nil
        var log = allyLogs[owner] ?? []
        if let i = log.firstIndex(where: { $0.id == e.id }) {
            log[i] = e
        } else {
            log.append(e)
            log.sort { $0.ts < $1.ts }
        }
        allyLogs[owner] = log
        if let i = allies.firstIndex(where: { $0.id == owner }) {
            let last = allies[i].lastEntry
            if last?.id == e.id || e.ts >= (last?.ts ?? 0) { allies[i].lastEntry = e }
        }
    }

    /// Gone from the list; drafts to them can't go out any more.
    private func forgetAlly(_ id: String) {
        allies.removeAll { $0.id == id }
        if var log = allyLogs[id] {
            for i in log.indices where log[i].isPendingDraft { log[i].status = .rejected }
            allyLogs[id] = log
        }
    }

    // MARK: actions

    /// A fresh invite (10 minutes, one use); the app draws its link as a QR code.
    public func inviteAlly() async throws -> AllyInviteResult {
        try await rpc.call(RPCMethod.allyInvite, params: EmptyParams(), timeout: 30)
    }

    /// A link that pairs one more of the owner's own devices with this
    /// computer (5 minutes, one device), to open on that device.
    public func pairInvite() async throws -> PairInviteResult {
        try await rpc.call(RPCMethod.pairInvite, params: EmptyParams(), timeout: 30)
    }

    /// Hands someone's invite to this computer. Answers once both sides are
    /// paired: usually seconds; 30 at most (§7.6).
    @discardableResult
    public func acceptAlly(link: String, kind: AllyKind, trust: AllyTrust? = nil) async throws -> AllyInfo? {
        let r: AllyResult = try await rpc.call(RPCMethod.allyAccept, params: AllyAcceptParams(link: link, kind: kind, trust: trust),
                                               timeout: 30)
        if let a = r.ally { apply(allyUpdate: .upsert(a)) }
        return r.ally
    }

    /// 解除: both sides forget each other.
    public func removeAlly(id: String) async throws {
        _ = try await rpc.call(RPCMethod.allyRemove, params: IDParams(id: id), as: OKResult.self)
        forgetAlly(id)
    }

    /// The owner's answer to a draft, shown at once and put back if the
    /// computer didn't take it. Returns the entry as the computer has it.
    @discardableResult
    public func decide(_ draft: AllyEntry, _ action: AllyDraftAction, text: String? = nil) async throws -> AllyEntry? {
        let owner = draft.allyId ?? allyID(ofEntry: draft.id)
        let before = allyEntry(id: draft.id) ?? draft
        var shown = before
        if let text { shown.text = text }
        switch action {
        case .send: shown.status = .queued
        case .discard: shown.status = .rejected; shown.note = "没发"
        case .edit: break
        }
        upsert(allyEntry: shown, allyId: owner)
        do {
            let r: AllyEntryResult = try await rpc.call(RPCMethod.allyDraftDecide,
                                                        params: AllyDraftDecideParams(id: draft.id, action: action, text: text))
            if let e = r.entry { upsert(allyEntry: e, allyId: owner ?? e.allyId) }
            return r.entry ?? shown
        } catch {
            upsert(allyEntry: before, allyId: owner)
            throw error
        }
    }

    /// The owner's own words to an Ally (§11.3): sent as they are, no card.
    /// They show at once as queued; the host's copy of the exchange follows.
    @discardableResult
    public func say(to allyId: String, text raw: String) async throws -> AllyEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let local = AllyEntry(id: "local-\(UUID().uuidString.lowercased())", allyId: allyId, dir: .outgoing,
                              ts: Date().epochMillis, text: text, status: .queued, author: .owner)
        upsert(allyEntry: local, allyId: allyId)
        do {
            let r: AllyEntryResult = try await rpc.call(RPCMethod.allySay, params: AllySayParams(id: allyId, text: text))
            dropAllyEntry(local.id, from: allyId)
            guard var e = r.entry else { return nil }
            if e.author == nil { e.author = .owner }
            upsert(allyEntry: e, allyId: allyId)
            return e
        } catch {
            dropAllyEntry(local.id, from: allyId)
            throw error
        }
    }

    /// 能对话 / 每句要你看 for one Ally (§11.1), shown at once and put back
    /// if the computer didn't take it.
    public func setTrust(_ trust: AllyTrust, for allyId: String) async throws {
        guard let i = allies.firstIndex(where: { $0.id == allyId }) else { return }
        let before = allies[i]
        allies[i].trust = trust
        do {
            let r: AllyResult = try await rpc.call(RPCMethod.allyTrust, params: AllyTrustParams(id: allyId, trust: trust))
            if let a = r.ally { apply(allyUpdate: .upsert(a)) }
        } catch {
            if let j = allies.firstIndex(where: { $0.id == allyId }) { allies[j] = before }
            throw error
        }
    }

    private func dropAllyEntry(_ id: String, from allyId: String) {
        allyLogs[allyId]?.removeAll { $0.id == id }
        if let i = allies.firstIndex(where: { $0.id == allyId }), allies[i].lastEntry?.id == id {
            allies[i].lastEntry = allyLogs[allyId]?.last
        }
    }

    /// 发送, with the owner's own words if they changed them (改一下 → 发送):
    /// `send` with `text` sends the changed words (§7.6).
    public func send(draft: AllyEntry, text: String? = nil) async throws {
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = words.flatMap { $0.isEmpty || $0 == draft.text ? nil : $0 }
        try await decide(draft, .send, text: changed)
    }
}
