import Foundation
import Testing
@testable import PaloAllyKit

/// A link that never answers until closed (an address nobody's at, where
/// packets just vanish).
final class SilentLink: UnitLink, @unchecked Sendable {
    let box = Mailbox()
    func send(_ unit: Data) async throws {}
    func receive() async throws -> Data { try await box.pop() }
    func ping() async throws {}
    func close() { Task { await box.close() } }
}

/// The relay plus the computer's direct addresses: each one reachable (the
/// fake host answers), refused (throws at once) or silent.
final class FakeNetwork: @unchecked Sendable {
    enum Reach { case ok, refused, silent }
    let relay: FakeRelay
    private let lock = NSLock()
    private var _reach: [String: Reach] = [:]
    private var _dialed: [String] = []

    init(device: DeviceIdentity) { relay = FakeRelay(device: device) }

    func set(_ addr: String, _ r: Reach) { lock.withLock { _reach[addr] = r } }
    var dialed: [String] { lock.withLock { _dialed } }

    var factory: UnitLinkFactory {
        let inner = relay.factory
        return { [self] url in
            guard url.scheme == "ws", let host = url.host else { return try await inner(url) }
            let r: Reach = lock.withLock {
                _dialed.append(host)
                return _reach[host] ?? .refused
            }
            switch r {
            case .ok: return try await inner(url)
            case .refused: throw URLError(.cannotConnectToHost)
            case .silent: return SilentLink()
            }
        }
    }

    /// The fake hosts reached directly (not through the relay).
    var directHosts: [FakeTunnelHost] {
        zip(relay.urls, relay.hosts).filter { $0.0.scheme == "ws" }.map(\.1)
    }
}

private func cache(_ endpoints: DirectEndpoints?, for daemonID: String = "daemon-1") -> DirectEndpointCache {
    let c = DirectEndpointCache(defaults: UserDefaults(suiteName: "direct-test-\(UUID().uuidString)")!)
    c.save(endpoints, for: daemonID)
    return c
}

private let endpoints = DirectEndpoints(port: 47820, addrs: ["100.101.102.103", "192.168.1.20", "127.0.0.1"])

@Suite("Direct links")
struct DirectRouteTests {
    @Test func candidatesAreOrderedAndClassified() {
        let c = DirectEndpoints(port: 47820, addrs: ["100.64.0.9", "10.0.0.5", "127.0.0.1", "box.ts.net", "10.0.0.5", "300.1.1.1"]).candidates
        #expect(c.map(\.addr) == ["127.0.0.1", "10.0.0.5", "100.64.0.9"])
        #expect(c.map(\.route) == [.local, .lan, .tailscale])
        #expect(DirectEndpoints.route(of: "100.128.0.1") == .lan)
        #expect(DirectEndpoints(port: 0, addrs: ["127.0.0.1"]).candidates.isEmpty)
    }

    @Test func cacheKeepsEndpointsPerComputer() {
        let c = cache(endpoints)
        #expect(c.load("daemon-1") == endpoints)
        #expect(c.load("daemon-2") == nil)
        c.save(nil, for: "daemon-1")
        #expect(c.load("daemon-1") == nil)
    }

    @Test func prefersDirectAndTakesTheBestRouteThatAnswers() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let net = FakeNetwork(device: device)
        net.set("192.168.1.20", .ok)
        net.set("100.101.102.103", .silent) // Tailscale off on this device: never answers
        let t = RelayTransport(host: net.relay.paired, identity: device, linkFactory: net.factory,
                               backoff: Backoff(base: 0.01, max: 0.05, jitter: 0), directCache: cache(endpoints),
                               directTimeout: 2, watchNetwork: false)
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        let began = Date()
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        // Decided once loopback had failed and the LAN answered, not after the silent one's timeout.
        #expect(Date().timeIntervalSince(began) < 1.5)
        #expect(await t.currentRoute() == .lan)
        #expect(!net.relay.urls.contains { $0.scheme == "wss" })
        let url = try #require(net.relay.urls.first)
        #expect(url.absoluteString.hasPrefix("ws://192.168.1.20:47820/v1/tunnel?daemon_id=daemon-1&device_id=dev-1&"))

        try await t.send(Data(#"{"id":1,"method":"hello","params":{}}"#.utf8))
        #expect(await eventually { await log.messages.count == 1 })
        await t.stop()
    }

    @Test func fallsBackToTheRelayWhenNothingAnswers() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let net = FakeNetwork(device: device)
        net.set("192.168.1.20", .silent)
        let t = RelayTransport(host: net.relay.paired, identity: device, linkFactory: net.factory,
                               backoff: Backoff(base: 0.01, max: 0.05, jitter: 0), directCache: cache(endpoints),
                               directTimeout: 0.3, watchNetwork: false)
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        #expect(await t.currentRoute() == .relay)
        let dialedFirst = net.dialed.count
        #expect(dialedFirst == 3)

        // A reconnect on the same network goes straight to the relay.
        await net.relay.hosts.last!.drop()
        #expect(await eventually { await log.connects == 2 })
        #expect(net.dialed.count == dialedFirst)
        await t.stop()
    }

    @Test func switchesToDirectOnceItAnswersAndBackToTheRelayWhenItDies() async throws {
        let device = DeviceIdentity(privateKey: .init())
        let net = FakeNetwork(device: device)
        let t = RelayTransport(host: net.relay.paired, identity: device, linkFactory: net.factory,
                               backoff: Backoff(base: 5, max: 5, jitter: 0), directCache: cache(nil),
                               directTimeout: 0.3, probeTimeout: 0.5, quietBeforeSwitch: 0.1, watchNetwork: false)
        let log = EventLog()
        let pump = Task { for await e in t.events { await log.add(e) } }
        defer { pump.cancel() }
        await t.start()
        #expect(await eventually { await log.connects == 1 })
        #expect(await t.currentRoute() == .relay)

        // The computer's hello names its addresses; this Mac's own answers.
        net.set("127.0.0.1", .ok)
        await t.directEndpointsAdvertised(endpoints)
        #expect(await eventually(5) { await log.connects == 2 })
        #expect(await t.currentRoute() == .local)
        #expect(net.directHosts.count == 1)
        // A normal reconnect for the store: disconnected, then connected again.
        #expect(await log.events.contains { if case .disconnected = $0 { true } else { false } })
        try await t.send(Data(#"{"id":7,"method":"sync","params":{}}"#.utf8))
        #expect(await eventually { await log.messages.count == 1 })
        #expect(await net.directHosts[0].receiveCounter == 1)

        // The direct link dies: the relay at once, without the 5 s backoff.
        net.set("127.0.0.1", .refused)
        await net.directHosts[0].drop()
        #expect(await eventually(2) { await log.connects == 3 })
        #expect(await t.currentRoute() == .relay)
        await t.stop()
    }

    @Test func raceDecidesOnTheBestRoute() async {
        // LAN answers first, loopback a moment later: loopback wins, the LAN link is closed.
        let race = DirectRace(ranks: [0, 1, 2])
        let lan = SilentLink()
        let local = SilentLink()
        let ch = SecureChannel(sendKey: .init(size: .bits256), receiveKey: .init(size: .bits256))
        race.finished(rank: 1, OpenedLink(link: lan, channel: ch, route: .lan))
        race.finished(rank: 0, OpenedLink(link: local, channel: ch, route: .local))
        let won = await race.wait()
        #expect(won?.route == .local)
        // A late Tailscale success after the decision is closed, not leaked.
        let late = SilentLink()
        race.finished(rank: 2, OpenedLink(link: late, channel: ch, route: .tailscale))
        await #expect(throws: (any Error).self) { _ = try await late.receive() }
        await #expect(throws: (any Error).self) { _ = try await lan.receive() }
    }
}

/// The app's real WebSocket against a real host's local tunnel. Opt-in:
///   PALOALLY_DIRECT_LIVE=<json file: daemonId, deviceId, deviceSeed (b64),
///   hostKey (b64), port, file (a path on that computer)> swift test --filter DirectLive
/// The host side writes it (a host with a test device paired, its tunnel
/// on 127.0.0.1). The relay in the pairing is unreachable on purpose: only
/// the direct link can connect.
@MainActor
@Suite("Direct live", .serialized)
struct DirectLiveTests {
    struct Setup: Decodable { let daemonId, deviceId, deviceSeed, hostKey: String; let port: Int; let file: String }

    nonisolated static var setup: Setup? {
        guard let p = ProcessInfo.processInfo.environment["PALOALLY_DIRECT_LIVE"], let d = FileManager.default.contents(atPath: p)
        else { return nil }
        return try? JSONDecoder().decode(Setup.self, from: d)
    }

    @Test(.enabled(if: setup != nil, "set PALOALLY_DIRECT_LIVE to run"))
    func connectsDirectlyAndDownloads() async throws {
        let s = try #require(Self.setup)
        let identity = try DeviceIdentity(seed: try #require(Data(base64Encoded: s.deviceSeed)))
        let host = PairedHost(relay: URL(string: "http://127.0.0.1:1")!, daemonID: s.daemonId, deviceID: s.deviceId,
                              hostKey: try #require(Data(base64Encoded: s.hostKey)), hostLabel: "live", hostFingerprint: "")
        let cache = DirectEndpointCache(defaults: UserDefaults(suiteName: "direct-live-\(UUID().uuidString)")!)
        cache.save(DirectEndpoints(port: s.port, addrs: ["127.0.0.1"]), for: s.daemonId)
        let transport = RelayTransport(host: host, identity: identity, directCache: cache)
        let store = AppStore(transport: transport, clientKind: "ios", clientVersion: "test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("direct-live-\(UUID().uuidString)")
        store.fileFetcher = FileFetcher(cache: FileCache(root: dir, capBytes: 1 << 30))
        defer { try? FileManager.default.removeItem(at: dir) }
        store.start()
        let began = Date()
        while store.connection != .online, Date().timeIntervalSince(began) < 10 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.connection == .online)
        print("[direct-live] online in \(String(format: "%.0f", Date().timeIntervalSince(began) * 1000)) ms, route \(String(describing: store.connectionRoute))")
        #expect(store.connectionRoute == .local)

        let t0 = Date()
        let url = try await store.downloadFile(.file(scope: .root, path: s.file), name: "big.bin")
        let secs = Date().timeIntervalSince(t0)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        print("[direct-live] \(size) bytes in \(String(format: "%.2f", secs)) s = \(String(format: "%.1f", Double(size) / 1_048_576 / secs)) MB/s")
        #expect(size == 50 * 1024 * 1024)
        store.shutdown()
    }
}
