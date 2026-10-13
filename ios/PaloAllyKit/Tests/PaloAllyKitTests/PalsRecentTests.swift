import Foundation
import Testing
@testable import PaloAllyKit

/// Recent conversations (pals-prd §10): `pals.recent`, the list by folder,
/// adopting one, and the assistant's `pal_adopt` card.
@Suite("Recent conversations decoding")
struct RecentDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> (T, [String]) {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LenientDiagnostics.collect { try v.decode(T.self) }
    }

    @Test func recentSessionAsInThePRD() throws {
        let (r, issues) = try decode(PalsRecentResult.self, """
        {"sessions":[{"sessionId":"s1","cwd":"/Users/someone/code/site","title":"首页改成两栏","lastModified":1791827337843,"size":4096}]}
        """)
        #expect(issues.isEmpty)
        let s = try #require(r.sessions.first)
        #expect(s.id == "s1" && s.title == "首页改成两栏" && s.lastModified == 1_791_827_337_843 && s.size == 4096)
        // Every field is the host's to give.
        let (_, missing) = try decode(RecentSession.self, #"{"sessionId":"s2"}"#)
        for key in ["cwd", "title", "lastModified", "size"] {
            #expect(missing.contains { $0.contains(key) }, "\(key) not reported")
        }
        // A time as an ISO string still reads.
        let (iso, isoIssues) = try decode(RecentSession.self,
                                          #"{"sessionId":"s3","cwd":"/a","title":"t","lastModified":"2026-10-12T08:00:00Z","size":1}"#)
        #expect(isoIssues.isEmpty && iso.lastModified == 1_791_792_000_000)
        // No title: its folder's name.
        let (bare, _) = try decode(RecentSession.self, #"{"sessionId":"s4","cwd":"/Users/someone/notes","title":" ","lastModified":1,"size":1}"#)
        #expect(bare.displayTitle == "notes")
    }

    @Test func aPalAdoptCardReadsAsOne() throws {
        let (m, issues) = try decode(ChatMessage.self, """
        {"seq":20,"id":"m20","role":"assistant","kind":"pal_adopt","text":"接管「首页改成两栏」（~/code/site）？","channel":"system","ts":1,
         "proposal":{"id":"pa1","sessionId":"s1","cwd":"/Users/someone/code/site","title":"首页改成两栏","status":"pending"}}
        """)
        #expect(issues.isEmpty, "\(issues)")
        #expect(m.kind == .palAdopt && m.proposal == nil)
        let a = try #require(m.adoption)
        #expect(a.id == "pa1" && a.sessionId == "s1" && a.isPending && a.shortCwd == "~/code/site" && a.palId == nil)

        let (done, doneIssues) = try decode(ChatMessage.self, """
        {"seq":20,"id":"m20","role":"assistant","kind":"pal_adopt","text":"","channel":"system","ts":1,
         "proposal":{"id":"pa1","sessionId":"s1","cwd":"/a","title":"t","status":"adopted","palId":"pal_1"}}
        """)
        #expect(doneIssues.isEmpty && done.adoption?.status == .adopted && done.adoption?.palId == "pal_1")
        let (failed, _) = try decode(ChatMessage.self, """
        {"seq":20,"id":"m20","role":"assistant","kind":"pal_adopt","text":"","channel":"system","ts":1,
         "proposal":{"id":"pa1","sessionId":"s1","cwd":"/a","title":"t","status":"failed","note":"已经开着 5 个 Pal 了"}}
        """)
        #expect(failed.adoption?.status == .failed && failed.adoption?.note == "已经开着 5 个 Pal 了")

        // Without its proposal, or with a status this client doesn't know, strict mode says so.
        let (_, noProposal) = try decode(ChatMessage.self,
                                         #"{"seq":1,"id":"m1","role":"assistant","kind":"pal_adopt","text":"","channel":"system","ts":1}"#)
        #expect(noProposal.contains { $0.contains("proposal") })
        let (odd, oddIssues) = try decode(ChatMessage.self, """
        {"seq":1,"id":"m1","role":"assistant","kind":"pal_adopt","text":"","channel":"system","ts":1,
         "proposal":{"id":"pa1","sessionId":"s1","cwd":"/a","title":"t","status":"withdrawn"}}
        """)
        #expect(odd.adoption?.status == .unknown && oddIssues.count == 1)
        // A helper's card is still a helper's.
        let (helper, helperIssues) = try decode(ChatMessage.self, """
        {"seq":1,"id":"m1","role":"assistant","kind":"helper","text":"","channel":"system","ts":1,
         "proposal":{"id":"hp1","name":"文档","cwd":"/a","duty":"写文档","status":"pending"}}
        """)
        #expect(helperIssues.isEmpty && helper.proposal?.name == "文档" && helper.adoption == nil)
    }

    @Test func aCardGoesOutAsTheHostSendsIt() throws {
        var m = ChatMessage(seq: 3, id: "m3", role: .assistant, kind: .palAdopt, text: "接管？", channel: .system, ts: 5)
        m.adoption = PalAdoptProposal(id: "pa1", sessionId: "s1", cwd: "/a", title: "t", status: .adopted, palId: "p1")
        let json = try JSONValue.from(m)
        #expect(json["kind"]?.stringValue == "pal_adopt")
        #expect(json["proposal"]?["sessionId"]?.stringValue == "s1" && json["adoption"] == nil)
        let (back, issues) = try LenientDiagnostics.collect { try json.decode(ChatMessage.self) }
        #expect(issues.isEmpty && back == m)
        // Other messages encode as before.
        var h = ChatMessage(seq: 4, id: "m4", role: .assistant, kind: .helper, text: "开吧？", ts: 6)
        h.proposal = HelperProposal(id: "hp1", name: "帮手", cwd: "/", duty: "做事")
        #expect(try JSONValue.from(h).decode(ChatMessage.self) == h)
    }

    @Test func groupedByFolderNewestFirst() {
        let list = [
            RecentSession(sessionId: "a1", cwd: "/Users/someone/code/site", title: "首页", lastModified: 30),
            RecentSession(sessionId: "b1", cwd: "/Users/someone/code/recipes", title: "收藏页", lastModified: 50),
            RecentSession(sessionId: "a2", cwd: "/Users/someone/code/site", title: "菜单", lastModified: 40),
            RecentSession(sessionId: "c1", cwd: "/Users/someone/Documents/旅行", title: "Tokyo 行程", lastModified: 10),
        ]
        let folders = RecentFolder.group(list)
        #expect(folders.map(\.name) == ["recipes", "site", "旅行"])
        #expect(folders[1].sessions.map(\.sessionId) == ["a2", "a1"])
        #expect(folders[1].path == "~/code/site")
        // Searching: words in a title (any case), or the folder.
        #expect(RecentFolder.group(list, matching: "tokyo").flatMap(\.sessions).map(\.sessionId) == ["c1"])
        #expect(RecentFolder.group(list, matching: " site ").flatMap(\.sessions).map(\.sessionId) == ["a2", "a1"])
        #expect(RecentFolder.group(list, matching: "没有的").isEmpty)
    }
}

@MainActor
@Suite("Recent conversations store", .serialized)
struct RecentStoreTests {
    func demoStore() async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.pals.count == 2 }
        return (store, host)
    }

    @Test func theListComesByFolder() async throws {
        let (store, host) = await demoStore()
        #expect(store.recentSessions == nil)
        try await store.refreshRecent()
        #expect(store.recentSupported == true)
        #expect(store.recentSessions?.count == 7)
        let folders = store.recentFolders()
        #expect(folders.map(\.name) == ["recipes", "旅行", "site"])
        #expect(folders.allSatisfy { f in zip(f.sessions, f.sessions.dropFirst()).allSatisfy { $0.lastModified >= $1.lastModified } })
        #expect(store.recentFolders(matching: "酒店").flatMap(\.sessions).map(\.title) == ["比较三家酒店的退改规则"])
        #expect(await host.lastParams["pals.recent"] == [:])
    }

    @Test func adoptingOneOpensItAsAPal() async throws {
        let (store, _) = await demoStore()
        try await store.refreshRecent()
        let recent = try #require(store.recentSessions?.first { $0.title == "收藏页加上按标签筛选" })
        guard case .adopted(let pal) = try await store.adopt(sessionId: recent.sessionId) else {
            Issue.record("not adopted at once"); return
        }
        #expect(pal.sessionId == recent.sessionId && pal.cwd == recent.cwd && pal.displayName == recent.title)
        #expect(store.pal(id: pal.id) != nil && store.adoptions[recent.sessionId] == nil)
        // It's left the recent ones, here and at the computer.
        #expect(store.recentSessions?.contains { $0.sessionId == recent.sessionId } == false)
        try await store.refreshRecent()
        #expect(store.recentSessions?.count == 6)
        // Its conversation so far comes with it.
        let page = store.palStore(pal.id)
        #expect(await until { page.messages.contains { $0.text.contains("按标签筛选") } })
    }

    @Test func aFailedAdoptionSaysWhy() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let adopting = Task { try await store.adopt(sessionId: "s9") }
        #expect(await until { host.request("pals.adopt") != nil })
        #expect(store.adoptions["s9"] == .working)
        host.transport.deliver(json: ["id": .number(Double(host.request("pals.adopt")!.id)),
                                      "error": ["message": "已经开着 5 个 Pal 了，最久没用的是「笔记整理」"]])
        await #expect(throws: RPCError.remote("已经开着 5 个 Pal 了，最久没用的是「笔记整理」")) { _ = try await adopting.value }
        #expect(store.adoptions["s9"] == .failed("已经开着 5 个 Pal 了，最久没用的是「笔记整理」"))
    }

    @Test func aHostFromBeforeSaysSo() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let asking = Task { try await store.refreshRecent() }
        #expect(await until { host.request("pals.recent") != nil })
        host.transport.deliver(json: ["id": .number(Double(host.request("pals.recent")!.id)),
                                      "error": ["message": "unknown method pals.recent"]])
        _ = try? await asking.value
        #expect(store.recentSupported == false && store.recentSessions == nil)
    }

    @Test func theAssistantsCardAdoptsOnlyOnYes() async throws {
        let (store, host) = await demoStore()
        try await store.refreshRecent()
        await host.applyScenario("adopt")
        #expect(await until { store.messages.contains { $0.kind == .palAdopt } })
        let message = try #require(store.messages.last { $0.kind == .palAdopt })
        let card = try #require(store.adoptProposal(in: message))
        #expect(card.isPending && card.title == "首页改成两栏布局" && card.shortCwd == "~/code/site")
        #expect(store.pendingAdoptProposals.map(\.id) == [card.id])
        #expect(store.pendingProposalCount == store.pendingHelperProposals.count + 1)
        #expect(!store.pals.contains { $0.sessionId == card.sessionId })

        let pal = try #require(try await store.decideAdopt(card, .create))
        #expect(await host.lastParams["helper.decide"] == ["proposalId": .string(card.id), "action": "create"])
        #expect(pal.sessionId == card.sessionId && store.pal(id: pal.id) != nil)
        #expect(store.pendingAdoptProposals.isEmpty)
        #expect(await until { store.messages.last { $0.kind == .palAdopt }?.adoption?.status == .adopted })
        let shown = try #require(store.adoptProposal(in: store.messages.last { $0.kind == .palAdopt }!))
        #expect(shown.status == .adopted && shown.palId == pal.id)
        // It left the recent ones.
        #expect(store.recentSessions?.contains { $0.sessionId == card.sessionId } == false)
        // Asked again: the same Pal.
        #expect(try await store.decideAdopt(card, .create)?.id == pal.id)
    }

    @Test func noToTheCardAdoptsNothing() async throws {
        let (store, host) = await demoStore()
        await host.applyScenario("adopt")
        #expect(await until { store.messages.contains { $0.kind == .palAdopt } })
        let card = try #require(store.adoptProposal(in: store.messages.last { $0.kind == .palAdopt }!))
        let palsBefore = store.pals.count
        #expect(try await store.decideAdopt(card, .discard) == nil)
        #expect(await until { store.messages.last { $0.kind == .palAdopt }?.adoption?.status == .discarded })
        #expect(store.pals.count == palsBefore && store.pendingAdoptProposals.isEmpty)
    }

    @Test func aCardNotAdoptedAfterAllShowsWhy() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        var m = ChatMessage(seq: 1, id: "m1", role: .assistant, kind: .palAdopt, text: "", channel: .system, ts: 1)
        m.adoption = PalAdoptProposal(id: "pa9", sessionId: "s9", cwd: "/a", title: "t")
        store.apply(event: RPCEventName.chatMessage, data: try JSONValue.from(m))
        #expect(store.pendingAdoptProposals.map(\.id) == ["pa9"])
        let deciding = Task { try await store.decideAdopt(m.adoption!, .create) }
        #expect(await until { host.request("helper.decide") != nil })
        // At once, before the computer answers.
        #expect(store.pendingAdoptProposals.isEmpty)
        #expect(store.adoptProposal(in: store.messages[0])?.status == .adopted)
        // The computer couldn't: the card is re-sent with why, and no Pal comes back.
        m.adoption?.status = .failed
        m.adoption?.note = "有别的进程开着它"
        store.apply(event: RPCEventName.chatMessage, data: try JSONValue.from(m))
        host.respond(host.request("helper.decide")!.id, [:])
        #expect(try await deciding.value == nil)
        let shown = try #require(store.adoptProposal(in: store.messages[0]))
        #expect(shown.status == .failed && shown.note == "有别的进程开着它")
        #expect(store.pendingAdoptProposals.isEmpty) // still on offer, but not waiting on the owner
        // Tapped again: shown at once, as the first time.
        let again = Task { try await store.decideAdopt(shown, .create) }
        #expect(await until { host.requests.filter { $0.method == "helper.decide" }.count == 2 })
        #expect(store.adoptProposal(in: store.messages[0])?.status == .adopted)
        host.respond(host.request("helper.decide")!.id, [:])
        #expect(try await again.value == nil)
        #expect(store.adoptProposal(in: store.messages[0])?.status == .failed)

        // A refused answer puts the card back on offer.
        var n = ChatMessage(seq: 2, id: "m2", role: .assistant, kind: .palAdopt, text: "", channel: .system, ts: 2)
        n.adoption = PalAdoptProposal(id: "pa8", sessionId: "s8", cwd: "/a", title: "t")
        store.apply(event: RPCEventName.chatMessage, data: try JSONValue.from(n))
        let refused = Task { try await store.decideAdopt(n.adoption!, .create) }
        #expect(await until { host.requests.filter { $0.method == "helper.decide" }.count == 3 })
        let id = try #require(host.request("helper.decide")?.id)
        host.transport.deliver(json: ["id": .number(Double(id)), "error": ["message": "没连上"]])
        await #expect(throws: RPCError.remote("没连上")) { _ = try await refused.value }
        #expect(store.pendingAdoptProposals.map(\.id) == ["pa8"])
    }
}
