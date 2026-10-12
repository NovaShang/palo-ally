import Foundation
import Testing
@testable import PaloAllyKit

/// Allies (allies-prd §7.5): decoding the wire shapes, and the store's state
/// as the list, exchanges and drafts change.
@Suite("Allies decoding")
struct AlliesDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> (T, [String]) {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LenientDiagnostics.collect { try v.decode(T.self) }
    }

    @Test func allyInfoAsInThePRD() throws {
        let (a, issues) = try decode(AllyInfo.self, """
        {"id":"al1","kind":"family","ownerName":"家人","assistantName":"小橘","online":true,"lastSeen":1791216926595,
         "lastEntry":{"id":"e1","allyId":"al1","dir":"in","ts":1791216900000,"text":"今晚我晚点回","urgent":false,"status":"seen"}}
        """)
        #expect(issues.isEmpty)
        #expect(a.kind == .family && a.online && a.lastSeen == 1791216926595)
        #expect(a.lastEntry?.dir == .incoming && a.lastEntry?.status == .seen)
        #expect(a.displayName == "家人" && a.assistantLabel == "家人的助理")
    }

    @Test func allyNeverSeenAndUnknownKind() throws {
        let (a, issues) = try decode(AllyInfo.self, """
        {"id":"al2","kind":"coworker","ownerName":"","assistantName":"阿福","online":false,"lastSeen":0}
        """)
        #expect(a.lastSeen == 0 && a.lastEntry == nil) // 0: never reached
        #expect(a.kind == .unknown)
        #expect(issues.count == 1 && issues[0].contains("coworker"))
        #expect(a.displayName == "阿福")
        // Missing lastSeen altogether is reported.
        let (_, missing) = try decode(AllyInfo.self, #"{"id":"x","kind":"mine","ownerName":"a","assistantName":"b","online":true}"#)
        #expect(missing.contains { $0.contains("lastSeen") })
    }

    @Test func entryWithSlotsAndEveryStatus() throws {
        let (e, issues) = try decode(AllyEntry.self, """
        {"id":"e2","allyId":"al1","dir":"out","ts":"2026-10-11T18:00:00+08:00","text":"周六下午哪个时间合适？","urgent":true,
         "slots":[{"start":"2026-10-17T14:00:00+08:00","end":"2026-10-17T16:00:00+08:00"}],"replyTo":"e1","status":"draft"}
        """)
        #expect(issues.isEmpty)
        #expect(e.isPendingDraft && e.urgent && e.replyTo == "e1")
        #expect(e.ts == 1_791_712_800_000)
        let slot = try #require(e.slots?.first)
        #expect(slot.startDate == Date(timeIntervalSince1970: 1_792_216_800))
        #expect(slot.endDate.map { $0.timeIntervalSince(slot.startDate!) } == 7200)
        for s in ["draft", "queued", "sent", "delivered", "seen", "rejected"] {
            #expect(AllyEntryStatus(rawValue: s) != nil)
        }
        let (odd, oddIssues) = try decode(AllyEntry.self, #"{"id":"e3","dir":"sideways","ts":1,"text":"x","urgent":false,"status":"lost"}"#)
        #expect(odd.dir == .unknown && odd.status == .unknown && odd.allyId == nil && oddIssues.count == 3)
        #expect(!odd.isPendingDraft)
        // Rejected says why.
        let (no, noIssues) = try decode(AllyEntry.self, #"{"id":"e4","allyId":"a","dir":"out","ts":1,"text":"x","urgent":false,"status":"rejected","note":"3 天没送到"}"#)
        #expect(noIssues.isEmpty && no.status == .rejected && no.note == "3 天没送到")
        // An incoming draft is not the owner's to send.
        #expect(!AllyEntry(id: "i", dir: .incoming, ts: 1, text: "", status: .draft).isPendingDraft)
    }

    @Test func chatMessageOfKindAlly() throws {
        let (m, issues) = try decode(ChatMessage.self, """
        {"seq":7,"id":"m7","role":"system","kind":"ally","text":"今晚我晚点回","channel":"system","ts":1,"proactive":true,
         "allyId":"al1","allyName":"家人","dir":"in","entryId":"e1"}
        """)
        #expect(issues.isEmpty)
        #expect(m.role == .system && m.channel == .system)
        #expect(m.kind == .ally && m.allyId == "al1" && m.allyName == "家人" && m.dir == .incoming && m.entryId == "e1")
        // And back out the same (the demo host and fixtures encode messages).
        let again = try JSONValue.from(m).decode(ChatMessage.self)
        #expect(again.allyId == "al1" && again.dir == .incoming && again.entryId == "e1")
    }

    @Test func rpcResults() throws {
        let (list, i1) = try decode(AlliesResult.self, #"{"allies":[{"id":"a","kind":"mine","ownerName":"我","assistantName":"Palo","online":true,"lastSeen":5}]}"#)
        #expect(i1.isEmpty && list.allies.first?.kind == .mine)
        let (invite, i2) = try decode(AllyInviteResult.self, #"{"link":"paloally://ally?daemon=d&code=1","expiresAt":"2026-10-11T10:10:00Z"}"#)
        #expect(i2.isEmpty && invite.expiresAt == 1_791_713_400_000)
        let (accepted, i3) = try decode(AllyResult.self, #"{"ally":{"id":"a","kind":"family","ownerName":"小林","assistantName":"阿福","online":true,"lastSeen":5}}"#)
        #expect(i3.isEmpty && accepted.ally?.ownerName == "小林")
        let (log, i4) = try decode(AllyEntriesResult.self, #"{"entries":[{"id":"e","allyId":"a","dir":"in","ts":1,"text":"嗨","urgent":false,"status":"delivered"}]}"#)
        #expect(i4.isEmpty && log.entries.count == 1)
        let (decided, i5) = try decode(AllyEntryResult.self, #"{"entry":{"id":"e","allyId":"a","dir":"out","ts":1,"text":"好","urgent":false,"status":"queued"}}"#)
        #expect(i5.isEmpty && decided.entry?.status == .queued)
        let (_, i6) = try decode(AllyEntryResult.self, "{}")
        #expect(i6.contains { $0.contains("entry") })
    }

    @Test func paramsOnTheWire() throws {
        #expect(try JSONValue.from(AllyAcceptParams(link: "paloally://ally?x", kind: .mine)) == ["link": "paloally://ally?x", "kind": "mine"])
        #expect(try JSONValue.from(AllyLogParams(id: "a")) == ["id": "a"])
        #expect(try JSONValue.from(AllyLogParams(id: "a", beforeTs: 9, limit: 20)) == ["id": "a", "beforeTs": 9, "limit": 20])
        #expect(try JSONValue.from(AllyDraftDecideParams(id: "e", action: .discard)) == ["id": "e", "action": "discard"])
        #expect(try JSONValue.from(AllyDraftDecideParams(id: "e", action: .edit, text: "改过的")) == ["id": "e", "action": "edit", "text": "改过的"])
    }

    @Test func updatedEventShapes() throws {
        let info: JSONValue = ["id": "a", "kind": "family", "ownerName": "家人", "assistantName": "小橘", "online": false, "lastSeen": 1]
        if case .list(let l) = AllyUpdate(json: ["allies": [info]]) { #expect(l.count == 1) } else { Issue.record("list") }
        if case .upsert(let a) = AllyUpdate(json: ["ally": info]) { #expect(a.id == "a") } else { Issue.record("ally") }
        if case .upsert(let a) = AllyUpdate(json: info) { #expect(!a.online) } else { Issue.record("bare") }
        if case .removed(let id) = AllyUpdate(json: ["removed": "a"]) { #expect(id == "a") } else { Issue.record("removed") }
        if case .refetch = AllyUpdate(json: [:]) {} else { Issue.record("empty → refetch") }

        let entry: JSONValue = ["id": "e", "dir": "out", "ts": 1, "text": "好", "urgent": false, "status": "draft"]
        let wrapped = try #require(AllyEntryEvent(json: ["allyId": "a", "entry": entry]))
        #expect(wrapped.allyId == "a" && wrapped.entry.isPendingDraft)
        var bareWithAlly = entry
        if case .object(var o) = bareWithAlly { o["allyId"] = "b"; bareWithAlly = .object(o) }
        #expect(AllyEntryEvent(json: bareWithAlly)?.allyId == "b")
        #expect(AllyEntryEvent(json: entry)?.allyId == nil)
        #expect(AllyEntryEvent(json: ["nothing": true]) == nil)
    }

    @Test func inviteLinks() throws {
        let link = "paloally://ally?relay=https%3A%2F%2Frelay.example.com&daemon=d1&code=482913&hostkey=AAAA&name=%E5%B0%8F%E6%98%8E&exp=1791713400000"
        let i = try #require(AllyInviteLink.parse(link))
        #expect(i.name == "小明" && i.daemonID == "d1" && i.code == "482913" && i.link == link)
        #expect(i.expiresAt == Date(timeIntervalSince1970: 1_791_713_400))
        #expect(i.isExpired(now: Date(timeIntervalSince1970: 1_791_713_401)))
        #expect(!i.isExpired(now: Date(timeIntervalSince1970: 1_791_713_399)))
        // exp in seconds, or ISO 8601.
        #expect(AllyInviteLink.parse("paloally://ally?daemon=d&code=1&exp=1791713400")?.expiresAt == Date(timeIntervalSince1970: 1_791_713_400))
        #expect(AllyInviteLink.parse("paloally://ally?daemon=d&code=1&exp=2026-10-11T10:10:00Z")?.expiresAt == Date(timeIntervalSince1970: 1_791_713_400))
        // Without an expiry it never counts as expired (the computer checks).
        #expect(AllyInviteLink.parse("paloally://ally?daemon=d&code=1")?.isExpired() == false)
        // Not ours, or not complete.
        #expect(AllyInviteLink.parse("paloally://pair?daemon=d&code=123456") == nil)
        #expect(AllyInviteLink.parse("paloally://ally?daemon=d") == nil)
        #expect(AllyInviteLink.isAllyLink("PALOALLY://ALLY?x=1"))
        #expect(!AllyInviteLink.isAllyLink("paloally://pair?x=1"))
        // Someone else's QR code: the name is one short line.
        let odd = try #require(AllyInviteLink.parse("paloally://ally?daemon=d&code=1&name=%0A%E5%AE%B6%E4%BA%BA%0D%0A%E7%9A%84" + String(repeating: "x", count: 40)))
        #expect(!odd.name.contains("\n") && !odd.name.contains("\r") && odd.name.count == 24 && odd.name.hasPrefix("家人的"))
    }

    @Test func labels() {
        #expect(AllyInfo.assistantLabel("小林") == "小林的助理")
        #expect(AllyInfo.assistantLabel("小林的助理") == "小林的助理")
        #expect(AllyInfo.assistantLabel("  ") == "对方的助理")
        #expect(AllyInfo.assistantLabel("Alex") == "Alex 的助理")
    }

    @Test func draftsCountAsWaitingOnTheOwner() {
        let one = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, pendingDrafts: 1, busy: false, activity: nil, tasks: [])
        #expect(one == AgentStatusLine(kind: .needsYou, text: "等你点发送"))
        let two = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, pendingDrafts: 2, busy: true, activity: nil, tasks: [])
        #expect(two.text == "2 条等你点发送")
        let mixed = AgentStatusLine.make(offlineText: nil, pendingApprovals: 1, pendingDrafts: 1, busy: false, activity: nil, tasks: [])
        #expect(mixed.text == "2 件事等你")
        let approvals = AgentStatusLine.make(offlineText: nil, pendingApprovals: 2, busy: false, activity: nil, tasks: [])
        #expect(approvals.text == "2 件等你确认")
    }
}

@MainActor
@Suite("Allies store")
struct AlliesStoreTests {
    func demoStore() async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.allyLogs.count == 2 }
        return (store, host)
    }

    @Test func listAndLogsLoadAfterConnecting() async throws {
        let (store, _) = await demoStore()
        #expect(store.alliesSupported == true)
        #expect(store.allies.map(\.displayName) == ["家人", "小林"])
        #expect(store.allyLog("al-family").map(\.id) == ["seed-1", "seed-2", "seed-3", "seed-4"]) // oldest first
        #expect(store.allyLog("al-lin").last?.status == .queued, "\(store.allyLog("al-lin").map { "\($0.id) \($0.ts) \($0.status)" })")
        #expect(store.allyLogHasMore["al-family"] == false)
        #expect(store.pendingAllyDrafts.isEmpty)
        // The ordinary demo conversation is untouched.
        #expect(store.messages.count == 9 && !store.messages.contains { $0.kind == .ally })
    }

    @Test func aMessageInAndADraftOutAppearInTheConversation() async throws {
        let (store, host) = await demoStore()
        await host.applyScenario("allies")
        #expect(await until { store.messages.filter { $0.kind == .ally }.count == 2 && store.pendingAllyDrafts.count == 1 })
        let incoming = try #require(store.messages.first { $0.kind == .ally && $0.dir == .incoming })
        #expect(incoming.allyName == "家人" && incoming.text.contains("公园") && incoming.role == .system)
        #expect(store.allyEntry(id: incoming.entryId!)?.status == .delivered)
        let draft = try #require(store.pendingAllyDrafts.first)
        #expect(draft.allyId == "al-family" && draft.slots?.count == 2)
        // Its card has a place in the conversation, so nothing waits at the end.
        #expect(store.messages.contains { $0.entryId == draft.id && $0.dir == .outgoing })
        #expect(store.unanchoredPendingDrafts.isEmpty)
        // The list's last line is the newest exchange, the draft included (§7.6).
        #expect(store.ally(id: "al-family")?.lastEntry?.id == draft.id)
    }

    @Test func sendingADraftGoesQueuedThenDeliveredThenSeen() async throws {
        let (store, host) = await demoStore()
        await host.makeDraft(to: "al-family", text: "今晚我晚点回，大概九点。")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        let draft = store.pendingAllyDrafts[0]
        try await store.send(draft: draft)
        #expect(store.pendingAllyDrafts.isEmpty)
        #expect(await until { store.allyEntry(id: draft.id)?.status == .seen })
        #expect(store.ally(id: "al-family")?.lastEntry?.id == draft.id)
        #expect(await host.lastParams["ally.draft.decide"] == ["id": .string(draft.id), "action": "send"])
    }

    @Test func toSomeoneOfflineItWaitsInTheQueue() async throws {
        let (store, host) = await demoStore()
        await host.makeDraft(to: "al-lin", text: "资料收到了吗？")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        try await store.send(draft: store.pendingAllyDrafts[0])
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.allyLog("al-lin").last?.status == .queued, "\(store.allyLog("al-lin").map { "\($0.id) \($0.ts) \($0.status)" })")
    }

    @Test func editedWordsGoOutInsteadOfTheDraft() async throws {
        let (store, host) = await demoStore()
        await host.makeDraft(to: "al-family", text: "今晚晚点回")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        let draft = store.pendingAllyDrafts[0]
        try await store.send(draft: draft, text: "  今晚九点到家  ")
        let sent = try #require(store.allyEntry(id: draft.id))
        #expect(sent.text == "今晚九点到家" && sent.status != .draft)
        // One call: send with the changed words (§7.6).
        #expect(await host.lastParams["ally.draft.decide"] == ["id": .string(draft.id), "action": "send", "text": "今晚九点到家"])
        // Unchanged words: just 发送.
        await host.makeDraft(to: "al-family", text: "好的")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        let second = store.pendingAllyDrafts[0]
        try await store.send(draft: second, text: "好的")
        #expect(await host.lastParams["ally.draft.decide"] == ["id": .string(second.id), "action": "send"])
        #expect(await host.requestLog.filter { $0 == "ally.draft.decide" }.count == 2)
    }

    @Test func notSendingMarksItRejected() async throws {
        let (store, host) = await demoStore()
        await host.makeDraft(to: "al-family", text: "算了")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        let draft = store.pendingAllyDrafts[0]
        try await store.decide(draft, .discard)
        #expect(store.allyEntry(id: draft.id)?.status == .rejected)
        #expect(store.allyEntry(id: draft.id)?.note == "没发")
        #expect(store.pendingAllyDrafts.isEmpty)
        #expect(store.ally(id: "al-family")?.lastEntry?.status == .rejected)
    }

    @Test func aDecisionTheComputerRefusesIsPutBack() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let draft = AllyEntry(id: "e9", allyId: "a", dir: .outgoing, ts: 5, text: "好", status: .draft)
        store.apply(event: RPCEventName.allyEntry, data: ["allyId": "a", "entry": try JSONValue.from(draft)])
        let sending = Task { try await store.decide(draft, .send) }
        #expect(await until { host.request("ally.draft.decide") != nil })
        #expect(store.allyEntry(id: "e9")?.status == .queued) // at once
        host.transport.deliver(json: ["id": .number(Double(host.request("ally.draft.decide")!.id)),
                                      "error": ["message": "草稿过期了"]])
        await #expect(throws: RPCError.remote("草稿过期了")) { _ = try await sending.value }
        #expect(store.allyEntry(id: "e9")?.status == .draft)
        #expect(store.pendingAllyDrafts.map(\.id) == ["e9"])
    }

    @Test func changedWordsGoWithTheSend() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let draft = AllyEntry(id: "e1", allyId: "a", dir: .outgoing, ts: 5, text: "原话", status: .draft)
        store.apply(event: RPCEventName.allyEntry, data: ["entry": try JSONValue.from(draft)])
        #expect(store.allyLog("a").map(\.id) == ["e1"]) // the entry says whose it is
        let sending = Task { try await store.send(draft: draft, text: "新的话") }
        #expect(await until { host.request("ally.draft.decide") != nil })
        let req = host.request("ally.draft.decide")!
        #expect(req.params == ["id": "e1", "action": "send", "text": "新的话"])
        #expect(store.allyEntry(id: "e1")?.text == "新的话" && store.allyEntry(id: "e1")?.status == .queued) // at once
        host.respond(req.id, ["entry": ["id": "e1", "allyId": "a", "dir": "out", "ts": 5, "text": "新的话", "urgent": false, "status": "sent"]])
        try await sending.value
        #expect(host.requests.filter { $0.method == "ally.draft.decide" }.count == 1)
        #expect(store.allyEntry(id: "e1")?.status == .sent)
    }

    @Test func aHostWithoutAlliesHidesThem() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { host.request("ally.list") != nil })
        host.transport.deliver(json: ["id": .number(Double(host.request("ally.list")!.id)),
                                      "error": ["message": "unknown method ally.list"]])
        #expect(await until { store.alliesSupported == false })
        #expect(store.allies.isEmpty)
    }

    @Test func anEntryWithoutItsAllyFindsItLater() async throws {
        let (store, host) = await demoStore()
        // A status change for an exchange already held: the store knows whose it is.
        store.apply(event: RPCEventName.allyEntry,
                    data: ["id": "seed-7", "dir": "out", "ts": 1, "text": "明天的资料发你邮箱了，记得看一下。", "urgent": false, "status": "delivered"])
        #expect(store.allyLog("al-lin").first { $0.id == "seed-7" }?.status == .delivered)
        // A new one: held aside, still counted as a draft, placed once a log has it.
        store.apply(event: RPCEventName.allyEntry,
                    data: ["id": "x1", "dir": "out", "ts": 2, "text": "新草稿", "urgent": false, "status": "draft"])
        #expect(store.pendingAllyDrafts.map(\.id) == ["x1"])
        #expect(store.unanchoredPendingDrafts.map(\.id) == ["x1"]) // no message shows it: the live end does
        #expect(store.allyID(ofEntry: "x1") == nil)
        _ = host
    }

    @Test func listUpdates() async throws {
        let (store, _) = await demoStore()
        var lin = try #require(store.ally(id: "al-lin"))
        lin.online = true
        store.apply(event: RPCEventName.allyUpdated, data: ["ally": try JSONValue.from(lin)])
        #expect(store.ally(id: "al-lin")?.online == true)
        store.apply(event: RPCEventName.allyUpdated, data: ["removed": "al-lin"])
        #expect(store.allies.map(\.id) == ["al-family"])
        store.apply(event: RPCEventName.allyUpdated, data: [:]) // unclear: asks for the list again
        #expect(await until { store.allies.count == 2 })
    }

    @Test func acceptingAnInviteAddsThemAndRemovingTakesThemAway() async throws {
        let (store, host) = await demoStore()
        let invite = try await store.inviteAlly()
        #expect(AllyInviteLink.parse(invite.link)?.name == "小明")
        #expect(invite.expiresAt > Date().epochMillis + 9 * 60_000)
        let added = try #require(try await store.acceptAlly(link: invite.link, kind: .mine))
        #expect(added.kind == .mine && added.ownerName == "小明")
        #expect(store.allies.count == 3)
        #expect(await host.lastParams["ally.accept"]?["kind"] == "mine")

        // A draft to someone who is then removed can't go out any more.
        await host.makeDraft(to: added.id, text: "你好")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        try await store.removeAlly(id: added.id)
        #expect(store.ally(id: added.id) == nil)
        #expect(store.pendingAllyDrafts.isEmpty)
    }

    @Test func anExpiredInviteIsRefusedInPlainWords() async throws {
        let (store, _) = await demoStore()
        let old = "paloally://ally?daemon=d&code=1&name=x&exp=1000"
        await #expect(throws: RPCError.remote("二维码过期了，请对方重新生成一个")) { try await store.acceptAlly(link: old, kind: .family) }
    }

    @Test func askingTheAssistantToPassSomethingOnMakesADraft() async throws {
        let (store, _) = await demoStore()
        store.send("跟家人说：今晚我晚点回，大概九点。")
        #expect(await until { store.pendingAllyDrafts.count == 1 })
        let draft = store.pendingAllyDrafts[0]
        #expect(draft.text == "今晚我晚点回，大概九点。" && draft.allyId == "al-family")
        #expect(await until { store.messages.last?.entryId == draft.id })
        store.send("跟小林约个时间")
        #expect(await until { store.pendingAllyDrafts.count == 2 })
        #expect(store.pendingAllyDrafts[1].allyId == "al-lin" && store.pendingAllyDrafts[1].slots?.count == 2)
    }
}
