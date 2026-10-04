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
        #expect(store.messages.count == 7)
        #expect(store.messages.map(\.seq) == Array(1...7))
        #expect(store.lastSeq == 7)
        #expect(store.tasks.count == 3)
        #expect(store.tasks.first?.isActive == true) // active tasks sort first
        #expect(store.pendingApprovals.map(\.id).sorted() == ["a1", "a2"])
        #expect(store.watches.count == 4)
        #expect(store.pinnedArtifacts.map(\.id) == ["ar1"])
        #expect(store.recentArtifacts.map(\.id) == ["ar2", "ar3"])
        #expect(store.settings?.maxProactivePerDay == 6)
        #expect(store.status?.model == "glm-4.6")
        #expect(await host.requestLog == ["hello", "sync"])
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

        #expect(await until { store.messages.count == 9 && !store.isBusy })
        let user = store.messages[7]
        let reply = store.messages[8]
        #expect(user.role == .user && user.seq == 8 && user.id == "m8" && user.delivery == .sent)
        #expect(reply.role == .assistant && reply.seq == 9 && !reply.isStreaming)
        #expect(reply.text.contains("我记下了"))
        #expect(store.lastSeq == 9)
        #expect(!store.awaitingReply)
        #expect(store.messages.filter { $0.text == "你好呀" }.count == 1)
        #expect(await host.lastParams["chat.send"]?["clientMsgId"] == .string(echo.clientMsgId!))
    }

    @Test func emptySendIgnored() async {
        let (store, _) = await demoStore()
        store.send("   \n ")
        #expect(store.messages.count == 7)
    }

    @Test func deltasMergeIntoStreamingMessageAndFinalize() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.event("chat.delta", ["id": "r1", "text": "今天"])
        host.event("chat.delta", ["id": "r1", "text": "天气"])
        #expect(await until { store.messages.first?.text == "今天天气" })
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
        #expect(store.lastSeq == 7)
        await host.post("漏掉的 1", broadcast: false)
        await host.post("漏掉的 2", broadcast: false)
        await host.post("看到的 3") // seq 10 broadcast → gap (expected 8)
        #expect(await until { store.lastSeq == 10 })
        #expect(store.messages.map(\.seq) == Array(1...10))
        #expect(await host.lastParams["sync"]?["sinceSeq"] == .number(7))
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

    @Test func entityEventsApply() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.event("task.updated", ["id": "t1", "title": "订票", "summary": "进行中", "status": "running", "createdAt": 1, "updatedAt": 1])
        host.event("task.updated", ["id": "t1", "title": "订票", "summary": "好了", "status": "done", "createdAt": 1, "updatedAt": 2])
        host.event("approval.updated", ["id": "a1", "tool": "send", "title": "发邮件", "detail": "", "irreversible": true, "status": "pending", "createdAt": 1])
        host.event("watch.updated", ["watch": ["id": "w1", "title": "晨报", "kind": "schedule", "at": ["08:30"], "enabled": true]])
        host.event("watch.updated", ["watch": ["id": "w2", "title": "x", "kind": "check", "intervalMinutes": 30]])
        host.event("watch.updated", ["removed": "w2"])
        host.event("artifact.updated", ["id": "ar1", "title": "晨报", "type": "markdown", "mainFile": "a.md", "pinned": true, "updatedAt": 5])
        host.event("settings.updated", ["timezone": "UTC", "quietHours": nil, "maxProactivePerDay": 2, "probeIntervalMinutes": 5, "approvalTimeoutMinutes": 10])
        host.event("status", ["online": true, "killed": true, "busy": false, "model": "m", "wechat": "off", "version": "2"])
        host.event("some.future.event", ["x": 1])
        #expect(await until { store.status?.killed == true })
        #expect(store.tasks.count == 1 && store.tasks[0].status == .done && store.tasks[0].summary == "好了")
        #expect(store.pendingApprovals.map(\.id) == ["a1"])
        #expect(store.watches.map(\.id) == ["w1"])
        #expect(store.pinnedArtifacts.map(\.id) == ["ar1"])
        #expect(store.settings?.maxProactivePerDay == 2)
        #expect(store.settings?.quietHours == nil)
        #expect(store.isKilled)
    }

    @Test func approvalAnswerSendsRememberOnlyWhenReversible() async throws {
        let (store, host) = await demoStore()
        let a2 = try #require(store.approval(id: "a2"))
        try await store.answer(a2, allow: true, remember: true)
        #expect(store.approval(id: "a2")?.status == .allowed)
        #expect(await host.lastParams["approval.answer"]?["remember"] == .bool(true))

        let a1 = try #require(store.approval(id: "a1"))
        #expect(a1.irreversible)
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
        try await store.writeMemory(path: "user.md", content: "# 新的我", baseUpdatedAt: before.updatedAt)
        #expect(try await store.readMemory(path: "user.md").content == "# 新的我")
    }

    @Test func settingsKillResumeAndPush() async throws {
        let (store, host) = await demoStore()
        try await store.updateSettings(patch: ["quietHours": nil, "maxProactivePerDay": 3])
        #expect(store.settings?.quietHours == nil)
        #expect(store.settings?.maxProactivePerDay == 3)
        try await store.kill()
        #expect(store.isKilled)
        #expect(await until { store.tasks.allSatisfy { !$0.isActive } })
        try await store.resume()
        #expect(!store.isKilled)

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
