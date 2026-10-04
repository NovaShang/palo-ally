import CryptoKit
import Foundation
import Testing
@testable import PaloAllyKit

/// Blocking FIFO for units, closable with an error.
actor Mailbox {
    private var buffer: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func push(_ d: Data) {
        guard !closed else { return }
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: d) } else { buffer.append(d) }
    }

    func pop() async throws -> Data {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { throw URLError(.networkConnectionLost) }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() {
        closed = true
        for w in waiters { w.resume(throwing: URLError(.networkConnectionLost)) }
        waiters.removeAll()
    }
}

/// Host side of one fake tunnel: runs the reference responder, then answers
/// JSON-RPC requests with `{"echo": method}` and can push events.
actor FakeTunnelHost {
    let responder: HostHandshakeResponder
    let toClient = Mailbox()
    var channel: SecureChannel?
    var received: [JSONValue] = []
    var rejectWith: String?

    init(responder: HostHandshakeResponder, rejectWith: String? = nil) {
        self.responder = responder
        self.rejectWith = rejectWith
    }

    func fromClient(_ unit: Data) async {
        if channel == nil {
            if let rejectWith {
                await toClient.push(HostHandshakeResponder.errorUnit(rejectWith))
                await toClient.close()
                return
            }
            do {
                let r = try responder.respond(to: unit)
                channel = r.channel
                await toClient.push(r.welcomeUnit)
            } catch {
                await toClient.push(HostHandshakeResponder.errorUnit("\(error)"))
                await toClient.close()
            }
            return
        }
        guard var ch = channel, let pt = try? ch.open(unit) else { await toClient.close(); return }
        channel = ch
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: pt) else { return }
        received.append(v)
        if let id = v["id"], let method = v["method"] {
            await sendPlain(["id": id, "result": ["echo": method]])
        }
    }

    func sendPlain(_ v: JSONValue) async {
        guard var ch = channel, let d = try? JSONEncoder().encode(v), let unit = try? ch.seal(d) else { return }
        channel = ch
        await toClient.push(unit)
    }

    func drop() async { await toClient.close() }
    var sendCounter: UInt64 { channel?.sendCounter ?? 0 }
    var receiveCounter: UInt64 { channel?.receiveCounter ?? 0 }
}

struct FakeLink: UnitLink {
    let host: FakeTunnelHost
    func send(_ unit: Data) async throws { await host.fromClient(unit) }
    func receive() async throws -> Data { try await host.toClient.pop() }
    func ping() async throws {}
    func close() { Task { await host.drop() } }
}

/// Builds fresh FakeTunnelHosts per connection and checks the relay-style
/// attach challenge on every URL.
final class FakeRelay: @unchecked Sendable {
    let hostKey = Curve25519.Signing.PrivateKey()
    let device: DeviceIdentity
    let deviceID = "dev-1"
    private let lock = NSLock()
    private var _hosts: [FakeTunnelHost] = []
    private var _urls: [URL] = []
    var rejectWith: String?

    init(device: DeviceIdentity) { self.device = device }

    var hosts: [FakeTunnelHost] { lock.withLock { _hosts } }
    var urls: [URL] { lock.withLock { _urls } }

    var paired: PairedHost {
        PairedHost(relay: URL(string: "https://relay.test")!, daemonID: "daemon-1", deviceID: deviceID,
                   hostKey: hostKey.publicKey.rawRepresentation, hostLabel: "Mac", hostFingerprint: "fp")
    }

    var factory: UnitLinkFactory {
        { [self] url in
            let devicePub = device.privateKey.publicKey
            let responder = HostHandshakeResponder(hostKey: hostKey) { [deviceID] id in id == deviceID ? devicePub : nil }
            let host = FakeTunnelHost(responder: responder, rejectWith: rejectWith)
            lock.withLock { _hosts.append(host); _urls.append(url) }
            return FakeLink(host: host)
        }
    }
}

func eventually(_ timeout: Double = 3, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Collects transport events in the background.
actor EventLog {
    var events: [TransportEvent] = []
    func add(_ e: TransportEvent) { events.append(e) }
    var connects: Int { events.filter { $0 == .connected }.count }
    var messages: [Data] { events.compactMap { if case .message(let d) = $0 { d } else { nil } } }
}

@Suite("Relay transport")
struct RelayTransportTests {
    @Test func connectsHandshakesAndExchanges() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: relay.factory,
                               backoff: Backoff(base: 0.01, max: 0.05, jitter: 0))
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })

        // Tunnel URL carried a valid attach signature.
        let url = try #require(relay.urls.first)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.scheme == "wss")
        let msg = DeviceIdentity.attachChallenge(daemonID: "daemon-1", deviceID: "dev-1", ts: Int64(q["ts"]!)!)
        #expect(device.privateKey.publicKey.isValidSignature(Data(base64URLEncoded: q["sig"]!)!, for: msg))

        for i in 1...3 {
            try await t.send(Data(#"{"id":\#(i),"method":"m\#(i)","params":{}}"#.utf8))
        }
        #expect(await eventually { await log.messages.count == 3 })
        let first = try JSONDecoder().decode(JSONValue.self, from: await log.messages[0])
        #expect(first["result"]?["echo"] == "m1")
        let host = relay.hosts[0]
        #expect(await host.receiveCounter == 3)
        #expect(await host.sendCounter == 3)
        await t.stop()
    }

    @Test func reconnectsWithFreshSessionAfterDrop() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: relay.factory,
                               backoff: Backoff(base: 0.01, max: 0.05, jitter: 0))
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        try await t.send(Data(#"{"id":1,"method":"a","params":{}}"#.utf8))
        #expect(await eventually { await log.messages.count == 1 })

        await relay.hosts[0].drop()
        #expect(await eventually { await log.connects == 2 })
        #expect(await log.events.contains { if case .disconnected(.network) = $0 { true } else { false } })
        #expect(relay.hosts.count == 2)

        // New session: counters restart at 0 on both sides.
        try await t.send(Data(#"{"id":2,"method":"b","params":{}}"#.utf8))
        #expect(await eventually { await log.messages.count == 2 })
        #expect(await relay.hosts[1].receiveCounter == 1)
        await t.stop()
    }

    @Test func sendWhileDisconnectedThrows() async {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: relay.factory)
        await #expect(throws: TransportError.notConnected) { try await t.send(Data("{}".utf8)) }
    }

    @Test func rejectedHandshakeSurfaces() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        relay.rejectWith = "unknown device"
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: relay.factory,
                               backoff: Backoff(base: 5, max: 5, jitter: 0))
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.events.contains(.disconnected(.rejected("unknown device"))) })
        #expect(await log.connects == 0)
        await t.stop()
    }

    @Test func reconnectNowSkipsBackoff() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let relay = FakeRelay(device: device)
        let t = RelayTransport(host: relay.paired, identity: device, linkFactory: relay.factory,
                               backoff: Backoff(base: 60, max: 60, jitter: 0))
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        await relay.hosts[0].drop()
        #expect(await eventually { await log.events.count == 2 }) // disconnected; now sleeping 60s
        await t.reconnectNow()
        #expect(await eventually { await log.connects == 2 })
        await t.stop()
    }

    @Test func backoffGrowsAndCaps() {
        let b = Backoff(base: 0.5, max: 30, jitter: 0)
        #expect(b.delay(attempt: 0) == 0.5)
        #expect(b.delay(attempt: 1) == 1)
        #expect(b.delay(attempt: 3) == 4)
        #expect(b.delay(attempt: 10) == 30)
        #expect(b.delay(attempt: 1000) == 30)
        let j = Backoff(base: 1, max: 30, jitter: 0.2)
        for _ in 0..<50 { #expect((0.8...1.2).contains(j.delay(attempt: 0))) }
    }
}
