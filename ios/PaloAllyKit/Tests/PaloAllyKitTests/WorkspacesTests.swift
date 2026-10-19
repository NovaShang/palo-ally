import Foundation
import Testing
@testable import PaloAllyKit

/// The workbench (docs/workbench-rpc.md): the wire shapes (samples from the
/// contract), the status dot, the sidebar's sections, and the store as
/// sessions, workspaces and 以前的 change.
@Suite("Workbench decoding")
struct WorkbenchDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> (T, [String]) {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LenientDiagnostics.collect { try v.decode(T.self) }
    }

    @Test func aSessionWithTheNewFields() throws {
        let (p, issues) = try decode(Pal.self, """
        {"id":"pal_3f9a1c0b2d4e","name":"session-3f9a1c","cwd":"/Users/demo/code/site","sessionId":"7b0c1e5a","status":"idle","lastLine":"登录页做完了","pending":0,"model":"claude-opus-4-5","createdBy":"owner","updatedAt":1792310400000,"attention":"done","finishedAt":1792310400000,"contextPct":42,"workspaceId":"ws_a1b2c3d4e5f6","effort":"high","folded":false}
        """)
        #expect(issues.isEmpty)
        #expect(p.attention == .done && p.dot == .done && p.finishedAt == 1792310400000 && p.seenAt == nil)
        #expect(p.contextPct == 42 && p.workspaceId == "ws_a1b2c3d4e5f6" && p.effort == "high" && !p.folded)
        // The host's placeholder name reads as 新会话.
        #expect(Pal.isUnnamed(p.name) && p.displayName != p.name)
    }

    @Test func aHostFromBeforeTheWorkbenchIsReadFromItsStatus() throws {
        func pal(_ extra: String) throws -> Pal {
            let (p, issues) = try decode(Pal.self, #"{"id":"a","name":"x","cwd":"/","sessionId":"s","createdBy":"owner",\#(extra)}"#)
            // An unknown attention word is reported; nothing else may be.
            #expect(issues.isEmpty || extra.contains("brooding"))
            return p
        }
        #expect(try pal(#""status":"busy","pending":0"#).attention == .working)
        #expect(try pal(#""status":"waiting","pending":1"#).attention == .waiting)
        // A card waiting wins over a turn running.
        #expect(try pal(#""status":"busy","pending":2"#).attention == .waiting)
        for s in ["asleep", "starting", "stopped", "idle"] {
            let p = try pal(#""status":"\#(s)","pending":0"#)
            #expect(p.attention == .idle && p.dot == .idle)
        }
        // Finished, not looked at; then looked at.
        #expect(try pal(#""status":"idle","pending":0,"finishedAt":10,"seenAt":5"#).attention == .done)
        #expect(try pal(#""status":"idle","pending":0,"finishedAt":10,"seenAt":10"#).attention == .idle)
        // The host's word wins; an unknown one falls back to the status.
        #expect(try pal(#""status":"idle","pending":0,"attention":"waiting""#).attention == .waiting)
        #expect(try pal(#""status":"busy","pending":0,"attention":"brooding""#).attention == .working)
    }

    @Test func workspacesAndTheirEvent() throws {
        let (r, issues) = try decode(WorkspacesResult.self, """
        {"workspaces":[{"id":"ws_a1b2c3d4e5f6","name":"官网","memberIds":["pal_3f9a1c0b2d4e","pal_55e0c4a1b2d3"],"layout":null,"createdAt":1792300000000,"updatedAt":1792310000000}]}
        """)
        #expect(issues.isEmpty && r.workspaces.count == 1)
        let w = try #require(r.workspaces.first)
        #expect(w.layout == nil && w.memberIds.count == 2 && w.title(pals: []) == "官网")
        // A layout is kept as the host sent it.
        let (laid, lIssues) = try decode(Workspace.self, """
        {"id":"ws_1","name":"","memberIds":["a","b"],"layout":{"type":"hsplit","w":1,"h":1,"x":0,"y":0,"children":[{"type":"leaf","session":"a","w":0.5,"h":1,"x":0,"y":0},{"type":"leaf","session":"b","w":0.5,"h":1,"x":0.5,"y":0}]},"createdAt":1,"updatedAt":2}
        """)
        #expect(lIssues.isEmpty && laid.layout?["type"]?.stringValue == "hsplit")
        // No name: the members' names stand in.
        let pals = [Pal(id: "a", name: "网站", cwd: "/", sessionId: "s1", status: .idle), Pal(id: "b", name: "博客", cwd: "/", sessionId: "s2", status: .idle)]
        #expect(laid.title(pals: pals) == "网站 · 博客")
        let (one, oIssues) = try decode(WorkspaceResult.self, #"{"workspace":{"id":"w","name":"","memberIds":[],"layout":null,"createdAt":1,"updatedAt":1}}"#)
        #expect(oIssues.isEmpty && one.workspace?.id == "w")
    }

    @Test func earlierSessionsFoldersAndDetails() throws {
        let (e, issues) = try decode(EarlierResult.self, """
        {"items":[{"kind":"folded","key":"folded:pal_77aa00bb11cc","id":"pal_77aa00bb11cc","sessionId":"0d8e","name":"周报","cwd":"/Users/demo/docs","at":1792000000000},{"kind":"recent","key":"recent:5a1f","sessionId":"5a1f","name":"修复构建","cwd":"/Users/demo/code/app","at":1791900000000}]}
        """)
        #expect(issues.isEmpty && e.items.map(\.kind) == [.folded, .recent] && e.items[0].palId == "pal_77aa00bb11cc")
        let (ended, eIssues) = try decode(PalEndResult.self, """
        {"earlier":{"kind":"ended","key":"ended:7b0c","sessionId":"7b0c","name":"登录页","cwd":"/Users/demo/code/site","at":1792310500000,"workspaceId":"ws_a1b2c3d4e5f6"}}
        """)
        #expect(eIssues.isEmpty && ended.earlier?.kind == .ended && ended.earlier?.workspaceId == "ws_a1b2c3d4e5f6")
        let (f, fIssues) = try decode(FoldersResult.self, #"{"folders":[{"path":"/Users/demo/code/site","name":"site","lastUsedAt":1792310400000}]}"#)
        #expect(fIssues.isEmpty && f.folders.first?.name == "site")
        let (d, dIssues) = try decode(PalDetail.self, """
        {"pal":{"id":"pal_3f9a1c0b2d4e","name":"登录页","cwd":"/Users/demo/code/site","sessionId":"7b0c","status":"busy","activity":"在改 Login.tsx","pending":0,"createdBy":"owner","updatedAt":1,"attention":"working","contextPct":42,"effort":"high","folded":false},"contextTokens":84000,"contextWindow":200000,"costTotalUsd":3.82,"spentToday":1.2,"model":"claude-opus-4-5","effort":"high","models":[{"id":"claude-opus-4-5","name":"Opus 4.5","efforts":["low","medium","high"]}],"tasks":[{"id":"t_9c1","title":"跑全部测试","kind":"bg","startedAt":1792310300000}],"lastCompactAt":1792300000000}
        """)
        #expect(dIssues.isEmpty && d.tasks.first?.kind == .bg && d.models.first?.efforts.count == 3 && d.costTotalUsd == 3.82)
        let (t, tIssues) = try decode(TabsSetResult.self, #"{"state":{"tabs":[{"kind":"library"},{"kind":"web","url":"https://example.com"}],"active":1,"open":true,"updatedAt":1792310400000}}"#)
        #expect(tIssues.isEmpty && t.state?.tabs.count == 2 && t.state?.open == true)
    }

    @Test func theDotHasFourStates() {
        #expect(StatusDotKind(PalAttention.working) == .working && StatusDotKind(PalAttention.waiting) == .waiting)
        #expect(StatusDotKind(PalAttention.done) == .done && StatusDotKind(PalAttention.idle) == .idle && StatusDotKind(PalAttention.unknown) == .idle)
        #expect(StatusDotKind(CCSessionStatus.busy) == .working && StatusDotKind(CCSessionStatus.waiting) == .waiting)
        #expect(StatusDotKind(CCSessionStatus.stopped) == .idle)
    }

    @Test func requestsOmitWhatIsNotGiven() throws {
        func json<T: Encodable>(_ v: T) throws -> JSONValue { try JSONValue.from(v) }
        #expect(try json(WorkspaceMoveParams(palId: "p")) == ["palId": "p"])
        #expect(try json(WorkspaceMoveParams(palId: "p", workspaceId: "w")) == ["palId": "p", "workspaceId": "w"])
        #expect(try json(PalCreateParams(cwd: "/a")) == ["cwd": "/a"])
        #expect(try json(WorkspaceUpdateParams(id: "w", name: "n")) == ["id": "w", "name": "n"])
        // null clears the tiling.
        #expect(try json(WorkspaceUpdateParams(id: "w", layout: .null)) == ["id": "w", "layout": .null])
    }
}

@Suite("Sidebar tree")
struct SidebarTreeTests {
    private func pal(_ id: String, at: Int64, _ a: PalAttention = .idle, ws: String? = nil, folded: Bool = false) -> Pal {
        Pal(id: id, name: id, cwd: "/\(id)", sessionId: "s-\(id)", status: .idle, updatedAt: at,
            attention: a, workspaceId: ws, folded: folded)
    }

    @Test func ordinarySessionsByLatestActivityWithoutFoldedOrWorkspaced() {
        let pals = [pal("a", at: 10), pal("b", at: 30), pal("c", at: 20, folded: true), pal("d", at: 40, ws: "w1"), pal("e", at: 30)]
        let w = Workspace(id: "w1", name: "W", memberIds: ["d"], createdAt: 1, updatedAt: 1)
        let t = SidebarTree.build(pals: pals, workspaces: [w])
        // b and e tie on activity: the host's order holds.
        #expect(t.sessions.map(\.id) == ["b", "e", "a"])
        #expect(t.foldedCount == 1 && t.workspaces.map(\.id) == ["w1"] && t.workspaces[0].members.map(\.id) == ["d"])
    }

    @Test func workspacesKeepTheirMembersOrderAndCountWhoWaits() {
        let pals = [pal("a", at: 1, .waiting, ws: "w1"), pal("b", at: 2, .done, ws: "w1"), pal("c", at: 3, .waiting), pal("x", at: 4, .waiting, ws: "w2")]
        let ws = [Workspace(id: "w2", name: "", memberIds: ["x"], createdAt: 20, updatedAt: 99),
                  Workspace(id: "w1", name: "官网", memberIds: ["b", "a"], createdAt: 10, updatedAt: 5)]
        let t = SidebarTree.build(pals: pals, workspaces: ws)
        // Oldest workspace first, however recently the other changed.
        #expect(t.workspaces.map(\.id) == ["w1", "w2"])
        #expect(t.workspaces[0].members.map(\.id) == ["b", "a"] && t.workspaces[0].waiting == 1)
        #expect(t.workspaces[0].title == "官网" && t.workspaces[1].title == "x")
        #expect(t.sessions.map(\.id) == ["c"] && t.waitingCount == 3)
    }

    @Test func aSessionOnlyTheSessionKnowsItsWorkspaceStillShowsThere() {
        let pals = [pal("a", at: 1, ws: "w1"), pal("gone", at: 2, ws: "w1")]
        let w = Workspace(id: "w1", name: "W", memberIds: ["a", "missing"], createdAt: 1, updatedAt: 1)
        let t = SidebarTree.build(pals: pals, workspaces: [w])
        #expect(t.workspaces[0].members.map(\.id) == ["a", "gone"] && t.sessions.isEmpty)
    }

    @Test func anEmptyWorkspaceIsStillListed() {
        let t = SidebarTree.build(pals: [], workspaces: [Workspace(id: "w", name: "空的", createdAt: 1, updatedAt: 1)])
        #expect(t.workspaces.count == 1 && t.workspaces[0].members.isEmpty && t.workspaces[0].waiting == 0)
    }

    @Test func earlierCountUsesTheLoadedListElseTheFolded() {
        let t = SidebarTree(foldedCount: 2)
        #expect(t.earlierCount(loaded: nil) == 2)
        let item = EarlierItem(kind: .recent, key: "recent:s", sessionId: "s", name: "x", cwd: "/", at: 1)
        #expect(t.earlierCount(loaded: [item, item, item]) == 3 && t.earlierCount(loaded: []) == 0)
    }

    @Test func earlierGroupsByFolderNewestFirstAndSearches() {
        func item(_ k: String, _ cwd: String, _ at: Int64, _ name: String = "x") -> EarlierItem {
            EarlierItem(kind: .recent, key: "recent:\(k)", sessionId: k, name: name, cwd: cwd, at: at)
        }
        let groups = EarlierGroup.group([item("1", "/a/site", 10), item("2", "/a/docs", 30), item("3", "/a/site", 20, "登录")])
        #expect(groups.map(\.cwd) == ["/a/docs", "/a/site"] && groups[1].items.map(\.sessionId) == ["3", "1"])
        #expect(EarlierGroup.group([item("1", "/a/site", 10), item("3", "/a/site", 20, "登录")], matching: "登").flatMap(\.items).map(\.sessionId) == ["3"])
    }
}

@MainActor
@Suite("Workbench store", .serialized)
struct WorkbenchStoreTests {
    func demoStore() async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.pals.count == 4 && !store.workspaces.isEmpty && store.workspacesSupported == true }
        return (store, host)
    }

    @Test func theTreeComesFromTheHost() async throws {
        let (store, _) = await demoStore()
        #expect(store.workspacesSupported == true)
        let tree = store.sidebarTree
        #expect(tree.workspaces.map(\.title) == ["官网改版"] && tree.workspaces[0].members.map(\.id) == ["pal-site", "pal-blog"])
        #expect(tree.workspaces[0].waiting == 1 && tree.waitingCount == 1)
        // 笔记整理 finished something unseen; 照片整理 has been left alone for days.
        #expect(tree.sessions.map(\.id) == ["pal-notes"] && store.pal(id: "pal-notes")?.attention == .done)
        #expect(tree.foldedCount == 1 && store.pal(id: "pal-photos")?.folded == true)
    }

    @Test func openingAFinishedSessionMarksItSeenAtOnceAndTellsTheHost() async throws {
        let (store, host) = await demoStore()
        store.markSeen(id: "pal-notes")
        // At once, before the host has answered.
        #expect(store.pal(id: "pal-notes")?.attention == .idle && store.pal(id: "pal-notes")?.seenAt != nil)
        #expect(await until { await host.lastParams["pals.seen"] == ["id": "pal-notes"] })
        // One that has nothing new is left alone, and the host isn't asked.
        store.markSeen(id: "pal-site")
        #expect(store.pal(id: "pal-site")?.attention == .waiting)
    }

    @Test func aSessionStartsInAFolderAndGetsNamedByItsFirstWords() async throws {
        let (store, host) = await demoStore()
        let p = try await store.createSession(cwd: "/Users/demo/code/new")
        #expect(Pal.isUnnamed(p.name) && store.pal(id: p.id) != nil && p.workspaceId == nil)
        #expect(await host.lastParams["pals.create"] == ["cwd": "/Users/demo/code/new"])
        let into = try await store.createSession(cwd: "/Users/demo/code/site", text: "把登录页做完", workspaceId: "ws-site")
        #expect(into.workspaceId == "ws-site")
        #expect(await until { store.workspace(id: "ws-site")?.memberIds.contains(into.id) == true })
        #expect(await until { store.pal(id: into.id)?.name == "把登录页做完" })
        let folders = try await store.sessionFolders()
        #expect(folders.first?.path != nil && Set(folders.map(\.path)).count == folders.count)
    }

    @Test func endingASessionMovesItToEarlierAndResumingBringsItBack() async throws {
        let (store, _) = await demoStore()
        try await store.refreshEarlier()
        // 照片整理 (folded) and the seven conversations on the computer.
        #expect(store.earlierItems?.count == 8 && store.earlierItems?.first?.kind != nil)
        let ended = try #require(try await store.endSession(id: "pal-notes"))
        #expect(ended.kind == .ended && store.pal(id: "pal-notes") == nil)
        #expect(store.earlierItems?.first?.key == ended.key && store.earlierItems?.count == 9)
        let back = try await store.resume(ended)
        #expect(back.name == "笔记整理" && store.pal(id: back.id) != nil && store.earlierItems?.count == 8)
        // A folded one wakes where it is; a conversation from the terminal becomes a session.
        let folded = try #require(store.earlierItems?.first { $0.kind == .folded })
        let woke = try await store.resume(folded)
        #expect(woke.id == "pal-photos" && store.pal(id: "pal-photos")?.folded == false)
        let recent = try #require(store.earlierItems?.first { $0.kind == .recent })
        let adopted = try await store.resume(recent)
        #expect(adopted.sessionId == recent.sessionId && store.earlierItems?.contains { $0.key == recent.key } == false)
    }

    @Test func workspacesAreMadeMovedRenamedAndDeleted() async throws {
        let (store, host) = await demoStore()
        let w = try await store.createWorkspace(name: "笔记", memberIds: ["pal-notes"])
        #expect(store.workspace(id: w.id)?.memberIds == ["pal-notes"] && store.pal(id: "pal-notes")?.workspaceId == w.id)
        try await store.moveSession("pal-notes", to: "ws-site")
        #expect(store.workspace(id: "ws-site")?.memberIds == ["pal-site", "pal-blog", "pal-notes"])
        // The one it left stays, empty: only deleting removes a workspace.
        #expect(store.workspace(id: w.id)?.memberIds.isEmpty == true)
        try await store.moveSession("pal-notes", to: nil)
        #expect(store.pal(id: "pal-notes")?.workspaceId == nil)
        _ = try await store.updateWorkspace(id: w.id, name: "新名字")
        #expect(store.workspace(id: w.id)?.name == "新名字")
        #expect(await host.lastParams["workspaces.update"] == ["id": .string(w.id), "name": "新名字"])
        try await store.deleteWorkspace(id: "ws-site")
        #expect(store.workspace(id: "ws-site") == nil && store.pal(id: "pal-site")?.workspaceId == nil)
        #expect(store.pals.count == 4)
    }

    @Test func aWorkspaceUpdateThatDoesNotWorkIsPutBack() async throws {
        let (store, _) = await demoStore()
        let long = String(repeating: "长", count: 41)
        await #expect(throws: (any Error).self) { _ = try await store.updateWorkspace(id: "ws-site", name: long) }
        #expect(store.workspace(id: "ws-site")?.name == "官网改版")
    }

    @Test func theEventReplacesTheTableButKeepsAFresherLocalWrite() async throws {
        let (store, _) = await demoStore()
        var mine = try #require(store.workspace(id: "ws-site"))
        mine.name = "本地"
        mine.updatedAt += 1000
        store.setWorkspaces([mine])
        var echo = mine
        echo.name = "旧回声"
        echo.updatedAt = mine.updatedAt - 500
        store.apply(workspacesUpdate: ["workspaces": try .from([echo])])
        #expect(store.workspace(id: "ws-site")?.name == "本地")
        echo.updatedAt = mine.updatedAt + 500
        store.apply(workspacesUpdate: ["workspaces": try .from([echo])])
        #expect(store.workspace(id: "ws-site")?.name == "旧回声")
        // A workspace gone from the table is gone here.
        store.apply(workspacesUpdate: ["workspaces": .array([])])
        #expect(store.workspaces.isEmpty)
    }
}
