import Foundation

/// The workbench (docs/workbench-rpc.md): workspaces that group sessions,
/// starting and ending sessions, 以前的 and resuming from it, folders to
/// start in, and marking a session seen.
extension AppStore {
    // MARK: reading

    /// The workspaces, as the host has them.
    public internal(set) var workspaces: [Workspace] {
        get { shared.workspaces }
        set { shared.workspaces = newValue }
    }
    /// false for a host from before workspaces.
    public internal(set) var workspacesSupported: Bool? {
        get { shared.workspacesSupported }
        set { shared.workspacesSupported = newValue }
    }
    /// 以前的, newest first; nil until `pals.earlier` has answered.
    public internal(set) var earlierItems: [EarlierItem]? {
        get { shared.earlierItems }
        set { shared.earlierItems = newValue }
    }
    /// false for a host from before 以前的.
    public internal(set) var earlierSupported: Bool? {
        get { shared.earlierSupported }
        set { shared.earlierSupported = newValue }
    }

    public func workspace(id: String) -> Workspace? { workspaces.first { $0.id == id } }

    /// The owner's order of the sessions in no workspace; nil from a host that keeps none.
    public internal(set) var sessionOrder: [String]? {
        get { shared.sessionOrder }
        set { shared.sessionOrder = newValue }
    }

    /// The sidebar's sections, in the owner's manual order.
    public var sidebarTree: SidebarTree { SidebarTree.build(pals: pals, workspaces: workspaces, sessionOrder: sessionOrder) }

    /// Sessions waiting on the owner, anywhere.
    public var waitingSessionCount: Int { pals.filter { $0.attention == .waiting }.count }

    // MARK: loading

    /// After every catch-up (with the Pals): the workspaces, once.
    public func refreshWorkspaces() async throws {
        if let parent { return try await parent.refreshWorkspaces() }
        do {
            let r: WorkspacesResult = try await rpc.call(RPCMethod.workspacesList, params: EmptyParams())
            workspacesSupported = true
            setWorkspaces(r.workspaces)
            if r.sessionOrder != sessionOrder { sessionOrder = r.sessionOrder }
        } catch {
            if isUnknownMethod(error) { workspacesSupported = false }
            throw error
        }
    }

    /// `pals.earlier`: 以前的.
    public func refreshEarlier(limit: Int = 200) async throws {
        if let parent { return try await parent.refreshEarlier(limit: limit) }
        do {
            // The host reads the records on disk.
            let r: EarlierResult = try await rpc.call(RPCMethod.palsEarlier, params: EarlierParams(limit: limit), timeout: 30)
            if r.items != earlierItems { earlierItems = r.items }
            earlierSupported = true
        } catch {
            if isUnknownMethod(error) { earlierSupported = false }
            throw error
        }
    }

    /// `pals.folders`: folders to start a session in, the latest first.
    public func sessionFolders(limit: Int = 20) async throws -> [SessionFolder] {
        if let parent { return try await parent.sessionFolders(limit: limit) }
        let r: FoldersResult = try await rpc.call(RPCMethod.palsFolders, params: FoldersParams(limit: limit))
        return r.folders
    }

    private func isUnknownMethod(_ error: Error) -> Bool {
        if case .remote(let m)? = error as? RPCError { return m.lowercased().contains("unknown method") }
        return false
    }

    // MARK: changes from the host

    /// `workspaces.updated`: the whole table. A workspace this device wrote
    /// more lately than the echo says is kept (the echo of an older write).
    func apply(workspacesUpdate json: JSONValue) {
        guard scope == .palo, let r = try? json.decode(WorkspacesResult.self) else { return }
        var list = r.workspaces
        for (i, w) in list.enumerated() {
            if let mine = workspaces.first(where: { $0.id == w.id }), mine.updatedAt > w.updatedAt { list[i] = mine }
        }
        setWorkspaces(list)
        // Order echoes: the host's array order and sessionOrder win, except a
        // workspace this device wrote more lately keeps its place in `list`.
        if r.sessionOrder != sessionOrder { sessionOrder = r.sessionOrder }
        workspacesSupported = true
    }

    func setWorkspaces(_ list: [Workspace]) {
        if list != workspaces { workspaces = list }
    }

    /// A session changed in place: shown at once.
    func upsert(pal p: Pal) {
        var list = pals
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
        setPals(list, others: nil)
        palsSupported = true
    }

    // MARK: sessions

    /// 新建会话: a session in a folder; the host may still be starting it.
    @discardableResult
    public func createSession(cwd: String, name: String? = nil, text: String? = nil, workspaceId: String? = nil) async throws -> Pal {
        if let parent { return try await parent.createSession(cwd: cwd, name: name, text: text, workspaceId: workspaceId) }
        let r: PalWakeResult = try await rpc.call(RPCMethod.palsCreate,
                                                  params: PalCreateParams(cwd: cwd, name: name, text: text, workspaceId: workspaceId),
                                                  timeout: 45)
        guard let p = r.pal else { throw RPCError.badResponse }
        upsert(pal: p)
        if workspaceId != nil { try? await refreshWorkspaces() }
        return p
    }

    /// The owner opened it (or saw it finish): a finished turn is seen at
    /// once here, and the host is told so every device's dot follows.
    public func markSeen(id: String) {
        if let parent { return parent.markSeen(id: id) }
        guard var p = pal(id: id), p.attention == .done else { return }
        p.seenAt = max(Date().epochMillis, p.finishedAt ?? 0)
        p.attention = .idle
        upsert(pal: p)
        Task { [weak self] in
            guard let self, self.connection.isOnline else { return }
            if let r = try? await self.rpc.call(RPCMethod.palsSeen, params: IDParams(id: id), as: PalWakeResult.self),
               let fresh = r.pal {
                self.upsert(pal: fresh)
            }
        }
    }

    /// 结束这个会话: its process closes and it moves to 以前的.
    @discardableResult
    public func endSession(id: String) async throws -> EarlierItem? {
        if let parent { return try await parent.endSession(id: id) }
        let r: PalEndResult = try await rpc.call(RPCMethod.palsEnd, params: IDParams(id: id), timeout: 30)
        setPals(pals.filter { $0.id != id }, others: nil)
        if let e = r.earlier, earlierItems != nil {
            earlierItems = [e] + (earlierItems ?? []).filter { $0.key != e.key && $0.sessionId != e.sessionId }
        }
        try? await refreshWorkspaces()
        return r.earlier
    }

    /// 接着聊 from 以前的: it is a session again (`pals.resume`).
    @discardableResult
    public func resume(_ item: EarlierItem) async throws -> Pal {
        if let parent { return try await parent.resume(item) }
        // Waking or resuming a record takes a few seconds.
        let r: PalWakeResult = try await rpc.call(RPCMethod.palsResume, params: PalResumeParams(key: item.key), timeout: 45)
        guard let p = r.pal else { throw RPCError.badResponse }
        upsert(pal: p)
        earlierItems = earlierItems?.filter { $0.key != item.key && $0.sessionId != item.sessionId }
        if item.workspaceId != nil { try? await refreshWorkspaces() }
        return p
    }

    // MARK: workspaces

    @discardableResult
    public func createWorkspace(name: String? = nil, memberIds: [String]) async throws -> Workspace {
        if let parent { return try await parent.createWorkspace(name: name, memberIds: memberIds) }
        let r: WorkspaceResult = try await rpc.call(RPCMethod.workspacesCreate,
                                                    params: WorkspaceCreateParams(name: name, memberIds: memberIds))
        guard let w = r.workspace else { throw RPCError.badResponse }
        // A new workspace goes on top of the owner's order (a host that keeps none: at the end).
        setWorkspaces(sessionOrder != nil ? [w] + workspaces.filter { $0.id != w.id } : workspaces.filter { $0.id != w.id } + [w])
        // Members moved in: their lists change with it.
        try? await refreshPals()
        try? await refreshWorkspaces()
        return w
    }

    /// Name and tiling; shown at once, put back when the host says no.
    @discardableResult
    public func updateWorkspace(id: String, name: String? = nil, layout: JSONValue? = nil, memberIds: [String]? = nil) async throws -> Workspace {
        if let parent { return try await parent.updateWorkspace(id: id, name: name, layout: layout, memberIds: memberIds) }
        let before = workspaces
        if let i = workspaces.firstIndex(where: { $0.id == id }) {
            var list = workspaces
            if let name { list[i].name = name }
            if let layout { list[i].layout = layout == .null ? nil : layout }
            if let memberIds { list[i].memberIds = Self.reordered(list[i].memberIds, by: memberIds) }
            list[i].updatedAt = max(list[i].updatedAt, Date().epochMillis)
            setWorkspaces(list)
        }
        do {
            let r: WorkspaceResult = try await rpc.call(RPCMethod.workspacesUpdate,
                                                        params: WorkspaceUpdateParams(id: id, name: name, layout: layout, memberIds: memberIds))
            guard let w = r.workspace else { throw RPCError.badResponse }
            setWorkspaces(workspaces.map { $0.id == w.id ? w : $0 })
            return w
        } catch {
            setWorkspaces(before)
            throw error
        }
    }

    /// Into a workspace, out of one (`workspaceId` nil), or to another; `index`
    /// is where it lands in that workspace's members, or in the ordinary
    /// sessions when it leaves one. Shown at once, put back when the host says no.
    public func moveSession(_ palId: String, to workspaceId: String?, index: Int? = nil) async throws {
        if let parent { return try await parent.moveSession(palId, to: workspaceId, index: index) }
        let (beforeWS, beforeOrder, beforePals) = (workspaces, sessionOrder, pals)
        applyMoveLocally(palId, to: workspaceId, index: index)
        do {
            let r: WorkspacesResult = try await rpc.call(RPCMethod.workspacesMove,
                                                         params: WorkspaceMoveParams(palId: palId, workspaceId: workspaceId, index: index))
            var list = workspaces
            for w in r.workspaces {
                if let i = list.firstIndex(where: { $0.id == w.id }) { list[i] = w } else { list.append(w) }
            }
            setWorkspaces(list)
        } catch {
            setWorkspaces(beforeWS); sessionOrder = beforeOrder; setPals(beforePals, others: nil)
            throw error
        }
        // A workspace left empty by the move stays; the host's order and lists are the truth.
        try? await refreshPals()
        try? await refreshWorkspaces()
    }

    /// The same move as the host will make, drawn before it answers.
    func applyMoveLocally(_ palId: String, to workspaceId: String?, index: Int?) {
        var list = workspaces
        for i in list.indices { list[i].memberIds.removeAll { $0 == palId } }
        var order = sessionOrder
        order?.removeAll { $0 == palId }
        if let workspaceId, let i = list.firstIndex(where: { $0.id == workspaceId }) {
            let at = min(max(index ?? list[i].memberIds.count, 0), list[i].memberIds.count)
            list[i].memberIds.insert(palId, at: at)
            list[i].updatedAt = max(list[i].updatedAt, Date().epochMillis)
        } else if order != nil {
            let at = min(max(index ?? 0, 0), order!.count)
            order!.insert(palId, at: at)
        }
        setWorkspaces(list)
        if order != sessionOrder { sessionOrder = order }
        if var p = pal(id: palId) {
            p.workspaceId = workspaceId
            upsert(pal: p)
        }
    }

    /// `ids` first in that order, then whatever it didn't name in its old order.
    static func reordered(_ old: [String], by ids: [String]) -> [String] {
        var seen = Set<String>()
        let named = ids.filter { old.contains($0) && seen.insert($0).inserted }
        return named + old.filter { !seen.contains($0) }
    }

    /// The owner dragged ordinary sessions into a new order (`workbench.order.set`).
    public func reorderSessions(_ ids: [String]) async throws {
        if let parent { return try await parent.reorderSessions(ids) }
        let before = sessionOrder
        sessionOrder = Self.reordered(sessionOrder ?? sidebarTree.sessionIDs, by: ids)
        do {
            let r: OrderSetResult = try await rpc.call(RPCMethod.workbenchOrderSet, params: OrderSetParams(kind: "sessions", ids: ids))
            sessionOrder = r.sessionOrder
        } catch {
            sessionOrder = before
            throw error
        }
    }

    /// The owner dragged workspaces into a new order.
    public func reorderWorkspaces(_ ids: [String]) async throws {
        if let parent { return try await parent.reorderWorkspaces(ids) }
        let before = workspaces
        let order = Self.reordered(workspaces.map(\.id), by: ids)
        setWorkspaces(order.compactMap { id in workspaces.first { $0.id == id } })
        do {
            let r: OrderSetResult = try await rpc.call(RPCMethod.workbenchOrderSet, params: OrderSetParams(kind: "workspaces", ids: ids))
            let byID = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            setWorkspaces(r.workspaceOrder.compactMap { byID[$0] } + workspaces.filter { !r.workspaceOrder.contains($0.id) })
        } catch {
            setWorkspaces(before)
            throw error
        }
    }

    /// The owner dragged a workspace's members into a new order.
    public func reorderMembers(workspaceId: String, _ ids: [String]) async throws {
        _ = try await updateWorkspace(id: workspaceId, memberIds: ids)
    }

    /// Its sessions become ordinary ones; none is ended.
    public func deleteWorkspace(id: String) async throws {
        if let parent { return try await parent.deleteWorkspace(id: id) }
        _ = try await rpc.call(RPCMethod.workspacesDelete, params: IDParams(id: id), as: OKResult.self)
        setWorkspaces(workspaces.filter { $0.id != id })
        try? await refreshPals()
    }
}

// MARK: - one session's details

extension AppStore {
    /// `pals.detail`: what the title capsule's details show; asked on opening
    /// and again when the session changes.
    public func palDetail(id: String) async throws -> PalDetail {
        if let parent { return try await parent.palDetail(id: id) }
        let d: PalDetail = try await rpc.call(RPCMethod.palsDetail, params: IDParams(id: id))
        if let p = d.pal { upsert(pal: p) }
        return d
    }

    /// `pals.setModel`: a model and/or thinking depth, for the next turn.
    @discardableResult
    public func setSessionModel(id: String, model: String? = nil, effort: String? = nil) async throws -> Pal? {
        if let parent { return try await parent.setSessionModel(id: id, model: model, effort: effort) }
        let r: PalWakeResult = try await rpc.call(RPCMethod.palsSetModel,
                                                  params: PalSetModelParams(id: id, model: model, effort: effort))
        if let p = r.pal { upsert(pal: p) }
        return r.pal
    }

    /// `pals.compact`: the session summarizes its own context.
    public func compactSession(id: String) async throws {
        if let parent { return try await parent.compactSession(id: id) }
        _ = try await rpc.call(RPCMethod.palsCompact, params: IDParams(id: id), as: EmptyResult.self, timeout: 30)
    }

    /// `pals.stopTask`: one background task or sub-agent.
    public func stopTask(id: String, taskId: String) async throws {
        if let parent { return try await parent.stopTask(id: id, taskId: taskId) }
        _ = try await rpc.call(RPCMethod.palsStopTask, params: PalStopTaskParams(id: id, taskId: taskId), as: EmptyResult.self)
    }

    /// `pals.reveal`: its folder in Finder, or a plain shell there, on the computer.
    public func revealSession(id: String, kind: String) async throws {
        if let parent { return try await parent.revealSession(id: id, kind: kind) }
        _ = try await rpc.call(RPCMethod.palsReveal, params: PalRevealParams(id: id, kind: kind), as: EmptyResult.self)
    }
}
