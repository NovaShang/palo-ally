import Foundation

// 回到这里重来 (docs/rewind-prd.md): the owner long-presses one of their own
// messages (right-clicks on a Mac), confirms in place of the composer, and the
// conversation goes back to just before it. The host forks the session; here
// that message and everything after it leave the list, and its words come
// back for the composer. In a Pal the files can go back too.

extension AppStore {
    /// Whether 回到这里重来 is offered on this message: the owner's own words,
    /// sent and known to the host. In the assistant's conversation only
    /// those it has a uuid for (older ones it couldn't match aren't).
    public func canRewind(to m: ChatMessage) -> Bool {
        guard m.role == .user, m.kind == .text, m.seq > 0, m.delivery == .sent, !m.isStreaming,
              !m.id.hasPrefix("local-"), !m.text.isEmpty else { return false }
        switch scope {
        case .palo: return m.pal == nil && !(m.uuid ?? "").isEmpty
        // A Pal: not the assistant's words to it, nor another session's.
        case .pal: return (m.from ?? "").isEmpty && m.channel != .system
        case .session: return false
        }
    }

    /// The conversation is working now: going back stops it first.
    public var busyForRewind: Bool {
        if awaitingReply || !streams.isEmpty { return true }
        if let palID, let p = pal(id: palID) { return p.status == .busy || p.status == .waiting || p.status == .starting }
        return status?.busy == true
    }

    /// A Pal: whether Claude Code kept its files as they were before `m`
    /// (only then can they go back too). False when it can't say.
    public func canRestoreFiles(to m: ChatMessage) async -> Bool {
        guard let palID else { return false }
        let r = try? await rpc.call(RPCMethod.palsRewind, params: PalRewindParams(id: palID, messageId: m.id, check: true),
                                    as: PalRewindCheck.self)
        return r?.canRestoreFiles ?? false
    }

    /// Goes back to just before `m`. A turn still on is stopped first, so
    /// it's one step for the owner. That message and the ones after it leave
    /// the list (through `animateRewind`); its words come back. A Pal's page
    /// is read again (a copy of its conversation may have new ids).
    public func rewind(to m: ChatMessage, restoreFiles: Bool = false) async throws -> RewindOutcome {
        var stopped = false
        var outcome: RewindOutcome?
        for attempt in 0..<12 {
            do {
                outcome = try await callRewind(m, restoreFiles: restoreFiles)
                break
            } catch RPCError.remote(let why) where (why.contains("还在忙") || why.contains("still busy")) && attempt < 11 {  // i18n-ok: the host's own words, in either language
                // Stopped once; it may take a moment to wind down.
                if !stopped {
                    stopped = true
                    try await stop()
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let outcome else { throw FriendlyError(loc("它还在忙，先停下再重来")) }
        dropRewound(from: m.id, ids: [])
        // The quote it carried comes back with its words (the assistant's).
        if palID == nil, let reply = m.replyTo { replyDraft = reply }
        rewindTarget = nil
        if palID != nil { await reloadPalHistory(fresh: true) }
        return outcome
    }

    private func callRewind(_ m: ChatMessage, restoreFiles: Bool) async throws -> RewindOutcome {
        if let palID {
            let r = try await rpc.call(RPCMethod.palsRewind,
                                       params: PalRewindParams(id: palID, messageId: m.id, restoreFiles: restoreFiles ? true : nil),
                                       as: PalRewindResult.self, timeout: 90)
            return RewindOutcome(text: r.text, filesRestored: r.filesRestored)
        }
        let r = try await rpc.call(RPCMethod.chatRewind, params: ChatRewindParams(messageId: m.id), as: ChatRewindResult.self)
        return RewindOutcome(text: r.text, filesRestored: false)
    }

    func dropRewound(from id: String, ids: [String]) {
        dropRewound(from: Optional(id), ids: Set(ids))
    }
}
