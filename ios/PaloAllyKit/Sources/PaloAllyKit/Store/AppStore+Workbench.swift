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

    /// The sidebar's sections.
    public var sidebarTree: SidebarTree { SidebarTree.build(pals: pals, workspaces: workspaces) }

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
        setWorkspaces(workspaces.filter { $0.id != w.id } + [w])
        // Members moved in: their lists change with it.
        try? await refreshPals()
        try? await refreshWorkspaces()
        return w
    }

    /// Name and tiling; shown at once, put back when the host says no.
    @discardableResult
    public func updateWorkspace(id: String, name: String? = nil, layout: JSONValue? = nil) async throws -> Workspace {
        if let parent { return try await parent.updateWorkspace(id: id, name: name, layout: layout) }
        let before = workspaces
        if let i = workspaces.firstIndex(where: { $0.id == id }) {
            var list = workspaces
            if let name { list[i].name = name }
            if let layout { list[i].layout = layout == .null ? nil : layout }
            list[i].updatedAt = max(list[i].updatedAt, Date().epochMillis)
            setWorkspaces(list)
        }
        do {
            let r: WorkspaceResult = try await rpc.call(RPCMethod.workspacesUpdate,
                                                        params: WorkspaceUpdateParams(id: id, name: name, layout: layout))
            guard let w = r.workspace else { throw RPCError.badResponse }
            setWorkspaces(workspaces.map { $0.id == w.id ? w : $0 })
            return w
        } catch {
            setWorkspaces(before)
            throw error
        }
    }

    /// Into a workspace, out of one (`workspaceId` nil), or to another.
    public func moveSession(_ palId: String, to workspaceId: String?) async throws {
        if let parent { return try await parent.moveSession(palId, to: workspaceId) }
        let r: WorkspacesResult = try await rpc.call(RPCMethod.workspacesMove,
                                                     params: WorkspaceMoveParams(palId: palId, workspaceId: workspaceId))
        var list = workspaces
        for w in r.workspaces {
            if let i = list.firstIndex(where: { $0.id == w.id }) { list[i] = w } else { list.append(w) }
        }
        setWorkspaces(list)
        // A workspace left empty by the move is gone at the host.
        try? await refreshPals()
        try? await refreshWorkspaces()
    }

    /// Its sessions become ordinary ones; none is ended.
    public func deleteWorkspace(id: String) async throws {
        if let parent { return try await parent.deleteWorkspace(id: id) }
        _ = try await rpc.call(RPCMethod.workspacesDelete, params: IDParams(id: id), as: OKResult.self)
        setWorkspaces(workspaces.filter { $0.id != id })
        try? await refreshPals()
    }
}
