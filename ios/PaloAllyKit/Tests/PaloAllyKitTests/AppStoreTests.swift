import Foundation
import Testing
@testable import PaloAllyKit

@MainActor
func until(_ timeout: Double = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Which observation callbacks fired (they may run on any thread).
final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    func set(_ n: String) { lock.withLock { _ = names.insert(n) } }
    func has(_ n: String) -> Bool { lock.withLock { names.contains(n) } }
}

/// A host that only auto-answers hello/sync; everything else waits for the
/// test to answer. Lets tests control ordering precisely.
final class ManualHost: @unchecked Sendable {
    let transport = InMemoryTransport()
    private let lock = NSLock()
    private var _requests: [(id: Int, method: String, params: JSONValue)] = []
    var syncResult: SyncResult = SyncResult(seq: 0, messages: [])

    init() {
        transport.onSend = { [weak self] data in self?.receive(data) }
    }

    var requests: [(id: Int, method: String, params: JSONValue)] { lock.withLock { _requests } }

    func receive(_ data: Data) {
        guard case .request(let id, let method, let params)? = WireMessage.parse(data) else { return }
        lock.withLock { _requests.append((id, method, params)) }
        switch method {
        case "hello": respond(id, ["hostName": "Mac", "version": "1"])
        case "sync": respond(id, (try? JSONValue.from(syncResult)) ?? .null)
        default: break
        }
    }

    func respond(_ id: Int, _ result: JSONValue) {
        transport.deliver(json: ["id": .number(Double(id)), "result": result])
    }

    func event(_ name: String, _ data: JSONValue) {
        transport.deliver(json: ["event": .string(name), "data": data])
    }

    func request(_ method: String) -> (id: Int, method: String, params: JSONValue)? {
        requests.last { $0.method == method }
    }
}

@MainActor
@Suite("AppStore")
struct AppStoreTests {
    func demoStore(seeded: Bool = true) async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, seeded: seeded)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online }
        return (store, host)
    }

    @Test func initialSyncPopulatesEverything() async throws {
        let (store, host) = await demoStore()
        #expect(store.connection == .online)
        #expect(store.hostName == "我的 MacBook")
        #expect(store.messages.count == 9)
        #expect(store.messages.map(\.seq) == Array(1...9))
        #expect(store.lastSeq == 9)
        #expect(store.tasks.count == 3)
        #expect(store.pendingQuestions.map(\.id) == ["q1"])
        #expect(store.tasks.first?.isActive == true) // active tasks sort first
        #expect(store.pendingApprovals.map(\.id).sorted() == ["a1", "a2"])
        #expect(store.watches.count == 8)
        // goals in each state, with progress lines
        #expect(Set(store.watches.map(\.state)) == [.waiting, .tracking, .done, .paused])
        #expect(store.watches.first { $0.id == "w6" }?.progress == "每天比价，现在最低 ¥4,860")
        #expect(store.pinnedArtifacts.map(\.id) == ["ar1"])
        #expect(store.recentArtifacts.map(\.id) == ["ar2", "ar3"])
        #expect(store.settings?.probeIntervalMinutes == 10)
        #expect(store.status?.model == "glm-4.6")
        // hello + sync first; 「试试」 suggestions load right after
        #expect(await until { await host.requestLog == ["hello", "sync", "suggestions.list"] })
        #expect(await host.lastParams["sync"]?["sinceSeq"] == nil)
        #expect(await host.lastParams["hello"]?["client"] == "ios")
        // a1 is anchored by a chat message; a2 is not.
        #expect(store.unanchoredPendingApprovals.map(\.id) == ["a2"])
    }

    @Test func sendShowsEchoThenServerMessageAndStreamedReply() async throws {
        let (store, host) = await demoStore()
        store.send("  你好呀  ")
        // Echo is immediate (before any network round trip).
        let echo = try #require(store.messages.last)
        #expect(echo.text == "你好呀")
        #expect(echo.seq == 0)
        #expect(echo.delivery == .sending)
        #expect(store.awaitingReply)

        #expect(await until { store.messages.count == 11 && !store.isBusy })
        let user = store.messages[9]
        let reply = store.messages[10]
        #expect(user.role == .user && user.seq == 10 && user.id == "m10" && user.delivery == .sent)
        #expect(reply.role == .assistant && reply.seq == 11 && !reply.isStreaming)
        #expect(reply.text.contains("我记下了"))
        #expect(store.lastSeq == 11)
        #expect(!store.awaitingReply)
        #expect(store.messages.filter { $0.text == "你好呀" }.count == 1)
        #expect(await host.lastParams["chat.send"]?["clientMsgId"] == .string(echo.clientMsgId!))
    }

    @Test func liveClipboardMessageIsCopiedButSyncedOneIsNot() async throws {
        let host = ManualHost()
        host.syncResult = SyncResult(seq: 1, messages: [
            ChatMessage(seq: 1, id: "c-old", role: .assistant, kind: .clipboard, text: "旧的验证码", ts: 1),
        ])
        let store = AppStore(transport: host.transport)
        var copied: [String] = []
        store.clipboardWriter = { copied.append($0); return true }
        store.start()
        #expect(await until { store.connection == .online && store.messages.count == 1 })
        #expect(copied.isEmpty) // history never copies
        host.event("chat.message", ["seq": 2, "id": "c-new", "role": "assistant", "kind": "clipboard",
                                    "text": "123456", "label": "验证码", "channel": "app", "ts": 2])
        #expect(await until { store.messages.count == 2 })
        #expect(copied == ["123456"])
        #expect(store.copiedClipboardIDs == ["c-new"])
        #expect(store.messages.last?.label == "验证码")
        // a re-delivered copy of the same message doesn't copy again
        host.event("chat.message", ["seq": 2, "id": "c-new", "role": "assistant", "kind": "clipboard",
                                    "text": "123456", "channel": "app", "ts": 2])
        try await Task.sleep(for: .milliseconds(50))
        #expect(copied == ["123456"])
    }

    @Test func answeringAQuestionSendsTheChoicesAndResolvesTheCard() async throws {
        let (store, host) = await demoStore()
        let q = try #require(store.question(id: "q1"))
        #expect(store.messages.contains { $0.kind == .question && $0.questionId == "q1" })
        try await store.answer(q, answers: ["周五晚上几个人？": "两个人", "想吃什么？": "日料, 西餐"])
        #expect(store.question(id: "q1")?.status == .answered)
        #expect(store.pendingQuestions.isEmpty)
        let sent = await host.lastParams["question.answer"]
        #expect(sent?["answers"]?["想吃什么？"]?.stringValue == "日料, 西餐")
        // every question needs an answer: the host refuses and the card rolls back
        let (store2, _) = await demoStore()
        let q2 = try #require(store2.question(id: "q1"))
        await #expect(throws: (any Error).self) { try await store2.answer(q2, answers: ["周五晚上几个人？": "两个人"]) }
        #expect(store2.question(id: "q1")?.status == .pending)
    }

    @Test func emptySendIgnored() async {
        let (store, _) = await demoStore()
        store.send("   \n ")
        #expect(store.messages.count == 9)
    }

    @Test func deltasMergeIntoStreamingMessageAndFinalize() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.event("chat.delta", ["id": "r1", "text": "今天"])
        host.event("chat.delta", ["id": "r1", "text": "天气"])
        #expect(await until { store.messages.first.map(store.liveText) == "今天天气" })
        // While it's written, the text lives in the reply's own object, not in `messages`.
        #expect(store.stream(for: "r1")?.text == "今天天气")
        #expect(store.messages.count == 1)
        #expect(store.messages[0].isStreaming)
        #expect(store.messages[0].seq == 0)
        #expect(store.isBusy)
        host.event("chat.message", ["seq": 1, "id": "r1", "role": "assistant", "kind": "text", "text": "今天天气不错", "channel": "app", "ts": 1])
        #expect(await until { store.messages.first?.isStreaming == false })
        #expect(store.messages[0].text == "今天天气不错")
        #expect(store.messages[0].seq == 1)
        #expect(store.lastSeq == 1)
        // Late delta after the final message is ignored.
        host.event("chat.delta", ["id": "r1", "text": "!!!"])
        host.event("status", ["busy": false])
        #expect(await until { store.status?.busy == false })
        #expect(store.messages[0].text == "今天天气不错")
    }

    // MARK: reconnecting mid-reply (sync's `streaming`)

    @Test func syncMidReplyStartsTheReplyAndLaterDeltasAppend() async throws {
        let host = ManualHost()
        host.syncResult = SyncResult(seq: 0, messages: [], status: HostStatus(online: true, busy: true),
                                     streaming: .init(id: "r1", text: "写到一半"))
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        #expect(store.messages.map(\.id) == ["r1"])
        #expect(store.liveText(store.messages[0]) == "写到一半")
        #expect(store.messages[0].isStreaming)
        host.event("chat.delta", ["id": "r1", "text": "，接着写"])
        #expect(await until { store.messages.first.map(store.liveText) == "写到一半，接着写" })
        host.event("chat.message", ["seq": 1, "id": "r1", "role": "assistant", "kind": "text", "text": "写到一半，接着写完了", "channel": "app", "ts": 1])
        #expect(await until { store.messages.first?.isStreaming == false })
        #expect(store.messages.map(\.text) == ["写到一半，接着写完了"])
    }

    @Test func syncMidReplyReplacesTheTextWeHad() async throws {
        let host = ManualHost()
        host.syncResult = SyncResult(seq: 1, messages: [ChatMessage(seq: 1, id: "u1", role: .user, text: "写点东西", ts: 1)],
                                     status: HostStatus(online: true, busy: true))
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.event("chat.delta", ["id": "r1", "text": "写到"])
        #expect(await until { store.messages.last.map(store.liveText) == "写到" })
        // The link drops; the deltas sent meanwhile never arrive.
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        host.syncResult = SyncResult(seq: 1, messages: [], status: HostStatus(online: true, busy: true),
                                     streaming: .init(id: "r1", text: "写到一半了"))
        await host.transport.simulateConnect()
        #expect(await until { store.connection == .online })
        #expect(store.messages.map(\.id) == ["u1", "r1"])
        #expect(store.liveText(store.messages[1]) == "写到一半了")
        #expect(store.messages[1].isStreaming)
        host.event("chat.delta", ["id": "r1", "text": "，快写完了"])
        #expect(await until { store.messages.last.map(store.liveText) == "写到一半了，快写完了" })
    }

    @Test func syncStreamingForAFinishedReplyIsIgnored() async throws {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.receive(ChatMessage(seq: 1, id: "r1", role: .assistant, text: "写完了", ts: 1))
        store.applySync(SyncResult(seq: 1, messages: [], streaming: .init(id: "r1", text: "写到")), since: 1, eventsBefore: 0)
        #expect(store.messages.map(\.text) == ["写完了"])
        #expect(store.messages[0].isStreaming == false)
    }

    /// The sync answer and the deltas reach the main actor by different
    /// paths: a delta the host sent after answering can be applied first,
    /// and one it sent before can come after. Either way each piece of text
    /// shows exactly once, in order.
    @Test func syncTextAndDeltasThatOvertookItMergeInOrder() async throws {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        func delta(_ text: String, _ index: Int) {
            store.apply(event: "chat.delta", data: ["id": "r1", "text": .string(text)], index: index)
        }
        delta("写到", 1)
        store.syncing = true
        delta("一半", 2)     // sent before the host answered: in its text
        delta("，然后", 3)   // sent after it answered, but here first
        store.applySync(SyncResult(seq: 0, messages: [], streaming: .init(id: "r1", text: "写到一半")),
                        since: 0, eventsBefore: 2)
        store.syncing = false
        delta("再写", 4)
        store.flushDeltas()
        #expect(store.messages.map(store.liveText) == ["写到一半，然后再写"])

        // The other way round: the answer first, then a delta it already holds.
        let other = AppStore(transport: InMemoryTransport(autoConnect: false))
        other.apply(event: "chat.delta", data: ["id": "r2", "text": "写到"], index: 1)
        other.syncing = true
        other.applySync(SyncResult(seq: 0, messages: [], streaming: .init(id: "r2", text: "写到一半")),
                        since: 0, eventsBefore: 2)
        other.syncing = false
        other.apply(event: "chat.delta", data: ["id": "r2", "text": "一半"], index: 2)
        other.apply(event: "chat.delta", data: ["id": "r2", "text": "，然后"], index: 3)
        other.flushDeltas()
        #expect(other.messages.map(other.liveText) == ["写到一半，然后"])
    }

    @Test func syncResultDecodesStreaming() throws {
        let json: JSONValue = ["seq": 3, "messages": [], "streaming": ["id": "r9", "text": "写到一半"]]
        let r = try json.decode(SyncResult.self)
        #expect(r.streaming == SyncResult.Streaming(id: "r9", text: "写到一半"))
        let none = try (["seq": 3, "messages": []] as JSONValue).decode(SyncResult.self)
        #expect(none.streaming == nil)
    }

    /// Deltas change only the reply's own object: views that read
    /// `messages` (the list, every other row) don't update with each one.
    @Test func streamingDoesNotChangeMessages() async throws {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.apply(event: "chat.delta", data: ["id": "r1", "text": "今天"])
        let changes = Flags()
        withObservationTracking { _ = store.messages } onChange: { changes.set("messages") }
        withObservationTracking { _ = store.stream(for: "r1")?.text } onChange: { changes.set("text") }
        for piece in ["天气", "不错，", "适合出门"] {
            store.apply(event: "chat.delta", data: ["id": "r1", "text": .string(piece)])
        }
        store.flushDeltas()
        #expect(!changes.has("messages"))
        #expect(changes.has("text"))
        #expect(store.liveText(store.messages[0]) == "今天天气不错，适合出门")
        // Finished: the text moves into the message, the reply object goes.
        store.receive(ChatMessage(seq: 1, id: "r1", role: .assistant, text: "今天天气不错，适合出门。", ts: 1))
        #expect(changes.has("messages"))
        #expect(store.messages[0].text == "今天天气不错，适合出门。")
        #expect(store.stream(for: "r1") == nil)
        #expect(store.latestStream == nil)
    }

    /// The host numbers a reply when it ends, after whatever arrived while it
    /// was written; shown last while written, it doesn't jump when finished.
    @Test func broadcastBeforeSendResponseMergesByClientMsgId() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        store.send("在吗")
        #expect(await until { host.request("chat.send") != nil })
        let req = try #require(host.request("chat.send"))
        let cid = try #require(req.params["clientMsgId"]?.stringValue)
        // Broadcast lands first, carrying clientMsgId.
        host.event("chat.message", ["seq": 1, "id": "srv-1", "role": "user", "text": "在吗", "channel": "app", "ts": 5, "clientMsgId": .string(cid)])
        #expect(await until { store.messages.first?.id == "srv-1" })
        host.respond(req.id, ["id": "srv-1", "seq": 1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.count == 1)
        #expect(store.messages[0].delivery == .sent)
        #expect(store.lastSeq == 1)
    }

    @Test func quotedReplyGoesWithTheNextMessageOnly() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let earlier = ChatMessage(seq: 1, id: "srv-a", role: .assistant, text: "周四下午 3 点开会", ts: 1)
        store.quote(earlier, excerpt: "3 点开会")
        #expect(store.replyDraft == ReplyTo(messageId: "srv-a", excerpt: "3 点开会"))
        store.send("改到周五")
        #expect(store.replyDraft == nil)
        #expect(store.messages.last?.replyTo?.excerpt == "3 点开会")
        #expect(await until { host.request("chat.send") != nil })
        let req = try #require(host.request("chat.send"))
        #expect(req.params["replyTo"]?["messageId"]?.stringValue == "srv-a")
        #expect(req.params["replyTo"]?["excerpt"]?.stringValue == "3 点开会")
        // A 「试试」 chip doesn't take the open quote with it.
        store.quote(earlier)
        store.send("找出没在用的订阅", suggestionId: "sg_1")
        #expect(store.replyDraft != nil)
    }

    @Test func broadcastWithoutClientMsgIdMergesByText() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        store.send("同一句话")
        #expect(await until { host.request("chat.send") != nil })
        let req = try #require(host.request("chat.send"))
        host.event("chat.message", ["seq": 1, "id": "srv-9", "role": "user", "text": "同一句话", "channel": "app", "ts": 5])
        #expect(await until { store.messages.first?.id == "srv-9" })
        host.respond(req.id, ["id": "srv-9", "seq": 1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.count == 1)
    }

    @Test func responseBeforeBroadcastDedupesById() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        store.send("先回包")
        #expect(await until { host.request("chat.send") != nil })
        host.respond(host.request("chat.send")!.id, ["id": "s1", "seq": 1])
        #expect(await until { store.messages.first?.id == "s1" })
        host.event("chat.message", ["seq": 1, "id": "s1", "role": "user", "text": "先回包", "channel": "app", "ts": 5])
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.count == 1)
        #expect(store.lastSeq == 1)
    }

    @Test func failedSendMarksEchoAndRetryWorks() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        store.send("断网了")
        #expect(await until { store.messages.first?.delivery == .queued })
        #expect(!store.awaitingReply)
        let cid = store.messages[0].clientMsgId
        await host.transport.simulateConnect()
        #expect(await until { store.connection == .online })
        // Queued while offline → resent automatically, same clientMsgId.
        #expect(await until { host.request("chat.send") != nil })
        #expect(store.messages[0].delivery == .sending)
        #expect(host.request("chat.send")?.params["clientMsgId"]?.stringValue == cid)
        host.respond(host.request("chat.send")!.id, ["id": "s1", "seq": 1])
        #expect(await until { store.messages.first?.delivery == .sent })
    }

    @Test func gapTriggersResyncFromLastSeq() async throws {
        let (store, host) = await demoStore()
        #expect(store.lastSeq == 9)
        await host.post("漏掉的 1", broadcast: false)
        await host.post("漏掉的 2", broadcast: false)
        await host.post("看到的 3") // seq 12 broadcast → gap (expected 10)
        #expect(await until { store.lastSeq == 12 })
        #expect(store.messages.map(\.seq) == Array(1...12))
        #expect(await host.lastParams["sync"]?["sinceSeq"] == .number(9))
        #expect(await host.requestLog.filter { $0 == "sync" }.count == 2)
    }

    @Test func reconnectSyncsSinceLastSeqAndPages() async throws {
        let (store, host) = await demoStore(seeded: false)
        #expect(store.lastSeq == 0)
        for i in 1...100 { await host.post("m\(i)") }
        #expect(await until { store.lastSeq == 100 })

        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        for i in 101...1200 { await host.post("m\(i)", broadcast: false) }
        let roundsBefore = store.syncRounds
        await host.transport.simulateConnect()
        #expect(await until(5) { store.connection == .online })
        #expect(store.lastSeq == 1200)
        #expect(store.messages.count == 1200)
        #expect(store.syncRounds - roundsBefore == 3) // 500 + 500 + 100
        #expect(Set(store.messages.map(\.id)).count == 1200)
        #expect(await host.lastParams["sync"]?["sinceSeq"] == .number(1100))
    }

    @Test func freshSyncKeepsUnsentEchoes() async throws {
        let host = ManualHost()
        host.syncResult = SyncResult(seq: 2, messages: [
            ChatMessage(seq: 1, id: "a", role: .user, text: "1", ts: 1),
            ChatMessage(seq: 2, id: "b", role: .assistant, text: "2", ts: 2),
        ])
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        #expect(store.messages.map(\.id) == ["a", "b"])
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        store.send("离线时说的")
        #expect(await until { store.messages.last?.delivery == .queued })
        // A fresh snapshot (as after re-pair) must not drop the failed echo.
        store.applySync(host.syncResult, since: nil)
        #expect(store.messages.map(\.text) == ["1", "2", "离线时说的"])
    }

    @Test func aFreshSnapshotEndsTheReplyItFinished() async throws {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.receive(ChatMessage(seq: 1, id: "u1", role: .user, text: "写点东西", ts: 1))
        store.apply(event: "chat.delta", data: ["id": "r1", "text": "写到"])
        #expect(store.stream(for: "r1") != nil)
        _ = store.applySync(SyncResult(seq: 2, messages: [
            ChatMessage(seq: 1, id: "u1", role: .user, text: "写点东西", ts: 1),
            ChatMessage(seq: 2, id: "r1", role: .assistant, text: "写完了", ts: 2),
        ]), since: nil)
        #expect(store.stream(for: "r1") == nil)
        #expect(store.latestStream == nil)
        #expect(store.messages.map(\.text) == ["写点东西", "写完了"])
    }

    @Test func entityEventsApply() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.event("task.updated", ["id": "t1", "title": "订票", "summary": "进行中", "status": "running", "createdAt": 1, "updatedAt": 1])
        host.event("task.updated", ["id": "t1", "title": "订票", "summary": "好了", "status": "done", "createdAt": 1, "updatedAt": 2])
        host.event("approval.updated", ["id": "a1", "tool": "send", "title": "发邮件", "detail": "", "careful": true, "status": "pending", "createdAt": 1])
        host.event("watch.updated", ["watch": ["id": "w1", "title": "晨报", "kind": "schedule", "at": ["08:30"], "enabled": true]])
        host.event("watch.updated", ["watch": ["id": "w2", "title": "x", "kind": "check", "intervalMinutes": 30]])
        host.event("watch.updated", ["removed": "w2"])
        host.event("artifact.updated", ["id": "ar1", "title": "晨报", "type": "markdown", "mainFile": "a.md", "pinned": true, "updatedAt": 5])
        host.event("settings.updated", ["timezone": "UTC", "quietHours": nil, "probeIntervalMinutes": 5, "approvalTimeoutMinutes": 10, "wechatProactive": "full"])
        host.event("status", ["online": true, "busy": false, "model": "m", "wechat": "off", "version": "2"])
        host.event("some.future.event", ["x": 1])
        #expect(await until { store.status?.version == "2" })
        #expect(store.tasks.count == 1 && store.tasks[0].status == .done && store.tasks[0].summary == "好了")
        #expect(store.pendingApprovals.map(\.id) == ["a1"])
        #expect(store.watches.map(\.id) == ["w1"])
        #expect(store.pinnedArtifacts.map(\.id) == ["ar1"])
        #expect(store.settings?.probeIntervalMinutes == 5)
        #expect(store.settings?.quietHours == nil)
        #expect(store.settings?.wechatProactive == .full)
        #expect(store.status?.model == "m")
    }

    @Test func approvalAnswerSendsRememberOnlyWhenNotCareful() async throws {
        let (store, host) = await demoStore()
        let a2 = try #require(store.approval(id: "a2"))
        try await store.answer(a2, allow: true, remember: true)
        #expect(store.approval(id: "a2")?.status == .allowed)
        #expect(await host.lastParams["approval.answer"]?["remember"] == .bool(true))

        let a1 = try #require(store.approval(id: "a1"))
        #expect(a1.careful)
        try await store.answer(a1, allow: false, remember: true)
        #expect(store.approval(id: "a1")?.status == .denied)
        let p = await host.lastParams["approval.answer"]
        #expect(p?["remember"] == nil)
        #expect(p?["allow"] == .bool(false))
        #expect(store.pendingApprovals.isEmpty)
    }

    @Test func watchCrud() async throws {
        let (store, host) = await demoStore()
        let w = try #require(try await store.addWatch(WatchDraft(title: "喝水", kind: .check, instruction: "提醒喝水", intervalMinutes: 60)))
        #expect(store.watches.contains { $0.id == w.id })
        try await store.setWatch(w, enabled: false)
        #expect(store.watches.first { $0.id == w.id }?.enabled == false)
        #expect(await host.lastParams["watch.update"]?["patch"]?["enabled"] == .bool(false))
        var edited = WatchDraft(w)
        edited.kind = .schedule
        edited.intervalMinutes = nil
        edited.at = ["09:00"]
        try await store.updateWatch(id: w.id, patch: AppStore.watchPatch(from: edited))
        let after = try #require(store.watches.first { $0.id == w.id })
        #expect(after.kind == .schedule && after.at == ["09:00"] && after.intervalMinutes == nil)
        // monthly on the last day, then back to every day (an explicit null clears it)
        edited.dayOfMonth = -1
        try await store.updateWatch(id: w.id, patch: AppStore.watchPatch(from: edited))
        #expect(await host.lastParams["watch.update"]?["patch"]?["dayOfMonth"] == .number(-1))
        #expect(store.watches.first { $0.id == w.id }?.dayOfMonth == -1)
        edited.dayOfMonth = nil
        try await store.updateWatch(id: w.id, patch: AppStore.watchPatch(from: edited))
        #expect(await host.lastParams["watch.update"]?["patch"]?["dayOfMonth"] == .null)
        #expect(store.watches.first { $0.id == w.id }?.dayOfMonth == nil)
        try await store.removeWatch(id: w.id)
        #expect(!store.watches.contains { $0.id == w.id })
    }

    @Test func artifactReadFollowsChunks() async throws {
        let (store, host) = await demoStore()
        let big = Data((0..<(700 * 1024)).map { UInt8($0 % 251) })
        await host.addArtifact(Artifact(id: "big", title: "大文件", type: "pdf", mainFile: "x.pdf", updatedAt: 1,
                                        files: [ArtifactFile(path: "x.pdf", size: Int64(big.count))]), files: ["x.pdf": big])
        #expect(await until { store.artifact(id: "big") != nil })
        let r = try await store.readArtifact(id: "big")
        #expect(r.data == big)
        #expect(r.mime == "application/pdf")
        #expect(await host.requestLog.filter { $0 == "artifact.read" }.count == 3)
        let md = try await store.readArtifact(id: "ar1")
        #expect(String(data: md.data, encoding: .utf8)?.contains("今日晨报") == true)
        try await store.setPinned(store.artifact(id: "ar2")!, true)
        #expect(store.pinnedArtifacts.map(\.id).contains("ar2"))
    }

    @Test func memoryRoundTrip() async throws {
        let (store, _) = await demoStore()
        let files = try await store.memoryFiles()
        #expect(files.first?.scope == .core)
        let before = try await store.readMemory(path: "user.md")
        #expect(before.updatedAt != nil)
        let stamp = try await store.writeMemory(path: "user.md", content: "# 新的我", baseUpdatedAt: before.updatedAt)
        let after = try await store.readMemory(path: "user.md")
        #expect(after.content == "# 新的我")
        // The stamp memory.write returns is the next base: saving again works.
        #expect(stamp == after.updatedAt)
        try await store.writeMemory(path: "user.md", content: "# 再改一次", baseUpdatedAt: stamp)
    }

    @Test func settingsStopAndPush() async throws {
        let (store, host) = await demoStore()
        try await store.updateSettings(patch: ["quietHours": nil, "probeIntervalMinutes": 3])
        #expect(store.settings?.quietHours == nil)
        #expect(store.settings?.probeIntervalMinutes == 3)
        try await store.stop()
        #expect(await host.requestLog.contains("stop"))
        #expect(store.status?.busy == false)
        #expect(await until { store.tasks.allSatisfy { !$0.isActive } })
        // Nothing stays blocked: the next message gets a reply as usual.
        store.send("你好")
        #expect(await until { store.messages.last?.role == .assistant && store.messages.last?.isStreaming == false })

        store.registerPush(token: Data([0xde, 0xad, 0xbe, 0xef]), environment: .sandbox)
        _ = await until { await host.pushTokens == ["deadbeef"] }
        #expect(await host.pushTokens == ["deadbeef"])
        // Re-registered after reconnect.
        host.transport.simulateDisconnect()
        await host.transport.simulateConnect()
        _ = await until { await host.pushTokens.count == 2 }
        #expect(await host.pushTokens.count == 2)
        #expect(await host.lastParams["push.register"]?["env"] == "sandbox")
    }

    @Test func taskDetailAndStop() async throws {
        let (store, _) = await demoStore()
        let d = try await store.taskDetail(id: "t1")
        #expect(d.task?.id == "t1")
        #expect(d.activity.count >= 4)
        try await store.stopTask(id: "t2")
        #expect(await until { store.task(id: "t2")?.status == .stopped })
    }

    @Test func taskRequestCreatesTaskAndCompletes() async throws {
        let (store, _) = await demoStore()
        store.send("帮我整理一下照片")
        #expect(await until(5) { store.tasks.contains { $0.title.contains("整理一下照片") && $0.status == .done } })
        #expect(store.messages.last?.kind == .task)
    }

    @Test func loadOlderHistory() async throws {
        let host = DemoHost(speed: 0, seeded: false)
        for i in 1...150 { await host.post("m\(i)", broadcast: false) }
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        #expect(store.messages.count == 100)
        #expect(store.messages.first?.seq == 51)
        #expect(store.hasOlderMessages)
        await store.loadOlder(limit: 50)
        #expect(store.messages.count == 150)
        #expect(store.messages.map(\.seq) == Array(1...150))
        #expect(!store.hasOlderMessages)
    }

    @Test func disconnectFailsPendingAndUpdatesConnection() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let detail = Task { try await store.taskDetail(id: "x") }
        #expect(await until { host.request("task.get") != nil })
        host.transport.simulateDisconnect(.network("wifi"))
        await #expect(throws: RPCError.disconnected) { _ = try await detail.value }
        #expect(await until { store.connection == .offline("wifi") })
        host.transport.simulateDisconnect(.rejected("unknown device"))
        #expect(await until { store.connection == .rejected("unknown device") })
    }

    @Test func rpcTimeoutAndRemoteError() async throws {
        let host = ManualHost()
        let rpc = RPCClient(transport: host.transport)
        await rpc.start()
        _ = await until { await rpc.isConnected }
        await #expect(throws: RPCError.timeout) {
            _ = try await rpc.callRaw("task.get", params: IDParams(id: "x"), timeout: 0.1)
        }
        #expect(await rpc.pendingCount == 0)
        // A timeout drops the (possibly stale) link and reconnects.
        #expect(await until { host.transport.forcedReconnects == 1 })
        #expect(await until { await rpc.isConnected })
        let r = Task { try await rpc.callRaw("memory.read", params: PathParams(path: "nope")) }
        _ = await until { host.request("memory.read") != nil }
        host.transport.deliver(json: ["id": .number(Double(host.request("memory.read")!.id)), "error": ["message": "没有这个文件"]])
        await #expect(throws: RPCError.remote("没有这个文件")) { _ = try await r.value }
    }

    @Test func requestsGoOutInOrder() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        for i in 0..<20 { store.send("消息 \(i)") }
        #expect(await until { host.requests.filter { $0.method == "chat.send" }.count == 20 })
        let texts = host.requests.filter { $0.method == "chat.send" }.compactMap { $0.params["text"]?.stringValue }
        #expect(texts == (0..<20).map { "消息 \($0)" })
        let ids = host.requests.map(\.id)
        #expect(ids == ids.sorted())
    }
}
