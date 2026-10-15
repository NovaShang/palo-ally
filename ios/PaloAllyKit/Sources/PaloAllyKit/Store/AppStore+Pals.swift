import Foundation

/// Pals (pals-prd §3–§5, §8, §10): the list with the computer's other live
/// sessions, each Pal's scoped store (its conversation; see `Scope`),
/// adopting a session (a live one, or one that ended lately), the
/// assistant's `pal_adopt` cards, handing a Pal back to the terminal, and
/// removing one.
extension AppStore {
    // MARK: reading

    public func pal(id: String) -> Pal? { pals.first { $0.id == id } }

    /// The Pals as the list shows them: awake ones first, then those asleep
    /// (§12), each the most lately used first.
    public var listedPals: [Pal] { Pal.listed(pals) }

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

    /// After every catch-up. `pals.list` brings the Pals, the computer's
    /// other sessions and the hooks switch in one answer, so `sessions.list`
    /// isn't asked as well. A host from before Pals says so once: they stay
    /// hidden, and that host's sessions are asked for instead.
    public func loadPals() async {
        do {
            try await refreshPals()
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") {
                palsSupported = false
                await loadSessions()
            }
            return
        }
        for id in watchedSessions.keys { _ = try? await loadSessionHistory(id: id) }
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
        // A recent conversation adopted (here, from a card, or on another device) is a Pal now.
        if let recent = recentSessions, recent.contains(where: { s in list.contains { $0.sessionId == s.sessionId } }) {
            recentSessions = recent.filter { s in !list.contains { $0.sessionId == s.sessionId } }
        }
        if let others {
            // A session becoming a Pal leaves the others.
            let rest = others.filter { s in !list.contains { $0.sessionId == s.id } }
            if rest != otherSessions { otherSessions = rest }
            // The host stopped waiting for one to be quit (it gave up after
            // a while and says so in the conversation, or a device cancelled):
            // it leaves `adopting` out.
            for s in rest where s.adopting != true {
                if adoptions[s.id] == .waitingForExit { adoptions[s.id] = nil }
                cancelledWaits.remove(s.id)
            }
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

    /// The owner stopped waiting for a terminal session to be quit: shown at
    /// once, and the host stops waiting too (`pals.adopt {cancel}`), so
    /// quitting it later adopts nothing. Should the host not hear it (offline),
    /// this device still doesn't open it when it's adopted.
    public func cancelAdoption(sessionId: String) async {
        if let parent { return await parent.cancelAdoption(sessionId: sessionId) }
        adoptions[sessionId] = nil
        cancelledWaits.insert(sessionId)
        _ = try? await rpc.call(RPCMethod.palsAdopt, params: PalAdoptParams(sessionId: sessionId, cancel: true),
                                as: PalAdoptResult.self)
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

    // MARK: waking (§12)

    /// 叫醒: an asleep Pal resumes its session (the host answers once it's
    /// up). Words for it wake it by themselves; this is for waking it ahead.
    @discardableResult
    public func wakePal(id: String) async throws -> Pal? {
        if let parent { return try await parent.wakePal(id: id) }
        // Resuming a session takes a few seconds.
        let r: PalWakeResult = try await rpc.call(RPCMethod.palsWake, params: IDParams(id: id), timeout: 45)
        if let p = r.pal {
            var list = pals
            if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
            setPals(list, others: nil)
        }
        return r.pal
    }

    // MARK: naming (§13)

    /// 重命名: the host renames it, and Claude Code's title for it too (a
    /// name another Pal has comes back with a number). Shown at once; put
    /// back when the host says no.
    @discardableResult
    public func renamePal(id: String, name: String) async throws -> Pal? {
        if let parent { return try await parent.renamePal(id: id, name: name) }
        let want = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { throw RPCError.remote("名字不能是空的") }
        let before = pals
        if let i = pals.firstIndex(where: { $0.id == id }) {
            var list = pals
            list[i].name = want
            setPals(list, others: nil)
        }
        do {
            let r: PalRenameResult = try await rpc.call(RPCMethod.palsRename, params: PalRenameParams(id: id, name: want), timeout: 30)
            if let p = r.pal {
                var list = pals
                if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
                setPals(list, others: nil)
            }
            return r.pal
        } catch {
            setPals(before, others: nil)
            throw error
        }
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

    // MARK: recent conversations (§10)

    /// `pals.recent`: the computer's conversations that ended in the last 30
    /// days, to adopt (`adopt(sessionId:)` resumes one straight away). A
    /// host from before them says so once (`recentSupported` false).
    public func refreshRecent() async throws {
        if let parent { return try await parent.refreshRecent() }
        do {
            // The host reads the records on disk.
            let r: PalsRecentResult = try await rpc.call(RPCMethod.palsRecent, params: PalsRecentParams(), timeout: 30)
            recentSessions = r.sessions.filter { pal(sessionId: $0.sessionId) == nil }
            recentSupported = true
        } catch {
            if case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") { recentSupported = false }
            throw error
        }
    }

    /// The recent conversations by folder, the folder used most lately
    /// first; with a query, those whose title or folder has it.
    public func recentFolders(matching query: String = "") -> [RecentFolder] {
        RecentFolder.group(recentSessions ?? [], matching: query)
    }

    // MARK: the assistant's pal_adopt cards (§10)

    /// The card a message shows, with the owner's answer when it's newer than
    /// the host's copy, and the Pal it became once that's known.
    public func adoptProposal(in message: ChatMessage) -> PalAdoptProposal? {
        guard message.kind == .palAdopt, var p = message.adoption else { return nil }
        // Still on offer: waiting, or not taken over last time (tapped again).
        if p.isPending || p.status == .failed, let decided = adoptDecisions[p.id] { p.status = decided }
        if p.palId == nil { p.palId = adoptProposalPals[p.id] ?? (p.status == .adopted ? pal(sessionId: p.sessionId)?.id : nil) }
        return p
    }

    /// Cards waiting for 接管 / 不用 (one that failed is still on offer, but
    /// doesn't wait on the owner).
    public var pendingAdoptProposals: [PalAdoptProposal] {
        messages.compactMap { adoptProposal(in: $0) }.filter(\.isPending)
    }

    /// Proposals of either kind waiting on the owner (a helper's 开吧, a
    /// conversation's 接管).
    public var pendingProposalCount: Int { pendingHelperProposals.count + pendingAdoptProposals.count }

    /// 接管 / 不用 on a card (`helper.decide`), shown at once and put back if
    /// the computer didn't take it. 接管 returns the Pal it became.
    @discardableResult
    public func decideAdopt(_ proposal: PalAdoptProposal, _ action: HelperDecideAction) async throws -> Pal? {
        if let parent { return try await parent.decideAdopt(proposal, action) }
        let before = adoptDecisions[proposal.id]
        adoptDecisions[proposal.id] = action == .create ? .adopted : .discarded
        do {
            // Resuming a record takes a few seconds.
            let r: HelperDecideResult = try await rpc.call(RPCMethod.helperDecide,
                                                           params: HelperDecideParams(proposalId: proposal.id, action: action),
                                                           timeout: 45)
            if let p = r.pal {
                var list = pals
                if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
                setPals(list, others: nil)
                adoptProposalPals[proposal.id] = p.id
                palsSupported = true
                return p
            }
            if action == .create {
                // Not adopted after all: the computer's copy of the card says
                // why (failed, with a note), and it can be tapped again.
                adoptDecisions[proposal.id] = before
            }
            return nil
        } catch {
            adoptDecisions[proposal.id] = before
            throw error
        }
    }
}
