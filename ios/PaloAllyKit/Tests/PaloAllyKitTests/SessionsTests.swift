import Foundation
import Testing
@testable import PaloAllyKit

/// Sessions (sessions-prd §7): decoding the wire shapes, and the store's
/// state as sessions, their conversations and their cards change.
@Suite("Sessions decoding")
struct SessionsDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> (T, [String]) {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LenientDiagnostics.collect { try v.decode(T.self) }
    }

    @Test func sessionAsInThePRD() throws {
        let (s, issues) = try decode(CCSession.self, """
        {"id":"s1","name":"网站帮手","cwd":"/Users/someone/code/site","kind":"helper","status":"waiting",
         "waitingFor":"想运行 npm run build","lastLine":"列表页做完了","contextTokens":182000,"updatedAt":1791216926595}
        """)
        #expect(issues.isEmpty)
        #expect(s.isHelper && s.status == .waiting && s.isRunning && s.canAttach)
        #expect(s.contextTokens == 182_000 && s.waitingFor == "想运行 npm run build")
        #expect(s.shortCwd == "~/code/site")
        // Only the optional fields may be left out.
        let (bare, bareIssues) = try decode(CCSession.self, #"{"id":"s2","name":"","cwd":"/tmp/x","kind":"terminal","status":"idle","updatedAt":1}"#)
        #expect(bareIssues.isEmpty && bare.lastLine == nil && bare.contextTokens == nil)
        #expect(bare.displayName == "x" && !bare.canAttach)
        let (_, missing) = try decode(CCSession.self, #"{"id":"s3","name":"a","kind":"background","status":"stopped"}"#)
        #expect(missing.contains { $0.contains("cwd") } && missing.contains { $0.contains("updatedAt") })
        // A new kind or status from a newer host doesn't drop the session.
        let (odd, oddIssues) = try decode(CCSession.self, #"{"id":"s4","name":"a","cwd":"/","kind":"cloud","status":"sleeping","updatedAt":1}"#)
        #expect(odd.kind == .unknown && odd.status == .unknown && oddIssues.count == 2 && !odd.isRunning)
    }

    @Test func messagesOfEveryRole() throws {
        let (r, issues) = try decode(SessionMessagesResult.self, """
        {"messages":[
          {"id":"1","ts":1,"role":"owner","text":"列表要能按日期排序"},
          {"id":"2","ts":2,"role":"assistant","text":"好的"},
          {"id":"3","ts":3,"role":"peer","text":"设计稿在这","from":"笔记整理"},
          {"id":"4","ts":4,"role":"palo","text":"主人：先别管登录页"},
          {"id":"5","ts":5,"role":"palo","text":"你好，我是 Palo。","from":"Palo"},
          {"id":"6","ts":6,"role":"palo","text":"详情页也做了吧","from":"主人"}]}
        """)
        #expect(issues.isEmpty)
        #expect(r.messages.map(\.role) == [.owner, .assistant, .peer, .palo, .palo, .palo])
        #expect(r.messages[5].from == "主人" && r.messages[5].shownText == "详情页也做了吧")
        #expect(r.messages[2].from == "笔记整理")
        // The 「主人：」 the host puts in front for the session isn't shown.
        #expect(r.messages[3].shownText == "先别管登录页")
        #expect(r.messages[4].shownText == "你好，我是 Palo。")
        #expect(r.messages[0].shownText == "列表要能按日期排序")
    }

    @Test func cardsCarryTheirSourceAndNote() throws {
        let (a, issues) = try decode(Approval.self, """
        {"id":"a1","tool":"Bash","title":"在电脑上运行一条命令","detail":"npm run build","careful":false,"status":"expired",
         "createdAt":1,"suggestedScope":"cmd:npm run build","source":{"kind":"session","id":"s1","name":"网站帮手"},"note":"在电脑上等你"}
        """)
        #expect(issues.isEmpty)
        #expect(a.source == CardSource(id: "s1", name: "网站帮手") && a.source?.isSession == true)
        #expect(a.status == .expired && a.note == "在电脑上等你")
        // A session's prompt never offers "always allow".
        #expect(!a.canRemember)
        var own = a
        own.source = nil
        #expect(own.canRemember)

        let (q, qIssues) = try decode(Question.self, """
        {"id":"q1","items":[{"question":"方案选 A 还是 B？","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}],
         "status":"pending","createdAt":1,"source":{"kind":"session","id":"s2","name":"数据清洗"}}
        """)
        #expect(qIssues.isEmpty && q.source?.name == "数据清洗" && q.note == nil)
        // Handled at the computer, not waiting there.
        var handled = a
        handled.decidedBy = "computer"
        handled.note = "已在电脑上处理"
        #expect(AppStore.handledAtComputer(by: handled.decidedBy, note: handled.note))
        #expect(!AppStore.handledAtComputer(by: "timeout", note: "在电脑上等你"))
        // A source missing its name is reported.
        let (_, srcIssues) = try decode(CardSource.self, #"{"kind":"session","id":"s1"}"#)
        #expect(srcIssues.contains { $0.contains("name") })
        // Encoded and back (the demo host and fixtures encode cards).
        let again = try JSONValue.from(a).decode(Approval.self)
        #expect(again.source == a.source && again.note == "在电脑上等你")
        let qAgain = try JSONValue.from(q).decode(Question.self)
        #expect(qAgain.source == q.source)
    }

    @Test func helperProposalInTheConversation() throws {
        let (m, issues) = try decode(ChatMessage.self, """
        {"seq":3,"id":"m3","role":"assistant","kind":"helper","text":"要不要开一个帮手专门管？","channel":"app","ts":1,
         "proposal":{"id":"hp1","name":"网站帮手","cwd":"/Users/someone/code/site","duty":"做网站","dailyUsd":5,"status":"pending"}}
        """)
        #expect(issues.isEmpty)
        #expect(m.kind == .helper)
        let p = try #require(m.proposal)
        #expect(p.id == "hp1" && p.name == "网站帮手" && p.dailyUsd == 5 && p.isPending)
        // Also read: `helper` for the object, `proposalId` and `dir`; and
        // why it didn't start.
        let (alt, altIssues) = try decode(ChatMessage.self, """
        {"seq":4,"id":"m4","role":"assistant","kind":"helper","text":"","channel":"app","ts":1,
         "helper":{"proposalId":"hp2","name":"笔记整理","dir":"/notes","duty":"归类","status":"expired","note":"同时开着的帮手最多 3 个"}}
        """)
        #expect(altIssues.isEmpty)
        #expect(alt.proposal?.id == "hp2" && alt.proposal?.cwd == "/notes" && alt.proposal?.dailyUsd == nil)
        #expect(alt.proposal?.status == .expired && alt.proposal?.note == "同时开着的帮手最多 3 个")
        let (bare, bareIssues) = try decode(HelperProposal.self, #"{"id":"hp3","name":"a","cwd":"/","duty":"b"}"#)
        #expect(bareIssues.isEmpty && bare.isPending) // a proposal that doesn't say is on offer
        let again = try JSONValue.from(m).decode(ChatMessage.self)
        #expect(again.proposal == p)
    }

    @Test func rpcResultsAndParams() throws {
        let (list, i1) = try decode(SessionsResult.self, #"{"sessions":[{"id":"s","name":"a","cwd":"/","kind":"background","status":"busy","updatedAt":1}],"hooks":false}"#)
        #expect(i1.isEmpty && list.sessions.count == 1 && list.hooks == false)
        let (noHooks, i2) = try decode(SessionsResult.self, #"{"sessions":[]}"#)
        #expect(i2.isEmpty && noHooks.hooks == nil)
        let (hooks, i3) = try decode(SessionHooksResult.self, #"{"enabled":true}"#)
        #expect(i3.isEmpty && hooks.enabled)
        let (created, i4) = try decode(HelperDecideResult.self, #"{"session":{"id":"s","name":"报销帮手","cwd":"/","kind":"helper","status":"busy","updatedAt":1}}"#)
        #expect(i4.isEmpty && created.session?.isHelper == true)
        let (discarded, i5) = try decode(HelperDecideResult.self, "{}")
        #expect(i5.isEmpty && discarded.session == nil)

        #expect(try JSONValue.from(SessionHistoryParams(id: "s")) == ["id": "s"])
        #expect(try JSONValue.from(SessionHistoryParams(id: "s", before: "m9", limit: 50)) == ["id": "s", "before": "m9", "limit": 50])
        #expect(try JSONValue.from(SessionSendParams(id: "s", text: "先别管登录页")) == ["id": "s", "text": "先别管登录页"])
        #expect(try JSONValue.from(SessionControlParams(id: "s", action: .revive)) == ["id": "s", "action": "revive"])
        #expect(try JSONValue.from(SessionHooksParams(enabled: false)) == ["enabled": false])
        #expect(try JSONValue.from(HelperDecideParams(proposalId: "hp1", action: .create)) == ["proposalId": "hp1", "action": "create"])
    }

    @Test func updatedEventShapes() throws {
        let s: JSONValue = ["id": "s", "name": "a", "cwd": "/", "kind": "helper", "status": "idle", "updatedAt": 1]
        if case .list(let l) = SessionsUpdate(json: ["sessions": [s]]) { #expect(l.count == 1) } else { Issue.record("list") }
        if case .upsert(let x) = SessionsUpdate(json: ["session": s]) { #expect(x.id == "s") } else { Issue.record("session") }
        if case .upsert(let x) = SessionsUpdate(json: s) { #expect(x.status == .idle) } else { Issue.record("bare") }
        if case .removed(let id) = SessionsUpdate(json: ["removed": "s"]) { #expect(id == "s") } else { Issue.record("removed") }
        if case .changed(let id) = SessionsUpdate(json: ["id": "s"]) { #expect(id == "s") } else { Issue.record("id alone") }
        if case .changed(let id) = SessionsUpdate(json: ["sessionId": "s"]) { #expect(id == "s") } else { Issue.record("sessionId") }
        if case .refetch = SessionsUpdate(json: [:]) {} else { Issue.record("empty → refetch") }
    }

    @Test func listOrderAndPaths() {
        let a = CCSession(id: "a", name: "终端里的", cwd: "/", kind: .terminal, status: .idle, updatedAt: 3)
        let b = CCSession(id: "b", name: "帮手一", cwd: "/", kind: .helper, status: .idle, updatedAt: 1)
        let c = CCSession(id: "c", name: "后台的", cwd: "/", kind: .background, status: .busy, updatedAt: 2)
        let d = CCSession(id: "d", name: "帮手二", cwd: "/", kind: .helper, status: .stopped, updatedAt: 4)
        #expect(CCSession.listOrder([a, b, c, d]).map(\.id) == ["b", "d", "a", "c"])
        #expect(CCSession.shortPath("/Users/someone") == "~")
        #expect(CCSession.shortPath("/home/someone/notes/a") == "~/notes/a")
        #expect(CCSession.shortPath("/opt/work") == "/opt/work")
    }

    @Test func historyPagesMergeInOrder() {
        func m(_ id: String, _ ts: Int64) -> CCMessage { CCMessage(id: id, ts: ts, role: .assistant, text: id) }
        let latest = [m("c", 3), m("d", 4)]
        let older = [m("a", 1), m("b", 2)]
        #expect(AppStore.merge(latest, older, older: true).map(\.id) == ["a", "b", "c", "d"])
        // The newest page again, with one more and one changed: no duplicates.
        var changed = m("d", 4)
        changed.text = "改过"
        let again = AppStore.merge(older + latest, [changed, m("e", 5)], older: false)
        #expect(again.map(\.id) == ["a", "b", "c", "d", "e"] && again[3].text == "改过")
        // A page with one id twice keeps one line, the later copy.
        var twice = m("c", 3)
        twice.text = "后来的"
        #expect(AppStore.merge([], [m("c", 3), twice], older: false).map(\.text) == ["后来的"])
        // Equal times keep the order they came in.
        #expect(AppStore.merge([m("x", 1)], [m("y", 1)], older: false).map(\.id) == ["x", "y"])
    }

    @Test func helperControlCardsInPlainWords() {
        #expect(Friendly.tool("helper_stop") == "停帮手")
        #expect(Friendly.tool("mcp__paloally__helper_restart") == "重启帮手")
        #expect(Friendly.tool("Bash") == "运行命令")
    }

    @Test func proposalsCountAsWaitingOnTheOwner() {
        let one = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, pendingProposals: 1, busy: false, activity: nil, tasks: [])
        #expect(one == AgentStatusLine(kind: .needsYou, text: "等你点头"))
        let mixed = AgentStatusLine.make(offlineText: nil, pendingApprovals: 1, pendingProposals: 1, busy: false, activity: nil, tasks: [])
        #expect(mixed.text == "2 件事等你")
    }
}

@MainActor
@Suite("Sessions store")
struct SessionsStoreTests {
    func demoStore() async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, sessions: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.sessions.count == 4 }
        return (store, host)
    }

    @Test func listLoadsAfterConnectingHelpersFirst() async throws {
        let (store, _) = await demoStore()
        #expect(store.sessionsSupported == true)
        #expect(store.sessionHooksEnabled == true)
        #expect(store.sessions.map(\.name) == ["网站帮手", "笔记整理", "修登录跳转", "问卷数据清洗"])
        #expect(store.sessions.map(\.kind) == [.helper, .helper, .terminal, .background])
        #expect(store.sessions.filter { $0.status == .waiting }.map(\.id) == ["cc-site", "cc-data"])
        // Their cards wait at the live end with the assistant's own; the
        // proposal is in the conversation.
        #expect(store.pendingApprovals.contains { $0.id == "sa1" && $0.source?.name == "网站帮手" })
        #expect(store.liveEndApprovals.map(\.id).contains("sa1"))
        #expect(store.liveEndQuestions.map(\.id) == ["sq1"])
        #expect(store.pendingHelperProposals.map(\.id) == ["hp1"])
    }

    @Test func aDemoWithoutSessionsListsNone() async throws {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.sessionsSupported == true })
        #expect(store.sessions.isEmpty && store.liveEndQuestions.isEmpty && store.pendingHelperProposals.isEmpty)
    }

    @Test func historyLoadsAndPagesBack() async throws {
        let (store, _) = await demoStore()
        let page = try await store.loadSessionHistory(id: "cc-site")
        #expect(page.count == 39)
        #expect(store.sessionHistoryHasMore["cc-site"] == false)
        _ = try await store.loadSessionHistory(id: "cc-site", limit: 10)
        // A fresh store, smaller pages: the newest first, then older ones.
        let (small, host) = await demoStore()
        _ = try await small.loadSessionHistory(id: "cc-site", limit: 10)
        #expect(small.sessionHistory("cc-site").count == 10)
        #expect(small.sessionHistory("cc-site").last?.text.contains("跑一下构建") == true)
        #expect(small.sessionHistoryHasMore["cc-site"] == true)
        let oldest = try #require(small.sessionHistory("cc-site").first)
        _ = try await small.loadSessionHistory(id: "cc-site", before: oldest.id, limit: 10)
        #expect(small.sessionHistory("cc-site").count == 20)
        #expect(await host.lastParams["sessions.history"] == ["id": "cc-site", "before": .string(oldest.id), "limit": 10])
        for _ in 0..<3 {
            _ = try await small.loadSessionHistory(id: "cc-site", before: small.sessionHistory("cc-site").first?.id, limit: 10)
        }
        #expect(small.sessionHistory("cc-site").count == 39)
        #expect(small.sessionHistoryHasMore["cc-site"] == false)
        let ts = small.sessionHistory("cc-site").map(\.ts)
        #expect(ts == ts.sorted())
        #expect(small.sessionHistory("cc-site").map(\.id) == store.sessionHistory("cc-site").map(\.id))
    }

    @Test func sentWordsWaitUntilTheConversationHasThem() async throws {
        let (store, host) = await demoStore()
        store.watchSession("cc-site")
        _ = try await store.loadSessionHistory(id: "cc-site")
        try await store.sendToSession(id: "cc-site", text: "  先别管登录页，把列表页做完  ")
        #expect(await host.lastParams["sessions.send"] == ["id": "cc-site", "text": "先别管登录页，把列表页做完"])
        // The host's update brings the session's conversation, with the words in it.
        #expect(await until { store.pendingSends("cc-site").isEmpty })
        let said = try #require(store.sessionHistory("cc-site").last { $0.role == .palo })
        #expect(said.shownText == "先别管登录页，把列表页做完")
        #expect(await until { store.sessionHistory("cc-site").last?.role == .assistant })
        store.unwatchSession("cc-site")
    }

    @Test func aSendTheComputerRefusesCanBeTriedAgain() async throws {
        let (store, _) = await demoStore()
        try await store.controlSession(id: "cc-notes", action: .stop)
        #expect(store.session(id: "cc-notes")?.status == .stopped)
        await #expect(throws: RPCError.remote("笔记整理已经停了，先复活它")) {
            try await store.sendToSession(id: "cc-notes", text: "在吗")
        }
        let failed = try #require(store.pendingSends("cc-notes").first)
        #expect(failed.state == .failed && failed.text == "在吗")
        try await store.controlSession(id: "cc-notes", action: .revive)
        #expect(store.session(id: "cc-notes")?.status == .idle)
        try await store.retrySend(failed, to: "cc-notes")
        #expect(store.pendingSends("cc-notes").first?.state != .failed)
        store.dropSend(failed, from: "cc-notes")
        #expect(store.pendingSends("cc-notes").isEmpty)
    }

    @Test func helpersCanBeStoppedRestartedRemovedAndRevived() async throws {
        let (store, host) = await demoStore()
        for (action, status) in [(SessionControlAction.stop, CCSessionStatus.stopped), (.restart, .idle), (.remove, .stopped), (.revive, .idle)] {
            try await store.controlSession(id: "cc-notes", action: action)
            #expect(store.session(id: "cc-notes")?.status == status, "\(action)")
            #expect(await host.lastParams["sessions.control"] == ["id": "cc-notes", "action": .string(action.rawValue)])
        }
        // Not a helper: the computer refuses, and nothing changes here.
        await #expect(throws: RPCError.remote("只能管帮手")) { try await store.controlSession(id: "cc-login", action: .stop) }
        #expect(store.session(id: "cc-login")?.status == .busy)
    }

    @Test func theHooksSwitch() async throws {
        let (store, host) = await demoStore()
        try await store.setSessionHooks(false)
        #expect(store.sessionHooksEnabled == false)
        #expect(await host.hooksEnabled == false)
        try await store.refreshSessions()
        #expect(store.sessionHooksEnabled == false)
    }

    @Test func answeringASessionsCardMovesItOn() async throws {
        let (store, _) = await demoStore()
        let card = try #require(store.approval(id: "sa1"))
        try await store.answer(card, allow: true)
        #expect(await until { store.session(id: "cc-site")?.status == .busy })
        #expect(!store.liveEndApprovals.contains { $0.id == "sa1" })
        let q = try #require(store.question(id: "sq1"))
        try await store.answer(q, answers: ["没填收入的 37 份问卷怎么处理？": "B 用中位数补上"])
        #expect(await until { store.session(id: "cc-data")?.status == .busy })
        #expect(store.liveEndQuestions.isEmpty)
    }

    @Test func anExpiredCardWaitsAtTheComputerUntilItsSettledThere() async throws {
        let (store, host) = await demoStore()
        await host.applyScenario("sessionExpired")
        #expect(await until { store.approval(id: "sa1")?.status == .expired })
        let card = try #require(store.approval(id: "sa1"))
        #expect(card.note == "在电脑上等你" && !card.isPending)
        // Still at the live end, as 「在电脑上等你」.
        #expect(store.liveEndApprovals.map(\.id).contains("sa1"))
        #expect(store.waitsAtComputer(card) && !store.settledAtComputer(card))
        // Answered at the computer: the session moves on and the card goes.
        var moved = try #require(store.session(id: "cc-site"))
        moved.status = .busy
        store.apply(event: RPCEventName.sessionsUpdated, data: ["session": try JSONValue.from(moved)])
        #expect(!store.liveEndApprovals.contains { $0.id == "sa1" })
        #expect(store.settledAtComputer(card))
    }

    @Test func otherDemoStatesSettleSessionsCardsAtTheComputer() async throws {
        let (store, host) = await demoStore()
        await host.applyScenario("allies")
        #expect(await until { store.approval(id: "sa1")?.decidedBy == "computer" })
        #expect(await until { store.question(id: "sq1")?.answeredBy == "computer" })
        let a = try #require(store.approval(id: "sa1"))
        #expect(store.settledAtComputer(a))
        #expect(await until { store.liveEndApprovals.isEmpty && store.liveEndQuestions.isEmpty })
        #expect(await until { !store.sessions.contains { $0.status == .waiting } })
        // Nothing else waits on the owner either: the proposal is withdrawn.
        #expect(await until { store.pendingHelperProposals.isEmpty })
        // The assistant's own decided cards are not "settled at the computer".
        var own = a
        own.source = nil
        #expect(!store.settledAtComputer(own))
    }

    @Test func aHelperProposalStartsAHelperOnlyOnYes() async throws {
        let (store, host) = await demoStore()
        let message = try #require(store.messages.first { $0.kind == .helper })
        let proposal = try #require(store.helperProposal(in: message))
        let created = try #require(try await store.decideHelper(proposal, .create))
        #expect(created.name == "报销帮手" && created.isHelper)
        #expect(store.session(id: created.id) != nil)
        #expect(store.sessions.prefix(3).map(\.isHelper) == [true, true, true]) // helpers first
        #expect(await host.lastParams["helper.decide"] == ["proposalId": "hp1", "action": "create"])
        #expect(store.pendingHelperProposals.isEmpty)
        let shown = try #require(store.helperProposal(in: store.messages.first { $0.kind == .helper }!))
        #expect(shown.status == .created && shown.sessionId == created.id)
        // Answering again changes nothing.
        let again = try await store.decideHelper(proposal, .create)
        #expect(again?.id == created.id)
        #expect(store.sessions.count == 5)
    }

    @Test func noToAProposalStartsNothing() async throws {
        let (store, host) = await demoStore()
        let message = try #require(store.messages.first { $0.kind == .helper })
        let proposal = try #require(store.helperProposal(in: message))
        #expect(try await store.decideHelper(proposal, .discard) == nil)
        #expect(await until { store.messages.first { $0.kind == .helper }?.proposal?.status == .discarded })
        #expect(store.sessions.count == 4)
        #expect(await host.requestLog.contains("helper.decide"))
    }

    @Test func aRefusedDecisionIsPutBack() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        var m = ChatMessage(seq: 1, id: "m1", role: .assistant, kind: .helper, text: "开个帮手？", ts: 1)
        m.proposal = HelperProposal(id: "hp9", name: "帮手", cwd: "/", duty: "做事")
        store.apply(event: RPCEventName.chatMessage, data: try JSONValue.from(m))
        #expect(store.pendingHelperProposals.map(\.id) == ["hp9"])
        let deciding = Task { try await store.decideHelper(m.proposal!, .create) }
        #expect(await until { host.request("helper.decide") != nil })
        #expect(store.pendingHelperProposals.isEmpty) // at once
        host.transport.deliver(json: ["id": .number(Double(host.request("helper.decide")!.id)),
                                      "error": ["message": "同时开着的帮手最多 3 个"]])
        await #expect(throws: RPCError.remote("同时开着的帮手最多 3 个")) { _ = try await deciding.value }
        #expect(store.pendingHelperProposals.map(\.id) == ["hp9"])
    }

    @Test func aHostWithoutSessionsHidesThem() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { host.request("sessions.list") != nil })
        host.transport.deliver(json: ["id": .number(Double(host.request("sessions.list")!.id)),
                                      "error": ["message": "unknown method sessions.list"]])
        #expect(await until { store.sessionsSupported == false })
        #expect(store.sessions.isEmpty)
    }

    @Test func listUpdates() async throws {
        let (store, _) = await demoStore()
        var data = try #require(store.session(id: "cc-data"))
        data.status = .idle
        store.apply(event: RPCEventName.sessionsUpdated, data: ["session": try JSONValue.from(data)])
        #expect(store.session(id: "cc-data")?.status == .idle)
        store.apply(event: RPCEventName.sessionsUpdated, data: ["removed": "cc-data"])
        #expect(store.sessions.count == 3)
        store.apply(event: RPCEventName.sessionsUpdated, data: [:]) // unclear: asks for the list again
        #expect(await until { store.sessions.count == 4 })
        // A brand-new helper goes with the helpers.
        let fresh = CCSession(id: "new", name: "新帮手", cwd: "/", kind: .helper, status: .busy, updatedAt: 9)
        store.apply(event: RPCEventName.sessionsUpdated, data: try JSONValue.from(fresh))
        #expect(store.sessions.map(\.id).prefix(3) == ["cc-site", "cc-notes", "new"])
    }
}
