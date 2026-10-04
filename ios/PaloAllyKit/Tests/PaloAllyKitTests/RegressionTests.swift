import CryptoKit
import Foundation
import Testing
@testable import PaloAllyKit

// Regression tests for issues found in review (dead links, stuck "busy",
// stuck "awaiting reply", offline sends, approvals wording, etc.).

@MainActor
@Suite("Regressions: store")
struct StoreRegressionTests {
    func online(_ host: ManualHost) async -> AppStore {
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online }
        return store
    }

    /// A turn that ends (error / kill) without a final chat.message for the
    /// streamed id must not leave the client busy forever.
    @Test func busyFalseFinalizesStreamingMessages() async throws {
        let host = ManualHost()
        let store = await online(host)
        host.event("status", ["online": true, "killed": false, "busy": true, "activity": "正在想", "model": "", "wechat": "off", "version": "1"])
        host.event("chat.delta", ["id": "m_x", "text": "我先看看"])
        #expect(await until { store.messages.contains { $0.isStreaming } })
        host.event("chat.message", ["seq": 1, "id": "m_n", "role": "system", "kind": "notice", "text": "出了点问题：x", "channel": "system", "ts": 1])
        host.event("status", ["online": true, "killed": false, "busy": false, "model": "", "wechat": "off", "version": "1"])
        #expect(await until { store.isBusy == false })
        #expect(store.messages.filter(\.isStreaming).isEmpty)
        #expect(store.messages.first { $0.id == "m_x" }?.text == "我先看看")
        // A late delta for the finished stream is ignored.
        host.event("chat.delta", ["id": "m_x", "text": "!!!"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.first { $0.id == "m_x" }?.text == "我先看看")
        #expect(!store.isBusy)
    }

    @Test func busyFalseClearsAwaitingReply() async throws {
        let host = ManualHost()
        let store = await online(host)
        store.send("hi")
        #expect(store.awaitingReply)
        host.event("status", ["busy": false])
        #expect(await until { !store.awaitingReply })
    }

    /// Reply lands while disconnected; the reconnect sync delivers it.
    @Test func awaitingReplyClearedBySync() async throws {
        let host = ManualHost()
        let store = await online(host)
        store.send("hi")
        #expect(await until { host.request("chat.send") != nil })
        let req = try #require(host.request("chat.send"))
        let cid = try #require(req.params["clientMsgId"])
        host.event("chat.message", ["seq": 1, "id": "m_u", "role": "user", "kind": "text", "text": "hi", "channel": "app", "ts": 1, "clientMsgId": cid])
        host.respond(req.id, ["id": "m_u", "seq": 1])
        #expect(await until { store.lastSeq == 1 })
        #expect(store.awaitingReply)
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        // No status in the sync: the newer assistant message alone ends the wait.
        host.syncResult = SyncResult(seq: 2, messages: [
            ChatMessage(seq: 2, id: "m_a", role: .assistant, kind: .text, text: "hello", channel: .app, ts: 2),
        ])
        await host.transport.simulateConnect()
        #expect(await until { store.connection == .online })
        #expect(await until { store.awaitingReply == false })
    }

    @Test func syncStatusNotBusyClearsAwaitingReply() {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.send("x")
        #expect(store.awaitingReply)
        store.applySync(SyncResult(seq: 0, messages: [], status: HostStatus(busy: false)), since: 0)
        #expect(!store.awaitingReply)
    }

    /// Offline sends sort by time among real messages and go out by
    /// themselves after reconnect.
    @Test func queuedEchoSortsByTimeAndResends() async throws {
        let host = ManualHost()
        let store = await online(host)
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        store.send("offline msg")
        #expect(await until { store.messages.first?.delivery == .queued })
        await host.transport.simulateConnect()
        #expect(await until { store.connection == .online })
        #expect(await until { host.request("chat.send") != nil })
        host.event("chat.message", ["seq": 1, "id": "m_a", "role": "assistant", "kind": "text", "text": "later reply", "channel": "app", "ts": 9_999_999_999_999])
        #expect(await until { store.messages.count == 2 })
        #expect(store.messages.last?.text == "later reply")
        #expect(store.messages.first?.text == "offline msg")
    }

    @Test func freshSnapshotReplacesQueuedEchoTheHostAlreadyHas() async throws {
        let host = ManualHost()
        let store = await online(host)
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        store.send("已经到了")
        #expect(await until { store.messages.first?.delivery == .queued })
        let cid = try #require(store.messages.first?.clientMsgId)
        store.applySync(SyncResult(seq: 1, messages: [
            ChatMessage(seq: 1, id: "s1", role: .user, text: "已经到了", ts: 1, clientMsgId: cid),
        ]), since: nil)
        #expect(store.messages.map(\.id) == ["s1"])
    }

    /// hello/sync that never answers on a live link: don't sit offline —
    /// the request times out, the link is dropped, and the retry succeeds.
    @Test func syncTimeoutRecoversOnLiveLink() async throws {
        let host = SlowSyncHost()
        let store = AppStore(transport: host.transport, rpcTimeout: 0.3)
        store.start()
        #expect(await until(5) { store.connection == .online })
        #expect(host.transport.forcedReconnects >= 1)
    }

    @Test func helloErrorRetriesWithBackoff() async throws {
        let host = FlakyHelloHost(failures: 2)
        let store = AppStore(transport: host.transport)
        store.syncRetryBase = 0.05
        store.start()
        #expect(await until(5) { store.connection == .online })
        #expect(host.hellos == 3)
        #expect(host.transport.forcedReconnects == 0)
    }

    @Test func helloKeepsFailingDropsLink() async throws {
        let host = FlakyHelloHost(failures: 3)
        let store = AppStore(transport: host.transport)
        store.syncRetryBase = 0.02
        store.start()
        #expect(await until(5) { store.connection == .online })
        #expect(host.transport.forcedReconnects == 1)
    }

    @Test func foregroundAfterLongBackgroundForcesReconnect() async throws {
        let host = ManualHost()
        let store = await online(host)
        let t0 = Date()
        store.didEnterBackground(at: t0)
        store.didBecomeActive(at: t0.addingTimeInterval(10))
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.transport.forcedReconnects == 0)
        store.didEnterBackground(at: t0)
        store.didBecomeActive(at: t0.addingTimeInterval(45))
        #expect(await until { host.transport.forcedReconnects == 1 })
        #expect(await until { store.connection == .online })
    }

    @Test func memoryWriteSendsBaseAndSurfacesConflict() async throws {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let r = try await store.readMemory(path: "user.md")
        let base = try #require(r.updatedAt)
        let newStamp = try await store.writeMemory(path: "user.md", content: "a", baseUpdatedAt: base)
        #expect(await host.lastParams["memory.write"]?["baseUpdatedAt"] == .number(Double(base)))
        #expect((newStamp ?? 0) > base)
        // Writing again against the old stamp is refused with the host's words.
        do {
            try await store.writeMemory(path: "user.md", content: "b", baseUpdatedAt: base)
            Issue.record("expected a conflict")
        } catch {
            #expect(Friendly.message(error) == "这个文件刚被助理改过，请重新打开再改")
        }
    }

    @Test func unregisterDeviceCallsHost() async throws {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        store.registerPush(token: Data([1, 2]), environment: .sandbox)
        #expect(await until { await host.pushTokens == ["0102"] })
        await store.unregisterDevice(pushToken: nil)
        #expect(await host.pushTokens.isEmpty)
        #expect(await host.requestLog.contains("device.unpair"))
        #expect(await host.lastParams["push.unregister"]?["token"] == "0102")
    }
}

/// Answers hello; never answers the first sync, answers later ones.
final class SlowSyncHost: @unchecked Sendable {
    let transport = InMemoryTransport()
    let lock = NSLock()
    var syncs = 0
    init() { transport.onSend = { [weak self] d in self?.receive(d) } }
    func receive(_ data: Data) {
        guard case .request(let id, let method, _)? = WireMessage.parse(data) else { return }
        switch method {
        case "hello": transport.deliver(json: ["id": .number(Double(id)), "result": ["hostName": "Mac", "version": "1"]])
        case "sync":
            let n = lock.withLock { syncs += 1; return syncs }
            if n > 1 { transport.deliver(json: ["id": .number(Double(id)), "result": ["seq": 0, "messages": []]]) }
        default: break
        }
    }
}

/// Fails `hello` with a remote error the first N times.
final class FlakyHelloHost: @unchecked Sendable {
    let transport = InMemoryTransport()
    let lock = NSLock()
    let failures: Int
    private var _hellos = 0
    var hellos: Int { lock.withLock { _hellos } }
    init(failures: Int) {
        self.failures = failures
        transport.onSend = { [weak self] d in self?.receive(d) }
    }
    func receive(_ data: Data) {
        guard case .request(let id, let method, _)? = WireMessage.parse(data) else { return }
        switch method {
        case "hello":
            let n = lock.withLock { _hellos += 1; return _hellos }
            if n <= failures {
                transport.deliver(json: ["id": .number(Double(id)), "error": ["message": "starting up"]])
            } else {
                transport.deliver(json: ["id": .number(Double(id)), "result": ["hostName": "Mac", "version": "1"]])
            }
        case "sync": transport.deliver(json: ["id": .number(Double(id)), "result": ["seq": 0, "messages": []]])
        default: break
        }
    }
}

// MARK: - transport

actor Flag {
    var value = false
    func set() { value = true }
}

@Suite("Regressions: transport")
struct TransportRegressionTests {
    /// withTimeout must return even when the operation ignores cancellation
    /// (sendPing's callback never firing on a half-open socket).
    @Test func withTimeoutReturnsForNonCancellableOp() async throws {
        let done = Flag()
        let timedOut = Flag()
        Task {
            do {
                try await withTimeout(0.2, onTimeout: { Task { await timedOut.set() } }) {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } // never resumes
                }
            } catch {
                #expect(error as? TransportError == .timeout)
            }
            await done.set()
        }
        #expect(await eventually(3) { await done.value })
        #expect(await eventually(1) { await timedOut.value })
    }

    @Test func withTimeoutPassesResultAndErrors() async throws {
        let v = try await withTimeout(2) { 42 }
        #expect(v == 42)
        await #expect(throws: URLError.self) {
            try await withTimeout(2) { throw URLError(.badURL) }
        }
    }

    /// Link handshakes, then goes silent (ping never completes): the ping
    /// timeout must close it and reconnect.
    @Test func deadLinkIsDetectedAndReconnects() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        let base = relay.factory
        let factory: UnitLinkFactory = { url in
            let l = try await base(url) as! FakeLink
            return SilentPingLink(inner: l)
        }
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: factory,
                               backoff: Backoff(base: 60, max: 60, jitter: 0), pingInterval: 0.2, pingTimeout: 0.2)
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        #expect(await eventually(5) { await log.events.contains { if case .disconnected = $0 { true } else { false } } })
        // Reconnects without waiting out the 60 s backoff.
        #expect(await eventually(5) { await log.connects >= 2 })
        await t.stop()
    }

    @Test func forceReconnectSkipsBackoff() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: relay.factory,
                               backoff: Backoff(base: 60, max: 60, jitter: 0))
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        await t.forceReconnect()
        #expect(await eventually { await log.connects == 2 })
        #expect(relay.hosts.count == 2)
        await t.stop()
    }
}

struct SilentPingLink: UnitLink {
    let inner: FakeLink
    func send(_ unit: Data) async throws { try await inner.send(unit) }
    func receive() async throws -> Data { try await inner.receive() }
    func ping() async throws {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    func close() { inner.close() }
}

// MARK: - wording / helpers

@Suite("Regressions: wording")
struct WordingRegressionTests {
    @Test func rememberNeedsScopeAndReversible() {
        let noScope = Approval(id: "a", tool: "Bash", title: "t", detail: "ls && cat x", irreversible: false, createdAt: 1)
        #expect(!noScope.canRemember)
        let withScope = Approval(id: "a", tool: "Bash", title: "t", detail: "git status", irreversible: false, createdAt: 1,
                                 suggestedScope: "cmd:git")
        #expect(withScope.canRemember)
        var irr = withScope
        irr.irreversible = true
        #expect(!irr.canRemember)
    }

    @Test func scopesInPlainWords() {
        #expect(Approval.friendlyScope("cmd:git") == "「git」这类命令")
        #expect(Approval.friendlyScope("domain:example.com") == "example.com 这个网站")
        #expect(Approval.friendlyScope("path:/Users/me/Projects/x")?.contains("这个文件夹") == true)
        #expect(Approval.friendlyScope("path:/Users/me/Projects/x")?.contains("/") == false)
        #expect(Approval.friendlyScope("recipient:a@b.com") == "发给 a@b.com")
        #expect(Approval.friendlyScope("weird") == nil)
        for raw in ["cmd:ls", "domain:x.y", "path:/a/b", "recipient:z"] {
            let s = Approval.friendlyScope(raw) ?? ""
            #expect(!s.contains("cmd:") && !s.contains("path:") && !s.contains("domain:"))
        }
    }

    @Test func toolNamesAreWordsNotSubstrings() {
        #expect(Friendly.tool("Bash") == "运行命令")
        #expect(Friendly.tool("Read") == "读文件")
        #expect(Friendly.tool("WebFetch") == "看网页")
        #expect(Friendly.tool("mcp__gmail__send_email") == "发邮件")
        #expect(Friendly.tool("NotebookEdit") == "改文件")
        #expect(Friendly.tool("read_thread") == "读文件")
        #expect(Friendly.tool("get_thread") == "用一个工具")
        #expect(Friendly.tool("credit_score") == "用一个工具")
        #expect(Friendly.tool("mcp__foo__frobnicate") == "用一个工具")
        #expect(Friendly.tool("") == "")
    }

    @Test func errorsInPlainWords() {
        #expect(Friendly.message(KeychainError(status: -34018)) == "这台设备没法安全保存配对信息")
        let enoent = Friendly.message(RPCError.remote("ENOENT: no such file or directory, open '/Users/x/.paloally/a.md'"))
        #expect(enoent == "找不到这个文件")
        #expect(Friendly.message(RPCError.remote("没有这个文件")) == "没有这个文件")
        #expect(Friendly.message(RPCError.remote("Error: something at foo.js:12")) == "电脑那边出了点问题，稍后再试")
        #expect(!Friendly.message(RPCError.remote("打不开 /Users/x/secret")).contains("/Users"))
        #expect(RPCError.remote("EACCES").errorDescription == "电脑那边没有权限做这个")
    }

    @Test func intervalStepping() {
        #expect(IntervalStep.down(60) == 55)
        #expect(IntervalStep.up(55) == 60)
        #expect(IntervalStep.up(60) == 90)
        #expect(IntervalStep.down(90) == 60)
        #expect(IntervalStep.down(5) == 5)
        #expect(IntervalStep.up(1440) == 1440)
    }

    @Test func intervalSchedule() {
        let w = Watch(id: "w", title: "t", kind: .schedule, instruction: "i", intervalMinutes: 120)
        #expect(w.isIntervalSchedule)
        let daily = Watch(id: "w", title: "t", kind: .schedule, instruction: "i", at: ["08:30"])
        #expect(!daily.isIntervalSchedule)
    }

    @Test func provisioningProfileApsEnvironment() {
        func blob(_ env: String, key: String = "aps-environment") -> Data {
            var d = Data([0x30, 0x82, 0x00, 0x01, 0xff])
            d.append(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Entitlements</key><dict><key>\(key)</key><string>\(env)</string></dict></dict></plist>
            """.utf8))
            d.append(Data([0x00, 0xa0, 0x82]))
            return d
        }
        #expect(ProvisioningProfile.pushEnvironment(from: blob("development")) == .sandbox)
        #expect(ProvisioningProfile.pushEnvironment(from: blob("production")) == .production)
        #expect(ProvisioningProfile.pushEnvironment(from: blob("production", key: "com.apple.developer.aps-environment")) == .production)
        #expect(ProvisioningProfile.pushEnvironment(from: Data("garbage".utf8)) == nil)
    }
}
