import Foundation
import Testing
@testable import PaloAllyKit

/// Pals (pals-prd §8): the wire shapes, and the store as Pals, their
/// conversations, their cards and adoptions change.
@Suite("Pals decoding")
struct PalsDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> (T, [String]) {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LenientDiagnostics.collect { try v.decode(T.self) }
    }

    @Test func palAsInThePRD() throws {
        let (p, issues) = try decode(Pal.self, """
        {"id":"p1","name":"网站帮手","cwd":"/Users/someone/code/site","sessionId":"5d821f3c-7a1e","status":"waiting",
         "lastLine":"列表页做完了","pending":1,"model":"claude-opus-5-5","createdBy":"palo"}
        """)
        #expect(issues.isEmpty)
        #expect(p.status == .waiting && p.inTurn && p.pending == 1 && p.createdBy == .palo)
        #expect(p.shortCwd == "~/code/site" && p.displayName == "网站帮手")
        #expect(p.resumeCommand == "claude --resume 5d821f3c-7a1e")
        // Only lastLine and model may be left out.
        let (bare, bareIssues) = try decode(Pal.self, #"{"id":"p2","name":"","cwd":"/tmp/notes","sessionId":"s","status":"starting","pending":0,"createdBy":"owner"}"#)
        #expect(bareIssues.isEmpty && bare.displayName == "notes" && !bare.inTurn)
        let (_, missing) = try decode(Pal.self, #"{"id":"p3","name":"a","status":"idle"}"#)
        #expect(missing.contains { $0.contains("sessionId") } && missing.contains { $0.contains("pending") }
            && missing.contains { $0.contains("createdBy") } && missing.contains { $0.contains("cwd") })
        // A new status from a newer host doesn't drop the Pal.
        let (odd, oddIssues) = try decode(Pal.self, #"{"id":"p4","name":"a","cwd":"/","sessionId":"s","status":"dreaming","pending":0,"createdBy":"owner"}"#)
        #expect(odd.status == .unknown && oddIssues.count == 1)
    }

    @Test func listAdoptReleaseAndUpdates() throws {
        let (list, issues) = try decode(PalsResult.self, """
        {"pals":[{"id":"p1","name":"网站帮手","cwd":"/a","sessionId":"s1","status":"idle","pending":0,"createdBy":"owner"}],
         "others":[{"id":"s2","name":"修登录跳转","cwd":"/b","kind":"terminal","status":"busy","updatedAt":1}],"hooks":true}
        """)
        #expect(issues.isEmpty && list.pals.count == 1 && list.others.first?.kind == .terminal && list.hooks == true)

        let (adopted, a1) = try decode(PalAdoptResult.self, #"{"pal":{"id":"p1","name":"a","cwd":"/","sessionId":"s1","status":"idle","pending":0,"createdBy":"owner"}}"#)
        #expect(a1.isEmpty && adopted.pal?.id == "p1" && adopted.waiting == nil)
        let (waiting, a2) = try decode(PalAdoptResult.self, #"{"waiting":"exit-in-terminal"}"#)
        #expect(a2.isEmpty && waiting.pal == nil && waiting.waiting == .exitInTerminal)
        let (_, a3) = try decode(PalAdoptResult.self, #"{}"#)
        #expect(!a3.isEmpty)

        let (released, r1) = try decode(PalReleaseResult.self, #"{"resumeCommand":"claude --resume s1"}"#)
        #expect(r1.isEmpty && released.resumeCommand == "claude --resume s1")

        if case .list(let r, let hasOthers) = PalsUpdate(json: ["pals": .array([]), "others": .array([])]) {
            #expect(r.pals.isEmpty && hasOthers)
        } else { Issue.record("a whole list") }
        if case .list(_, let hasOthers) = PalsUpdate(json: ["pals": .array([])]) { #expect(!hasOthers) } else { Issue.record("pals only") }
        if case .removed(let id) = PalsUpdate(json: ["removed": "p1"]) { #expect(id == "p1") } else { Issue.record("removed") }
        if case .refetch = PalsUpdate(json: ["what": 1]) {} else { Issue.record("refetch") }
    }

    @Test func messagesDeltasAndCardsCarryTheirPal() throws {
        let (m, issues) = try decode(ChatMessage.self, """
        {"seq":3,"id":"m3","role":"user","kind":"text","text":"设计稿在这","channel":"system","ts":1,"pal":"p1","from":"Palo"}
        """)
        #expect(issues.isEmpty && m.pal == "p1" && m.from == "Palo")
        let (d, dIssues) = try decode(ChatDelta.self, #"{"id":"r1","text":"好","pal":"p1"}"#)
        #expect(dIssues.isEmpty && d.pal == "p1")
        let (own, _) = try decode(ChatDelta.self, #"{"id":"r1","text":"好"}"#)
        #expect(own.pal == nil)
        let (src, sIssues) = try decode(CardSource.self, #"{"kind":"pal","id":"p1","name":"网站帮手"}"#)
        #expect(sIssues.isEmpty && src.isPal && !src.isSession)
    }
}

@MainActor
@Suite("Pals store", .serialized)
struct PalsStoreTests {
    func demoStore() async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.pals.count == 2 }
        return (store, host)
    }

    @Test func listLoadsWithTheOtherSessions() async throws {
        let (store, _) = await demoStore()
        #expect(store.palsSupported == true && store.sessionHooksEnabled == true)
        #expect(store.pals.map(\.name) == ["网站帮手", "笔记整理"])
        #expect(store.otherSessions.map(\.name) == ["修登录跳转", "问卷数据清洗"])
        #expect(store.palPendingCount("pal-site") == 1 && store.palPendingCount("pal-notes") == 0)
        #expect(store.sessionPendingCount("cc-data") == 1)
    }

    @Test func aPalsCardIsOnItsPageNotTheAssistants() async throws {
        let (store, _) = await demoStore()
        #expect(store.approval(id: "pa1")?.source?.isPal == true)
        #expect(!store.liveEndApprovals.contains { $0.id == "pa1" })
        #expect(!store.pendingApprovals.contains { $0.id == "pa1" })
        // The other session's question stays with the assistant's.
        #expect(store.liveEndQuestions.map(\.id) == ["sq1"])
        let site = store.palStore("pal-site")
        #expect(site.liveEndApprovals.map(\.id) == ["pa1"])
        #expect(site.pendingApprovals.map(\.id) == ["pa1"])
        #expect(site.liveEndQuestions.isEmpty && site.unanchoredPendingDrafts.isEmpty)
        #expect(store.palStore("pal-notes").liveEndApprovals.isEmpty)
        // One store per Pal, the same each time.
        #expect(store.palStore("pal-site") === site && site.palStore("pal-site") === site)
    }

    @Test func aPalsConversationLoadsAndPagesBack() async throws {
        let (store, host) = await demoStore()
        store.initialHistoryLimit = 10
        let site = store.palStore("pal-site")
        #expect(await until { site.messages.count == 10 })
        #expect(site.hasOlderMessages && site.hasSynced)
        #expect(site.messages.last?.text.contains("跑一下构建") == true)
        #expect(site.messages.allSatisfy { $0.pal == "pal-site" })
        // The assistant's conversation is untouched.
        #expect(!store.messages.contains { $0.pal != nil })
        let oldest = try #require(site.messages.first)
        await site.loadOlder(limit: 10)
        #expect(site.messages.count == 20)
        #expect(await host.lastParams["pals.history"] == ["id": "pal-site", "before": .string(oldest.id), "limit": 10])
        while site.hasOlderMessages { await site.loadOlder(limit: 10) }
        #expect(site.messages.count == 39)
        #expect(site.messages.map(\.seq) == Array(1...39).map(Int64.init))
        // The assistant's words to it say who they're from.
        #expect(site.messages.first?.from == "Palo" && site.messages.first?.role == .user)
    }

    @Test func wordsGoInAsTypedAndTheReplyStreams() async throws {
        let (store, host) = await demoStore()
        let notes = store.palStore("pal-notes")
        #expect(await until { notes.hasSynced })
        let before = store.messages.count
        notes.send("  把上周的也归一下  ")
        #expect(notes.messages.last?.role == .user && notes.messages.last?.delivery == .sending)
        #expect(notes.awaitingReply)
        #expect(await until { notes.messages.last?.role == .assistant && notes.messages.last?.isStreaming == false })
        let params = try #require(await host.lastParams["pals.send"])
        #expect(params["id"] == "pal-notes" && params["text"] == "把上周的也归一下" && params["clientMsgId"]?.stringValue != nil)
        // One copy of the owner's words, then the answer.
        #expect(notes.messages.filter { $0.text == "把上周的也归一下" }.count == 1)
        #expect(notes.messages.last?.text.hasPrefix("好的，按你说的办。") == true)
        #expect(await until { !notes.isBusy && store.pal(id: "pal-notes")?.status == .idle })
        // Nothing of it in the assistant's conversation.
        #expect(store.messages.count == before)
    }

    @Test func stopEndsItsTurn() async throws {
        let host = DemoHost(speed: 1, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.pals.count == 2 })
        let notes = store.palStore("pal-notes")
        #expect(await until { notes.hasSynced })
        notes.send("开始吧")
        #expect(await until(5) { store.pal(id: "pal-notes")?.status == .busy && notes.status?.busy == true })
        try await notes.stop()
        #expect(await host.lastParams["pals.stop"] == ["id": "pal-notes"])
        #expect(await until { store.pal(id: "pal-notes")?.status == .idle && !notes.isBusy })
    }

    @Test func answeringItsCardLetsItCarryOn() async throws {
        let (store, _) = await demoStore()
        let site = store.palStore("pal-site")
        #expect(await until { site.hasSynced })
        #expect(site.status?.busy == true) // waiting on the card: still in its turn
        let card = try #require(site.liveEndApprovals.first)
        try await site.answer(card, allow: true)
        #expect(site.liveEndApprovals.isEmpty)
        #expect(await until { site.messages.last?.text.contains("构建通过了") == true })
        #expect(await until { store.pal(id: "pal-site")?.status == .idle && site.status?.busy == false })
    }

    @Test func adoptingABackgroundSessionMakesAPal() async throws {
        let (store, host) = await demoStore()
        let outcome = try await store.adopt(sessionId: "cc-data")
        guard case .adopted(let pal) = outcome else { Issue.record("not adopted: \(outcome)"); return }
        #expect(pal.name == "问卷数据清洗" && pal.sessionId == "cc-data")
        #expect(await host.lastParams["pals.adopt"] == ["sessionId": "cc-data"])
        #expect(store.adoptions.isEmpty)
        #expect(await until { !store.otherSessions.contains { $0.id == "cc-data" } && store.pals.count == 3 })
        // Its question is the Pal's now.
        #expect(await until { store.question(id: "sq1")?.source?.id == pal.id })
        #expect(store.liveEndQuestions.isEmpty)
        #expect(store.palStore(pal.id).liveEndQuestions.map(\.id) == ["sq1"])
    }

    @Test func aTerminalSessionWaitsToBeQuitThenOpens() async throws {
        UserDefaults.standard.set(0, forKey: "demoAdoptAfter") // the demo's owner never quits it
        defer { UserDefaults.standard.removeObject(forKey: "demoAdoptAfter") }
        let (store, host) = await demoStore()
        var opened: [Pal] = []
        store.onAdopted = { opened.append($0) }
        #expect(try await store.adopt(sessionId: "cc-login") == .waitingForExit)
        #expect(store.adoptions["cc-login"] == .waitingForExit)
        // Quit in the terminal: the host carries on, and it opens.
        await host.finishAdoption("cc-login")
        #expect(await until { opened.map(\.sessionId) == ["cc-login"] })
        #expect(store.adoptions.isEmpty && store.pal(sessionId: "cc-login") != nil)
    }

    @Test func cancellingTheWaitOpensNothing() async throws {
        UserDefaults.standard.set(0, forKey: "demoAdoptAfter")
        defer { UserDefaults.standard.removeObject(forKey: "demoAdoptAfter") }
        let (store, host) = await demoStore()
        var opened = 0
        store.onAdopted = { _ in opened += 1 }
        _ = try await store.adopt(sessionId: "cc-login")
        store.cancelAdoption(sessionId: "cc-login")
        await host.finishAdoption("cc-login")
        #expect(await until { store.pal(sessionId: "cc-login") != nil })
        #expect(opened == 0 && store.adoptions.isEmpty)
    }

    @Test func handingBackGivesTheLineAndRemovingTakesItOff() async throws {
        let (store, _) = await demoStore()
        let line = try await store.releasePal(id: "pal-site")
        #expect(line == "cd /Users/demo/code/site && claude --resume 5d821f3c-7a1e-4c55-9b0e-2f6d81a4c901")
        #expect(store.pal(id: "pal-site") == nil)
        try await store.removePal(id: "pal-notes")
        #expect(store.pals.isEmpty)
    }

    @Test func aProposalOpensAPal() async throws {
        let (store, _) = await demoStore()
        let message = try #require(store.messages.first { $0.kind == .helper })
        let proposal = try #require(store.helperProposal(in: message))
        _ = try await store.decideHelper(proposal, .create)
        let pal = try #require(store.pals.first { $0.name == "报销帮手" })
        #expect(pal.createdBy == .palo)
        #expect(store.helperProposal(in: store.messages.first { $0.kind == .helper }!)?.sessionId == pal.sessionId)
        let page = store.palStore(pal.id)
        #expect(await until { page.messages.contains { $0.from == "Palo" } })
    }

    @Test func aPalsStateComesFromTheList() async throws {
        let (store, _) = await demoStore()
        let notes = store.palStore("pal-notes")
        #expect(notes.status?.busy == false)
        var busy = try #require(store.pal(id: "pal-notes"))
        busy.status = .busy
        store.apply(event: RPCEventName.palsUpdated, data: ["pal": try JSONValue.from(busy)])
        #expect(notes.status?.busy == true && notes.isBusy)
        // A reply being written ends with its turn.
        store.apply(event: RPCEventName.chatDelta, data: ["id": "r9", "text": "写到一半", "pal": "pal-notes"])
        #expect(notes.messages.last?.isStreaming == true)
        busy.status = .idle
        store.apply(event: RPCEventName.palsUpdated, data: ["pals": try JSONValue.from(store.pals.map { $0.id == "pal-notes" ? busy : $0 })])
        #expect(notes.messages.last?.isStreaming == false && notes.messages.last?.text == "写到一半")
        #expect(!notes.isBusy)
        // Removed from the list.
        store.apply(event: RPCEventName.palsUpdated, data: ["removed": "pal-notes"])
        #expect(store.pal(id: "pal-notes") == nil)
    }

    @Test func aHostWithoutPalsHidesThem() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { host.request("pals.list") != nil })
        host.transport.deliver(json: ["id": .number(Double(host.request("pals.list")!.id)),
                                      "error": ["message": "unknown method pals.list"]])
        #expect(await until { store.palsSupported == false })
        #expect(store.pals.isEmpty)
    }
}

@Suite("Pals quoting")
struct PalsQuotingTests {
    @Test func aQuoteGoesInFrontAsMarkdown() {
        #expect(AppStore.quoting(nil, in: "好") == "好")
        #expect(AppStore.quoting(ReplyTo(messageId: "m", excerpt: "第一行\n第二行"), in: "这里改一下")
            == "> 第一行\n> 第二行\n\n这里改一下")
    }
}
