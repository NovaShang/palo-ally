import Foundation

/// The workbench in the demo (docs/workbench-rpc.md): starting and ending
/// sessions, marking them seen, 以前的 and resuming from it, folders,
/// workspaces, a session's details, and the browser pane's tabs.
extension DemoHost {
    /// The workbench's methods; nil for any other.
    func dispatchWorkbench(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case RPCMethod.palsCreate:
            let cwd = (p["cwd"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { throw DemoError(message: "找不到这个文件夹") }
            let name = (p["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 40 else { throw DemoError(message: "名字太长了（最多 40 个字）") }
            let text = (p["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let wsID = p["workspaceId"]?.stringValue
            if let wsID, !workspaces.contains(where: { $0.id == wsID }) { throw DemoError(message: "找不到这个工作区") }
            let id = "pal-\(nextID("p"))"
            let short = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
            let pal = Pal(id: id, name: name.isEmpty ? "session-\(short)" : name, cwd: cwd, sessionId: UUID().uuidString.lowercased(),
                          status: .idle, model: "claude-opus-5-5", createdBy: .owner, updatedAt: Date().epochMillis,
                          workspaceId: wsID)
            pals.insert(pal, at: 0)
            palLogs[id] = []
            if let wsID, let i = workspaces.firstIndex(where: { $0.id == wsID }) {
                workspaces[i].memberIds.append(id)
                workspaces[i].updatedAt = Date().epochMillis
                emitWorkspaces()
            }
            emitPals()
            if !text.isEmpty {
                var m = palMessage(id, role: .user, text: text, channel: .app)
                m.clientMsgId = nil
                appendPal(m)
                setPal(id) { $0.name = String(text.replacingOccurrences(of: "\n", with: " ").prefix(16)) }
                palTurns[id] = Task { await self.palAnswers(id, to: text) }
            }
            return ["pal": try .from(pals.first { $0.id == id })]
        case RPCMethod.palsFolders:
            var seen = Set<String>()
            var out: [SessionFolder] = []
            let all = pals.map { ($0.cwd, $0.updatedAt ?? 0) } + recentSessions.map { ($0.cwd, $0.lastModified) }
                + endedItems.map { ($0.cwd, $0.at) }
            for (cwd, at) in all.sorted(by: { $0.1 > $1.1 }) where seen.insert(cwd).inserted {
                out.append(SessionFolder(path: cwd, name: (cwd as NSString).lastPathComponent, lastUsedAt: at))
            }
            let limit = min(50, max(1, Int(p["limit"]?.doubleValue ?? 20)))
            return ["folders": try .from(Array(out.prefix(limit)))]
        case RPCMethod.palsSeen:
            let id = p["id"]?.stringValue ?? ""
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "找不到这个会话") }
            setPal(id) { $0.seenAt = max(Date().epochMillis, $0.finishedAt ?? 0) }
            return ["pal": try .from(pals.first { $0.id == id })]
        case RPCMethod.palsEnd:
            let id = p["id"]?.stringValue ?? ""
            guard let pal = pals.first(where: { $0.id == id }) else { throw DemoError(message: "找不到这个会话") }
            palTurns[id]?.cancel()
            palTurns[id] = nil
            pals.removeAll { $0.id == id }
            let item = EarlierItem(kind: .ended, key: "ended:\(pal.sessionId)", sessionId: pal.sessionId, name: pal.displayName,
                                   cwd: pal.cwd, at: Date().epochMillis, workspaceId: pal.workspaceId)
            endedItems.insert(item, at: 0)
            if let ws = pal.workspaceId { removeMember(id, from: ws) }
            emitPals()
            return ["earlier": try .from(item)]
        case RPCMethod.palsEarlier:
            var items: [EarlierItem] = []
            var sids = Set<String>()
            normalizePals()
            for pal in pals where pal.folded {
                sids.insert(pal.sessionId)
                items.append(EarlierItem(kind: .folded, key: "folded:\(pal.id)", palId: pal.id, sessionId: pal.sessionId,
                                         name: pal.displayName, cwd: pal.cwd, at: pal.updatedAt ?? 0))
            }
            for e in endedItems where sids.insert(e.sessionId).inserted && !pals.contains(where: { $0.sessionId == e.sessionId }) {
                items.append(e)
            }
            for r in recentSessions where sids.insert(r.sessionId).inserted && !pals.contains(where: { $0.sessionId == r.sessionId }) {
                items.append(EarlierItem(kind: .recent, key: "recent:\(r.sessionId)", sessionId: r.sessionId, name: r.displayTitle,
                                         cwd: r.cwd, at: r.lastModified))
            }
            if UserDefaults.standard.bool(forKey: "demoRecentEmpty") { items.removeAll { $0.kind == .recent } }
            if let folder = p["folder"]?.stringValue, !folder.isEmpty {
                items = items.filter { $0.cwd == folder || $0.cwd.hasSuffix("/" + folder) }
            }
            items.sort { $0.at > $1.at }
            let limit = min(200, max(1, Int(p["limit"]?.doubleValue ?? 50)))
            return ["items": try .from(Array(items.prefix(limit)))]
        case RPCMethod.palsResume:
            let key = p["key"]?.stringValue ?? "\(p["kind"]?.stringValue ?? ""):\(p["sessionId"]?.stringValue ?? "")"
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let (kind, rest) = (parts.first ?? "", parts.count > 1 ? parts[1] : "")
            switch kind {
            case "folded":
                guard pals.contains(where: { $0.id == rest }) else { throw DemoError(message: "这一项已经不在了") }
                await wakePal(rest)
                setPal(rest) { $0.updatedAt = Date().epochMillis }
                return ["pal": try .from(pals.first { $0.id == rest })]
            case "recent":
                await pause(1.0)
                if let why = UserDefaults.standard.string(forKey: "demoAdoptError"), !why.isEmpty { throw DemoError(message: why) }
                guard let pal = adoptRecent(rest) else { throw DemoError(message: "这一项已经不在了") }
                return ["pal": try .from(pal)]
            case "ended":
                await pause(1.0)
                guard let i = endedItems.firstIndex(where: { $0.sessionId == rest }) else { throw DemoError(message: "这一项已经不在了") }
                let e = endedItems.remove(at: i)
                let id = "pal-\(nextID("p"))"
                let ws = e.workspaceId.flatMap { w in workspaces.contains { $0.id == w } ? w : nil }
                pals.insert(Pal(id: id, name: e.name, cwd: e.cwd, sessionId: e.sessionId, status: .idle, model: "claude-opus-5-5",
                                createdBy: .owner, updatedAt: Date().epochMillis, workspaceId: ws), at: 0)
                palLogs[id] = []
                if let ws, let j = workspaces.firstIndex(where: { $0.id == ws }) {
                    workspaces[j].memberIds.append(id)
                    workspaces[j].updatedAt = Date().epochMillis
                    emitWorkspaces()
                }
                emitPals()
                return ["pal": try .from(pals.first { $0.id == id })]
            default:
                throw DemoError(message: "这一项已经不在了")
            }
        case RPCMethod.palsDetail:
            let id = p["id"]?.stringValue ?? ""
            guard let pal = pals.first(where: { $0.id == id }) else { throw DemoError(message: "找不到这个会话") }
            return ["pal": try .from(pal), "contextTokens": 84_000, "contextWindow": 200_000, "costTotalUsd": 3.82,
                    "spentToday": 1.2, "model": .string(pal.model ?? "claude-opus-5-5"), "effort": .string(pal.effort ?? "high"),
                    "models": [["id": "claude-opus-5-5", "name": "Opus 5.5", "efforts": ["low", "medium", "high"]],
                               ["id": "claude-sonnet-4-5", "name": "Sonnet 4.5", "efforts": []]],
                    "tasks": .array([])]
        case RPCMethod.palsSetModel:
            let id = p["id"]?.stringValue ?? ""
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "找不到这个会话") }
            let model = p["model"]?.stringValue, effort = p["effort"]?.stringValue
            guard model != nil || effort != nil else { throw DemoError(message: "要改的内容不能是空的") }
            setPal(id) { if let model { $0.model = model }; if let effort { $0.effort = effort } }
            return ["pal": try .from(pals.first { $0.id == id })]
        case RPCMethod.palsCompact, RPCMethod.palsStopTask, RPCMethod.palsReveal:
            let id = p["id"]?.stringValue ?? ""
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "找不到这个会话") }
            if method == RPCMethod.palsStopTask { throw DemoError(message: "这个任务已经结束了") }
            return [:]

        case RPCMethod.workspacesList:
            return ["workspaces": try .from(workspaces)]
        case RPCMethod.workspacesCreate:
            let ids = (p["memberIds"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !ids.isEmpty else { throw DemoError(message: "至少要有一个会话") }
            guard ids.allSatisfy({ id in pals.contains { $0.id == id } }) else { throw DemoError(message: "找不到这个会话") }
            let name = (p["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 40 else { throw DemoError(message: "名字太长了（最多 40 个字）") }
            for id in ids { if let old = pals.first(where: { $0.id == id })?.workspaceId { removeMember(id, from: old) } }
            let now = Date().epochMillis
            let w = Workspace(id: "ws-\(nextID("w"))", name: name, memberIds: ids, layout: nil, createdAt: now, updatedAt: now)
            workspaces.append(w)
            for id in ids { setPalQuiet(id) { $0.workspaceId = w.id } }
            emitWorkspaces()
            emitPals()
            return ["workspace": try .from(w)]
        case RPCMethod.workspacesUpdate:
            let id = p["id"]?.stringValue ?? ""
            guard let i = workspaces.firstIndex(where: { $0.id == id }) else { throw DemoError(message: "找不到这个工作区") }
            if let name = p["name"]?.stringValue {
                guard name.count <= 40 else { throw DemoError(message: "名字太长了（最多 40 个字）") }
                workspaces[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let layout = p["layout"] { workspaces[i].layout = layout == .null ? nil : layout }
            workspaces[i].updatedAt = max(Date().epochMillis, workspaces[i].updatedAt + 1)
            emitWorkspaces()
            return ["workspace": try .from(workspaces[i])]
        case RPCMethod.workspacesMove:
            let palID = p["palId"]?.stringValue ?? ""
            guard let pal = pals.first(where: { $0.id == palID }) else { throw DemoError(message: "找不到这个会话") }
            let target = p["workspaceId"]?.stringValue
            if let target, !workspaces.contains(where: { $0.id == target }) { throw DemoError(message: "找不到这个工作区") }
            var changed: [String] = []
            if let old = pal.workspaceId, old != target { removeMember(palID, from: old); changed.append(old) }
            if let target, pal.workspaceId != target, let i = workspaces.firstIndex(where: { $0.id == target }) {
                workspaces[i].memberIds.append(palID)
                workspaces[i].updatedAt = Date().epochMillis
                changed.append(target)
            }
            setPalQuiet(palID) { $0.workspaceId = target }
            emitWorkspaces()
            emitPals()
            return ["workspaces": try .from(workspaces.filter { changed.contains($0.id) })]
        case RPCMethod.workspacesDelete:
            let id = p["id"]?.stringValue ?? ""
            guard workspaces.contains(where: { $0.id == id }) else { throw DemoError(message: "找不到这个工作区") }
            workspaces.removeAll { $0.id == id }
            for pal in pals where pal.workspaceId == id { setPalQuiet(pal.id) { $0.workspaceId = nil } }
            emitWorkspaces()
            emitPals()
            return ["ok": true]
        case RPCMethod.workbenchTabsGet:
            if let key = p["key"]?.stringValue {
                return ["states": paneTabs[key].map { [key: (try? JSONValue.from($0)) ?? .null] as JSONValue } ?? [:]]
            }
            return ["states": try .from(paneTabs)]
        case RPCMethod.workbenchTabsSet:
            guard let key = p["key"]?.stringValue, !key.isEmpty else { throw DemoError(message: "标签的位置不对") }
            let tabs = try (p["tabs"] ?? .array([])).decode([PaneTab].self)
            let state = TabsState(tabs: tabs, active: Int(p["active"]?.doubleValue ?? 0), open: p["open"]?.boolValue ?? false,
                                  updatedAt: Date().epochMillis)
            paneTabs[key] = state
            emit(RPCEventName.workbenchUpdated, ["key": .string(key), "state": try .from(state)] as JSONValue)
            return ["state": try .from(state)]
        default:
            return nil
        }
    }

    /// Off a workspace's list. An empty workspace stays: only `workspaces.delete`
    /// removes one.
    func removeMember(_ palID: String, from wsID: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == wsID }) else { return }
        workspaces[i].memberIds.removeAll { $0 == palID }
        workspaces[i].updatedAt = Date().epochMillis
        emitWorkspaces()
    }

    /// A change to a session without announcing the list (the caller does).
    func setPalQuiet(_ id: String, _ change: (inout Pal) -> Void) {
        guard let i = pals.firstIndex(where: { $0.id == id }) else { return }
        change(&pals[i])
    }
}
