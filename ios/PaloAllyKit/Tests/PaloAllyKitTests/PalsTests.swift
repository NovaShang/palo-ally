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
        // Asleep (§12), with what waking it cost last time.
        let (asleep, asleepIssues) = try decode(Pal.self, #"{"id":"p5","name":"a","cwd":"/","sessionId":"s","status":"asleep","pending":0,"createdBy":"owner","lastWakeUsd":0.0412,"updatedAt":5}"#)
        #expect(asleepIssues.isEmpty && asleep.isAsleep && !asleep.inTurn && asleep.lastWakeUsd == 0.0412)
        #expect(bare.lastWakeUsd == nil)
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

        let (woke, w1) = try decode(PalWakeResult.self, #"{"pal":{"id":"p1","name":"a","cwd":"/","sessionId":"s1","status":"idle","pending":0,"createdBy":"owner","lastWakeUsd":0.03}}"#)
        #expect(w1.isEmpty && woke.pal?.status == .idle && woke.pal?.lastWakeUsd == 0.03)
        let (_, w2) = try decode(PalWakeResult.self, #"{}"#)
        #expect(!w2.isEmpty)

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
        _ = await until { store.connection == .online && store.pals.count == 4 }
        return (store, host)
    }

    @Test func listLoadsWithTheOtherSessions() async throws {
        let (store, _) = await demoStore()
        #expect(store.palsSupported == true && store.sessionHooksEnabled == true)
        #expect(store.pals.map(\.name) == ["网站帮手", "笔记整理", "博客改版", "照片整理"])
        #expect(store.listedPals.filter(\.isAsleep).map(\.name) == ["博客改版", "照片整理"])
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

    @Test func imagesAndFilesGoWithTheWordsAsToPalo() async throws {
        let (store, host) = await demoStore()
        let notes = store.palStore("pal-notes")
        #expect(await until { notes.hasSynced })
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
        notes.send("照这个改", images: [.init(data: png, mediaType: "image/png")],
                   files: [.init(data: Data("要点".utf8), mediaType: "text/plain", name: "要点.txt")])
        // Shown at once from the local bytes.
        #expect(notes.messages.last?.attachments?.count == 2)
        #expect(await until { notes.messages.contains { $0.text == "照这个改" && $0.delivery == .sent } })
        let params = try #require(await host.lastParams["pals.send"])
        guard case .array(let ids)? = params["attachments"] else { Issue.record("no attachments"); return }
        #expect(ids.count == 2)
        let sent = try #require(notes.messages.first { $0.text == "照这个改" })
        #expect(sent.attachments?.map(\.kind) == ["image", "file"])
        #expect(sent.attachments?.last?.name == "要点.txt")
        // The uploaded image is there under the host's id, the file reads back.
        let imageID = try #require(sent.attachments?.first?.id)
        #expect(notes.images[imageID] == png)
        let fileID = try #require(sent.attachments?.last?.id)
        #expect(try await notes.fileData(fileID) == Data("要点".utf8))
        #expect(notes.messages.filter { $0.text == "照这个改" }.count == 1)
    }

    @Test func stopEndsItsTurn() async throws {
        let host = DemoHost(speed: 1, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.pals.count == 4 })
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
        #expect(await until { !store.otherSessions.contains { $0.id == "cc-data" } && store.pals.count == 5 })
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
        await store.cancelAdoption(sessionId: "cc-login")
        // The host stops waiting too, and every device's list says so.
        #expect(await host.lastParams["pals.adopt"] == ["sessionId": "cc-login", "cancel": true])
        #expect(await host.waitingAdoptions.isEmpty)
        #expect(await until { store.otherSessions.first { $0.id == "cc-login" }?.adopting == nil })
        #expect(store.otherSessions.first { $0.id == "cc-login" }.map { store.waitsForExit($0) } == false)
        // Adopted anyway (here, by the test): it isn't opened.
        await host.finishAdoption("cc-login")
        #expect(await until { store.pal(sessionId: "cc-login") != nil })
        #expect(opened == 0 && store.adoptions.isEmpty)
    }

    @Test func anotherDeviceCancellingTheWaitEndsItHere() async throws {
        UserDefaults.standard.set(0, forKey: "demoAdoptAfter")
        defer { UserDefaults.standard.removeObject(forKey: "demoAdoptAfter") }
        let (store, _) = await demoStore()
        #expect(try await store.adopt(sessionId: "cc-login") == .waitingForExit)
        var session = try #require(store.otherSessions.first { $0.id == "cc-login" })
        #expect(store.waitsForExit(session))
        // The host's list without `adopting`: it no longer waits (cancelled elsewhere, or it gave up).
        session.adopting = nil
        let list: JSONValue = ["pals": try .from(store.pals), "others": try .from(store.otherSessions.map { $0.id == "cc-login" ? session : $0 }),
                               "hooks": true]
        store.apply(event: RPCEventName.palsUpdated, data: list)
        #expect(store.adoptions["cc-login"] == nil)
        #expect(!store.waitsForExit(try #require(store.otherSessions.first { $0.id == "cc-login" })))
    }

    @Test func handingBackGivesTheLineAndRemovingTakesItOff() async throws {
        let (store, _) = await demoStore()
        let line = try await store.releasePal(id: "pal-site")
        #expect(line == "cd /Users/demo/code/site && claude --resume 5d821f3c-7a1e-4c55-9b0e-2f6d81a4c901")
        #expect(store.pal(id: "pal-site") == nil)
        try await store.removePal(id: "pal-notes")
        #expect(store.pals.map(\.id) == ["pal-blog", "pal-photos"])
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

    /// Long words another agent sent a Pal fold: the assistant's and another
    /// session's, never the owner's or the Pal's own, and nothing in the
    /// assistant's own conversation. Unfolded stays so while the app runs.
    @Test func longWordsFromAnotherAgentFold() async throws {
        let (store, _) = await demoStore()
        let notes = store.palStore("pal-notes")
        #expect(await until { notes.hasSynced && notes.messages.count > 3 })
        let palo = try #require(notes.messages.first { $0.from == "Palo" })
        let peer = try #require(notes.messages.first { $0.from == "网站帮手" })
        #expect(notes.folds(palo) && notes.folds(peer))
        #expect(notes.messages.filter { notes.folds($0) }.map(\.id) == [palo.id, peer.id])
        #expect(!store.folds(palo))
        // Long by characters: whole only up to the folded lines.
        #expect(MessageFold.wholeLines(String(repeating: "字", count: 280)) == MessageFold.maxLines)
        #expect(MessageFold.wholeLines(String(repeating: "字", count: 281)) == MessageFold.foldedLines)
        notes.setUnfolded(palo.id, true)
        #expect(store.palStore("pal-notes").unfolded == [palo.id])
        notes.setUnfolded(palo.id, false)
        #expect(notes.unfolded.isEmpty)
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

/// Asleep and awake (pals-prd §12): the list's order, and words for an
/// asleep Pal waking it first, its page saying so.
@MainActor
@Suite("Pals asleep and awake", .serialized)
struct PalsSleepTests {
    @Test func theListPutsAwakeOnesFirstEachByLastUse() {
        let p = { (id: String, s: PalStatus, at: Int64?) in Pal(id: id, name: id, cwd: "/", sessionId: id, status: s, updatedAt: at) }
        let order = Pal.listed([p("a", .asleep, 50), p("b", .idle, 10), p("c", .asleep, 90), p("d", .busy, 20), p("e", .idle, nil), p("f", .waiting, 10)])
        #expect(order.map(\.id) == ["d", "b", "f", "e", "c", "a"])
    }

    @Test func wordsForAnAsleepPalWakeItFirstAndThePageSaysSo() async throws {
        UserDefaults.standard.removeObject(forKey: "demoWakeAfter")
        let host = DemoHost(speed: 1, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.pals.count == 4 })
        #expect(store.pal(id: "pal-blog")?.isAsleep == true && store.pal(id: "pal-blog")?.lastWakeUsd == 0.04)
        let blog = store.palStore("pal-blog")
        #expect(await until { blog.hasSynced && blog.messages.count == 3 })
        #expect(blog.status?.busy != true && !blog.isBusy)
        blog.send("评论区再加个点赞")
        #expect(await until { blog.status?.busy == true && blog.status?.activity == AppStore.wakingActivity })
        #expect(await until(5) { store.pal(id: "pal-blog")?.status == .busy || store.pal(id: "pal-blog")?.status == .idle })
        #expect(blog.status?.activity != AppStore.wakingActivity)
        #expect(await until(8) { blog.messages.last?.text.hasPrefix("好的，按你说的办。") == true })
        #expect(blog.messages.filter { $0.text == "评论区再加个点赞" }.count == 1)
        #expect(await host.lastParams["pals.send"]?["id"] == "pal-blog")
        // 叫醒 ahead of any words: pals.wake
        let woke = try await store.wakePal(id: "pal-photos")
        #expect(woke?.status == .idle && store.pal(id: "pal-photos")?.status == .idle)
        #expect(await host.lastParams["pals.wake"] == ["id": "pal-photos"])
    }
}

/// Naming a Pal (pals-prd §13): `pals.rename`, the list following it, a
/// name another Pal has coming back with a number.
@MainActor
@Suite("Pals renamed", .serialized)
struct PalsRenameTests {
    @Test func renamingGoesToTheHostAndTheListFollows() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.pals.count == 4 })
        let p = try await store.renamePal(id: "pal-notes", name: "  读书笔记 ")
        #expect(p?.name == "读书笔记" && store.pal(id: "pal-notes")?.name == "读书笔记")
        #expect(await host.lastParams["pals.rename"] == ["id": "pal-notes", "name": "读书笔记"])
        // its page's store reads the same list
        #expect(store.palStore("pal-notes").pal(id: "pal-notes")?.name == "读书笔记")
        // a name another Pal has: with a number
        #expect(try await store.renamePal(id: "pal-notes", name: "网站帮手")?.name == "网站帮手 2")
        // nothing to call it: not sent, the name stays
        await #expect(throws: (any Error).self) { try await store.renamePal(id: "pal-notes", name: " ") }
        #expect(store.pal(id: "pal-notes")?.name == "网站帮手 2")
        // the host says no: the name goes back
        await #expect(throws: (any Error).self) { try await store.renamePal(id: "pal-notes", name: String(repeating: "长", count: 41)) }
        #expect(store.pal(id: "pal-notes")?.name == "网站帮手 2")
    }

    @Test func renameParamsAndAnswer() throws {
        let data = try JSONEncoder().encode(PalRenameParams(id: "p1", name: "官网"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == ["id": "p1", "name": "官网"])
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"pal":{"id":"p1","name":"官网","cwd":"/","sessionId":"s","status":"idle","pending":0,"createdBy":"owner"}}"#.utf8))
        let (r, issues) = try LenientDiagnostics.collect { try v.decode(PalRenameResult.self) }
        #expect(issues.isEmpty && r.pal?.name == "官网")
    }
}

/// Looking at a session without taking it over (pals-prd §14): its
/// conversation in a read-only store, what's new on the next look, its
/// cards at its end, another agent's long words folded.
@MainActor
@Suite("Sessions looked at", .serialized)
struct SessionViewTests {
    @Test func aLiveSessionsConversationReadOnlyWithItsCards() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.pals.count == 4 && store.otherSessions.count == 2 })
        let login = store.sessionStore("cc-login")
        #expect(store.sessionStore("cc-login") === login && login.viewedSessionID == "cc-login" && login.palID == nil)
        #expect(await until { login.hasSynced && login.messages.count >= 4 })
        #expect(await host.lastParams["sessions.history"]?["id"] == "cc-login")
        let first = try #require(login.messages.first)
        #expect(first.role == .user && first.channel == .cli && first.text.contains("登录以后会跳回首页"))
        let peer = try #require(login.messages.first { $0.from == "笔记整理" })
        #expect(login.folds(peer) && !login.folds(first))
        // the next look has what it said since
        let before = login.messages.count
        await login.reloadSessionPage()
        #expect(login.messages.count > before && login.messages.last?.text.contains("测试文件跑完了") == true)
        #expect(Set(login.messages.map(\.id)).count == login.messages.count)
        // its cards at its end (the other one's question isn't here; it stays with the assistant's too)
        let data = store.sessionStore("cc-data")
        #expect(await until { data.hasSynced })
        #expect(data.liveEndQuestions.map(\.id) == ["sq1"] && login.liveEndQuestions.isEmpty)
        #expect(store.liveEndQuestions.map(\.id) == ["sq1"])
        #expect(!store.messages.contains { $0.text.contains("登录以后会跳回首页") })
    }

    @Test func aConversationThatEndedReadsToo() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.pals.count == 4 })
        try await store.refreshRecent()
        let id = "7c1e9a52-3f0b-4d8e-9a61-0b5c2e7d4f10"
        #expect(store.viewedSession(id)?.name == "首页改成两栏布局" && store.viewedSession(id)?.live == nil)
        let page = store.sessionStore(id)
        #expect(await until { page.messages.count == 3 })
        #expect(page.messages.last?.text.contains("两栏改好了") == true)
        // nothing taken over by looking
        #expect(store.pal(sessionId: id) == nil)
    }
}
