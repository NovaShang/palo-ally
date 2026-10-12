import Foundation

/// Words the owner sent to a session from the app, shown until the
/// session's own conversation has them.
public struct SessionPendingSend: Identifiable, Sendable, Hashable {
    public enum State: Sendable, Hashable { case sending, sent, failed }
    public var id: String
    public var text: String
    /// When it was sent (ms).
    public var sentAt: Int64
    public var state: State
}

/// Sessions (sessions-prd §5, §7): the computer's Claude Code sessions, one
/// session's conversation, the owner's words into one, helpers' lifecycle,
/// the hooks switch, and the owner's answer to a helper proposal. Their
/// approvals and questions are ordinary cards with a `source`.
extension AppStore {
    // MARK: reading

    public func session(id: String) -> CCSession? { sessions.first { $0.id == id } }

    /// One session's conversation held here, oldest first.
    public func sessionHistory(_ id: String) -> [CCMessage] { sessionHistories[id] ?? [] }

    public func pendingSends(_ id: String) -> [SessionPendingSend] { sessionPending[id] ?? [] }

    // MARK: loading

    /// After every catch-up. A host that doesn't know sessions says so once,
    /// and they stay hidden.
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
        resolvePending(id)
        return r.messages
    }

    /// The page goes in front (an older page) or at the end; a message held
    /// already takes the page's copy. Oldest first by time, the arrival order
    /// kept among equal times.
    nonisolated static func merge(_ held: [CCMessage], _ page: [CCMessage], older: Bool) -> [CCMessage] {
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
            Task { try? await self.refreshSessions() }
            if watchedSessions[id] != nil { reloadHistory(id) }
        case .refetch:
            Task { try? await self.refreshSessions() }
            for id in watchedSessions.keys { reloadHistory(id) }
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

    // MARK: talking to a session

    /// The owner's words into a session, as typed (§6.4). They show at once
    /// as sent-but-not-there-yet, until the session's conversation has them.
    public func sendToSession(id: String, text raw: String) async throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let p = SessionPendingSend(id: UUID().uuidString, text: text, sentAt: Date().epochMillis, state: .sending)
        sessionPending[id, default: []].append(p)
        try await deliver(p, to: id)
    }

    /// Sends a failed one again.
    public func retrySend(_ pending: SessionPendingSend, to id: String) async throws {
        setPending(id, pending.id) { $0.state = .sending; $0.sentAt = Date().epochMillis }
        guard let p = sessionPending[id]?.first(where: { $0.id == pending.id }) else { return }
        try await deliver(p, to: id)
    }

    /// Gives up on a failed one.
    public func dropSend(_ pending: SessionPendingSend, from id: String) {
        sessionPending[id]?.removeAll { $0.id == pending.id }
    }

    private func deliver(_ p: SessionPendingSend, to id: String) async throws {
        do {
            // The errand session may have to start first (§6.4): a few seconds.
            _ = try await rpc.call(RPCMethod.sessionsSend, params: SessionSendParams(id: id, text: p.text),
                                   as: OKResult.self, timeout: 45)
            setPending(id, p.id) { $0.state = .sent }
            // The host says when it's there (`sessions.updated`); the
            // conversation is read again then. Once more here in case.
            Task {
                try? await Task.sleep(for: .seconds(4))
                if self.sessionPending[id]?.contains(where: { $0.id == p.id }) == true {
                    _ = try? await self.loadSessionHistory(id: id)
                }
            }
        } catch {
            setPending(id, p.id) { $0.state = .failed }
            throw error
        }
    }

    private func setPending(_ id: String, _ pid: String, _ change: (inout SessionPendingSend) -> Void) {
        guard var list = sessionPending[id], let i = list.firstIndex(where: { $0.id == pid }) else { return }
        change(&list[i])
        sessionPending[id] = list
    }

    /// Sent words the conversation now shows are no longer pending: each
    /// takes the first line from the owner or PaloAlly with the same words,
    /// said around or after the send.
    func resolvePending(_ id: String) {
        guard let pending = sessionPending[id], !pending.isEmpty else { return }
        let history = sessionHistory(id)
        var used: Set<String> = []
        var left: [SessionPendingSend] = []
        for p in pending {
            guard p.state != .failed else { left.append(p); continue }
            let match = history.first { m in
                !used.contains(m.id) && (m.role == .palo || m.role == .owner) && m.ts >= p.sentAt - 120_000
                    && m.shownText.trimmingCharacters(in: .whitespacesAndNewlines) == p.text
            }
            if let match { used.insert(match.id) } else { left.append(p) }
        }
        sessionPending[id] = left.isEmpty ? nil : left
    }

    // MARK: helpers

    /// 停止 / 重启 / 删除 / 复活 (helpers only). Shown at once; the host's
    /// list follows.
    public func controlSession(id: String, action: SessionControlAction) async throws {
        let before = session(id: id)
        if var s = before {
            switch action {
            case .stop, .remove: s.status = .stopped
            case .restart, .revive: s.status = .idle
            }
            upsert(session: s)
        }
        do {
            _ = try await rpc.call(RPCMethod.sessionsControl, params: SessionControlParams(id: id, action: action),
                                   as: OKResult.self, timeout: 30)
        } catch {
            if let before { upsert(session: before) }
            throw error
        }
        try? await refreshSessions()
    }

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
            if let s = r.session {
                upsert(session: s)
                helperSessions[proposal.id] = s.id
                sessionsSupported = true
            }
            return r.session
        } catch {
            helperDecisions[proposal.id] = before
            throw error
        }
    }

    // MARK: sessions' cards

    /// A session's card is still waiting at the computer: it expired here
    /// and the session still waits there (or the list can't say yet).
    public func waitsAtComputer(_ source: CardSource?) -> Bool {
        guard let source, source.isSession else { return false }
        guard sessionsSupported == true else { return true }
        return session(id: source.id)?.status == .waiting
    }

    /// Settled at the computer, not here: it leaves the conversation (§5).
    public func settledAtComputer(_ a: Approval) -> Bool {
        guard a.source?.isSession == true else { return false }
        switch a.status {
        case .allowed, .denied: return a.decidedBy.map { $0 != "app" } ?? false
        case .expired: return !waitsAtComputer(a.source)
        default: return false
        }
    }

    public func settledAtComputer(_ q: Question) -> Bool {
        guard q.source?.isSession == true else { return false }
        switch q.status {
        case .answered: return q.answeredBy.map { $0 != "app" } ?? false
        case .expired: return !waitsAtComputer(q.source)
        default: return false
        }
    }

    /// Approvals at the conversation's live end: every pending one with no
    /// message of its own, and a session's that expired here while it still
    /// waits at the computer (shown as 「在电脑上等你」, not tappable).
    public var liveEndApprovals: [Approval] {
        let anchored = Set(messages.compactMap(\.approvalId))
        return approvals.filter { a in
            guard !anchored.contains(a.id) else { return false }
            if a.isPending { return true }
            return a.status == .expired && waitsAtComputer(a.source)
        }
    }

    /// Sessions' questions at the live end (the assistant's own come with a
    /// message of their own): pending, or expired while still waiting at the
    /// computer. Oldest first, like approvals reading down.
    public var liveEndQuestions: [Question] {
        let anchored = Set(messages.compactMap(\.questionId))
        return questions.filter { q in
            guard q.source?.isSession == true, !anchored.contains(q.id) else { return false }
            if q.isPending { return true }
            return q.status == .expired && waitsAtComputer(q.source)
        }.sorted { $0.createdAt < $1.createdAt }
    }
}
