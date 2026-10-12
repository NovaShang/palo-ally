import Foundation

/// Pals (pals-prd §3–§5, §8): the list with the computer's other live
/// sessions, each Pal's scoped store (its conversation; see `Scope`),
/// adopting a session, handing a Pal back to the terminal, and removing one.
extension AppStore {
    // MARK: reading

    public func pal(id: String) -> Pal? { pals.first { $0.id == id } }

    /// The Pal resuming that Claude Code session, if one does.
    public func pal(sessionId: String) -> Pal? { pals.first { $0.sessionId == sessionId } }

    /// One Pal's scoped store: its conversation, read and written like the
    /// assistant's. Made on first use and kept while the app runs; the
    /// assistant's store feeds it the Pal's events and state.
    public func palStore(_ id: String) -> AppStore {
        if let parent { return parent.palStore(id) }
        if let s = palStores[id] { return s }
        let s = AppStore(pal: id, parent: self)
        palStores[id] = s
        preparePalStore?(s)
        if let p = pal(id: id) { s.applyPal(p) }
        if connection.isOnline { Task { await s.reloadPalHistory() } }
        return s
    }

    /// How many of a Pal's cards wait on the owner: the host's count, or the
    /// cards here when there are more of them (one just arrived).
    public func palPendingCount(_ id: String) -> Int {
        let here = approvals.filter { $0.isPending && $0.source?.isPal == true && $0.source?.id == id }.count
            + questions.filter { $0.isPending && $0.source?.isPal == true && $0.source?.id == id }.count
        return max(here, pal(id: id)?.pending ?? 0)
    }

    /// The cards waiting on the owner from one of the computer's other sessions.
    public func sessionPendingCount(_ id: String) -> Int {
        approvals.filter { $0.isPending && $0.source?.isSession == true && $0.source?.id == id }.count
            + questions.filter { $0.isPending && $0.source?.isSession == true && $0.source?.id == id }.count
    }

    // MARK: loading

    /// After every catch-up. A host that doesn't know Pals says so once, and
    /// they stay hidden.
    public func loadPals() async {
        do {
            try await refreshPals()
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") {
                palsSupported = false
            }
        }
    }

    public func refreshPals() async throws {
        if let parent { return try await parent.refreshPals() }
        let r: PalsResult = try await rpc.call(RPCMethod.palsList, params: EmptyParams())
        setPals(r.pals, others: r.others)
        if let hooks = r.hooks { sessionHooksEnabled = hooks }
        palsSupported = true
    }

    // MARK: changes from the host

    func apply(palsUpdate u: PalsUpdate) {
        guard scope == .palo else { return }
        switch u {
        case .list(let r, let hasOthers):
            setPals(r.pals, others: hasOthers ? r.others : nil)
            if let hooks = r.hooks { sessionHooksEnabled = hooks }
            palsSupported = true
        case .upsert(let p):
            var list = pals
            if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
            setPals(list, others: nil)
            palsSupported = true
        case .removed(let id):
            setPals(pals.filter { $0.id != id }, others: nil)
        case .refetch:
            Task { try? await self.refreshPals() }
        }
    }

    /// The list as the host has it; each Pal's store takes its state, and a
    /// session waiting to be adopted that is a Pal now is done.
    func setPals(_ list: [Pal], others: [CCSession]?) {
        if list != pals { pals = list }
        if let others {
            // A session becoming a Pal leaves the others.
            let rest = others.filter { s in !list.contains { $0.sessionId == s.id } }
            if rest != otherSessions { otherSessions = rest }
            // The host stopped waiting for one to be quit (it gave up after
            // a while, and says so in the conversation).
            for s in rest where s.adopting == false && adoptions[s.id] == .waitingForExit { adoptions[s.id] = nil }
        } else if otherSessions.contains(where: { s in list.contains { $0.sessionId == s.id } }) {
            otherSessions.removeAll { s in list.contains { $0.sessionId == s.id } }
        }
        for p in list {
            guard let page = palStores[p.id] else { continue }
            page.applyPal(p)
            // A page opened before its Pal was on the list: its conversation now.
            if !page.hasSynced, connection.isOnline { Task { await page.reloadPalHistory() } }
        }
        // Waiting for a terminal session to be quit: it's a Pal now. (One
        // still being asked for is finished by `adopt` itself.)
        for (sid, state) in adoptions where state == .waitingForExit {
            guard let p = list.first(where: { $0.sessionId == sid }) else { continue }
            adoptions[sid] = nil
            onAdopted?(p)
        }
    }

    // MARK: adopting

    /// What `adopt` came to.
    public enum AdoptOutcome: Sendable, Equatable {
        /// It's a Pal: its page can open.
        case adopted(Pal)
        /// A terminal session: the owner quits it there first; the host
        /// carries on by itself (`onAdopted` then).
        case waitingForExit
    }

    /// 接管: the host stops the original (a background session) or waits
    /// for it to be quit in its terminal, then resumes its record as a Pal.
    /// Never two processes on one record (§5): when the original can't be
    /// stopped, this throws with the host's reason.
    @discardableResult
    public func adopt(sessionId: String) async throws -> AdoptOutcome {
        if let parent { return try await parent.adopt(sessionId: sessionId) }
        adoptions[sessionId] = .working
        do {
            // Stopping a background session and resuming it takes a few seconds.
            let r: PalAdoptResult = try await rpc.call(RPCMethod.palsAdopt, params: PalAdoptParams(sessionId: sessionId),
                                                       timeout: 30)
            cancelledWaits.remove(sessionId)
            if let p = r.pal {
                adoptions[sessionId] = nil
                var list = pals
                if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
                setPals(list, others: nil)
                palsSupported = true
                return .adopted(p)
            }
            // Asked to quit it in the terminal (or a wait this client can't
            // name): the Pal shows up in the list once it's done.
            if let p = pal(sessionId: sessionId) {
                // Done before the answer came.
                adoptions[sessionId] = nil
                return .adopted(p)
            }
            adoptions[sessionId] = .waitingForExit
            return .waitingForExit
        } catch {
            adoptions[sessionId] = .failed(Friendly.message(error))
            throw error
        }
    }

    /// The owner stopped waiting for a terminal session to be quit: this
    /// device no longer opens it when it's adopted.
    public func cancelAdoption(sessionId: String) {
        adoptions[sessionId] = nil
        cancelledWaits.insert(sessionId)
    }

    /// A session waits to be quit in its terminal before it's adopted: asked
    /// from this device, or (the host says) from another.
    public func waitsForExit(_ s: CCSession) -> Bool {
        adoptions[s.id] == .waitingForExit || (s.adopting == true && adoptions[s.id] == nil && !cancelledWaits.contains(s.id))
    }

    /// The failed adoption's note was read.
    public func clearAdoption(sessionId: String) {
        if case .failed? = adoptions[sessionId] { adoptions[sessionId] = nil }
    }

    // MARK: releasing and removing

    /// 交还终端: the host closes its own process; the returned line resumes
    /// the record in a terminal.
    public func releasePal(id: String) async throws -> String {
        if let parent { return try await parent.releasePal(id: id) }
        let before = pal(id: id)
        let r: PalReleaseResult = try await rpc.call(RPCMethod.palsRelease, params: IDParams(id: id), timeout: 30)
        let command = r.resumeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await refreshPals()
        return command.isEmpty ? (before?.resumeCommand ?? "claude --resume") : command
    }

    /// 移出 Pals.
    public func removePal(id: String) async throws {
        if let parent { return try await parent.removePal(id: id) }
        _ = try await rpc.call(RPCMethod.palsRemove, params: IDParams(id: id), as: OKResult.self, timeout: 30)
        setPals(pals.filter { $0.id != id }, others: nil)
        try? await refreshPals()
    }
}
