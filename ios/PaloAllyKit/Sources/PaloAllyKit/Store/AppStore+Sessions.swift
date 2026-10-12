import Foundation

/// Sessions (sessions-prd §5, §7): the computer's Claude Code sessions the
/// host doesn't run (Pals are the ones it does), one session's conversation,
/// the hooks switch, and the owner's answer to a proposal (which opens a
/// Pal on hosts that have them). Their approvals and questions are ordinary
/// cards with a `source`.
extension AppStore {
    // MARK: reading

    public func session(id: String) -> CCSession? { sessions.first { $0.id == id } }

    /// One session's conversation held here, oldest first.
    public func sessionHistory(_ id: String) -> [CCMessage] { sessionHistories[id] ?? [] }

    // MARK: loading

    /// A host from before Pals, after every catch-up (`loadPals` asks). One
    /// that doesn't know sessions either says so once, and they stay hidden.
    public func loadSessions() async {
        do {
            try await refreshSessions()
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") {
                sessionsSupported = false
            }
            return
        }
        for id in watchedSessions.keys { _ = try? await loadSessionHistory(id: id) }
    }

    public func refreshSessions() async throws {
        let r: SessionsResult = try await rpc.call(RPCMethod.sessionsList, params: EmptyParams())
        setSessions(r.sessions)
        if let hooks = r.hooks { sessionHooksEnabled = hooks }
        sessionsSupported = true
    }

    /// One page of a session's conversation (the newest, or the one before
    /// message `before`), merged into what's held.
    @discardableResult
    public func loadSessionHistory(id: String, before: String? = nil, limit: Int = 50) async throws -> [CCMessage] {
        let r: SessionMessagesResult = try await rpc.call(RPCMethod.sessionsHistory,
                                                          params: SessionHistoryParams(id: id, before: before, limit: limit))
        let held = sessionHistories[id] ?? []
        let known = Set(held.map(\.id))
        let added = r.messages.contains { !known.contains($0.id) }
        sessionHistories[id] = Self.merge(held, r.messages, older: before != nil)
        if before != nil {
            sessionHistoryHasMore[id] = added && r.messages.count >= limit
        } else if held.isEmpty {
            sessionHistoryHasMore[id] = r.messages.count >= limit
        }
        return r.messages
    }

    /// The page goes in front (an older page) or at the end; a message held
    /// already takes the page's copy. Oldest first by time, the arrival order
    /// kept among equal times.
    nonisolated static func merge(_ held: [CCMessage], _ page: [CCMessage], older: Bool) -> [CCMessage] {
        // One line per id (the page's last copy): the list is keyed by id.
        var seen: Set<String> = []
        let page = page.reversed().filter { seen.insert($0.id).inserted }.reversed()
        let pageIDs = Set(page.map(\.id))
        let rest = held.filter { !pageIDs.contains($0.id) }
        let joined = older ? page + rest : rest + page
        return joined.enumerated().sorted { a, b in
            a.element.ts != b.element.ts ? a.element.ts < b.element.ts : a.offset < b.offset
        }.map(\.element)
    }

    /// A session page came on screen: its conversation follows the host's
    /// updates until it goes.
    public func watchSession(_ id: String) {
        watchedSessions[id, default: 0] += 1
    }

    public func unwatchSession(_ id: String) {
        guard let n = watchedSessions[id] else { return }
        watchedSessions[id] = n > 1 ? n - 1 : nil
    }

    // MARK: changes from the host

    func apply(sessionsUpdate u: SessionsUpdate) {
        switch u {
        case .list(let list):
            let before = Dictionary(sessions.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
            setSessions(list)
            sessionsSupported = true
            for s in list where watchedSessions[s.id] != nil && before[s.id] != s.updatedAt { reloadHistory(s.id) }
        case .upsert(let s):
            upsert(session: s)
            sessionsSupported = true
            if watchedSessions[s.id] != nil { reloadHistory(s.id) }
        case .removed(let id):
            sessions.removeAll { $0.id == id }
        case .changed(let id):
            refetchComputerSessions()
            if watchedSessions[id] != nil { reloadHistory(id) }
        case .refetch:
            refetchComputerSessions()
            for id in watchedSessions.keys { reloadHistory(id) }
        }
    }

    /// The list read again: from `pals.list` on a host with Pals (its
    /// `others` are what the list shows), `sessions.list` on one before them.
    private func refetchComputerSessions() {
        Task {
            if self.palsSupported == true { try? await self.refreshPals() } else { try? await self.refreshSessions() }
        }
    }

    func upsert(session s: CCSession) {
        var list = sessions
        if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s } else { list.append(s) }
        setSessions(list)
    }

    private func setSessions(_ list: [CCSession]) {
        let ordered = CCSession.listOrder(list)
        if ordered != sessions { sessions = ordered }
    }

    private func reloadHistory(_ id: String) {
        Task { _ = try? await self.loadSessionHistory(id: id) }
    }

    // MARK: helpers

    /// The 设置 switch: the global hooks on or off (§6.3).
    public func setSessionHooks(_ enabled: Bool) async throws {
        let before = sessionHooksEnabled
        sessionHooksEnabled = enabled
        do {
            let r: SessionHooksResult = try await rpc.call(RPCMethod.sessionsHooks, params: SessionHooksParams(enabled: enabled),
                                                           timeout: 30)
            sessionHooksEnabled = r.enabled
        } catch {
            sessionHooksEnabled = before
            throw error
        }
    }

    // MARK: helper proposals

    /// The proposal a message shows, with the owner's answer when it's newer
    /// than the host's copy.
    public func helperProposal(in message: ChatMessage) -> HelperProposal? {
        guard var p = message.proposal else { return nil }
        if p.isPending, let decided = helperDecisions[p.id] { p.status = decided }
        if p.sessionId == nil { p.sessionId = helperSessions[p.id] }
        if p.palId == nil, let sid = p.sessionId { p.palId = pal(sessionId: sid)?.id }
        return p
    }

    /// Proposals waiting for 开吧 / 不用.
    public var pendingHelperProposals: [HelperProposal] {
        messages.compactMap { $0.kind == .helper ? helperProposal(in: $0) : nil }.filter(\.isPending)
    }

    /// 开吧 / 不用, shown at once and put back if the computer didn't take
    /// it. 开吧 returns the new helper.
    @discardableResult
    public func decideHelper(_ proposal: HelperProposal, _ action: HelperDecideAction) async throws -> CCSession? {
        let before = helperDecisions[proposal.id]
        helperDecisions[proposal.id] = action == .create ? .created : .discarded
        do {
            // Starting a session takes a few seconds.
            let r: HelperDecideResult = try await rpc.call(RPCMethod.helperDecide,
                                                           params: HelperDecideParams(proposalId: proposal.id, action: action),
                                                           timeout: 45)
            if let p = r.pal {
                // A host with Pals opens one.
                var list = pals
                if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
                setPals(list, others: nil)
                helperSessions[proposal.id] = p.sessionId
                palsSupported = true
            } else if let s = r.session {
                upsert(session: s)
                helperSessions[proposal.id] = s.id
                sessionsSupported = true
            } else if action == .create {
                // Not started after all: the computer's copy says why (its note).
                helperDecisions[proposal.id] = before
            }
            return r.session
        } catch {
            helperDecisions[proposal.id] = before
            throw error
        }
    }

    // MARK: sessions' cards

    /// The session a card came from still waits at the computer (or the
    /// list can't say yet).
    public func waitsAtComputer(_ source: CardSource?) -> Bool {
        guard let source, source.isSession else { return false }
        if let s = otherSessions.first(where: { $0.id == source.id }) ?? session(id: source.id) { return s.status == .waiting }
        // Not on a list the host gave: it can't say yet, so it does.
        return sessionsSupported != true && palsSupported != true
    }

    /// A session's card that ran past the hook's limit here (「在电脑上等你」):
    /// the session asks in its terminal now, and the card stays, untappable,
    /// while it does. One the owner handled at the computer is not this.
    public func waitsAtComputer(_ a: Approval) -> Bool {
        a.status == .expired && !Self.handledAtComputer(by: a.decidedBy, note: a.note) && waitsAtComputer(a.source)
    }

    public func waitsAtComputer(_ q: Question) -> Bool {
        q.status == .expired && !Self.handledAtComputer(by: q.answeredBy, note: q.note) && waitsAtComputer(q.source)
    }

    /// The host's mark for a card that ended because the owner answered in
    /// the terminal (`decidedBy` "computer", 「已在电脑上处理」).
    nonisolated static func handledAtComputer(by: String?, note: String?) -> Bool {
        by == "computer" || note == "已在电脑上处理"
    }

    /// Settled at the computer, not here: it leaves the conversation (§5).
    public func settledAtComputer(_ a: Approval) -> Bool {
        guard a.source?.isSession == true else { return false }
        switch a.status {
        case .allowed, .denied: return a.decidedBy.map { $0 != "app" } ?? false
        case .expired: return !waitsAtComputer(a)
        default: return false
        }
    }

    public func settledAtComputer(_ q: Question) -> Bool {
        guard q.source?.isSession == true else { return false }
        switch q.status {
        case .answered: return q.answeredBy.map { $0 != "app" } ?? false
        case .expired: return !waitsAtComputer(q)
        default: return false
        }
    }

    /// Approvals at the conversation's live end: every pending one with no
    /// message of its own, and a session's that expired here while it still
    /// waits at the computer (shown as 「在电脑上等你」, not tappable).
    public var liveEndApprovals: [Approval] {
        let anchored = Set(messages.compactMap(\.approvalId))
        return approvals.filter { a in
            guard !anchored.contains(a.id), shows(a.source) else { return false }
            if a.isPending { return true }
            return waitsAtComputer(a)
        }
    }

    /// Sessions' questions at the live end (the assistant's own come with a
    /// message of their own): pending, or expired while still waiting at the
    /// computer. Oldest first, like approvals reading down.
    public var liveEndQuestions: [Question] {
        let anchored = Set(messages.compactMap(\.questionId))
        return questions.filter { q in
            // A Pal's come without a message of their own, like a session's.
            guard q.source?.isSession == true || q.source?.isPal == true, shows(q.source), !anchored.contains(q.id)
            else { return false }
            if q.isPending { return true }
            return waitsAtComputer(q)
        }.sorted { $0.createdAt < $1.createdAt }
    }
}
