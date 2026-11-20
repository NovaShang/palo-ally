import CryptoKit
import Foundation
import Network

/// One relay tunnel connection: each WebSocket binary message is one E2E unit.
public protocol UnitLink: Sendable {
    func send(_ unit: Data) async throws
    func receive() async throws -> Data
    func ping() async throws
    func close()
}

public typealias UnitLinkFactory = @Sendable (URL) async throws -> any UnitLink

/// URLSessionWebSocketTask-backed link.
public final class WebSocketUnitLink: UnitLink, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }

    public static let factory: UnitLinkFactory = { url in WebSocketUnitLink(url: url) }

    public func send(_ unit: Data) async throws {
        try await task.send(.data(unit))
    }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return Data()
        }
    }

    public func ping() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // The pong handler can fire twice (pong, then again with an error when
            // the socket closes); resuming a continuation twice traps, so only once.
            let once = ResumeOnce()
            task.sendPing { error in
                guard once.claim() else { return }
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Exponential backoff with jitter.
public struct Backoff: Sendable {
    public var base: Double
    public var max: Double
    public var jitter: Double

    public init(base: Double = 0.5, max: Double = 30, jitter: Double = 0.2) {
        self.base = base; self.max = max; self.jitter = jitter
    }

    public func delay(attempt: Int) -> Double {
        let raw = Swift.min(max, base * pow(2, Double(Swift.min(attempt, 20))))
        guard jitter > 0 else { return raw }
        return raw * Double.random(in: (1 - jitter)...(1 + jitter))
    }
}

/// Resume-once box shared by the racing tasks in `withTimeout`.
final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func install(_ c: CheckedContinuation<T, Error>) {
        let pending: Result<T, Error>? = lock.withLock {
            if let early { self.early = nil; return early }
            continuation = c
            return nil
        }
        if let pending { c.resume(with: pending) }
    }

    /// Returns true if this call won the race.
    @discardableResult
    func finish(_ r: Result<T, Error>) -> Bool {
        let (won, c): (Bool, CheckedContinuation<T, Error>?) = lock.withLock {
            guard !done else { return (false, nil) }
            done = true
            let c = continuation
            continuation = nil
            if c == nil { early = r }
            return (true, c)
        }
        guard won else { return false }
        c?.resume(with: r)
        work?.cancel()
        timer?.cancel()
        return true
    }
}

/// Runs `op` with a deadline. Unlike a task group, this returns on time even
/// if `op` ignores cancellation (e.g. a `sendPing` whose callback never fires
/// on a half-open socket). `onTimeout` runs when the deadline wins, so the
/// caller can tear down whatever `op` is stuck on.
func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: (@Sendable () -> Void)? = nil,
                              _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = RaceBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            box.install(c)
            box.work = Task {
                do { box.finish(.success(try await op())) } catch { box.finish(.failure(error)) }
            }
            box.timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                if box.finish(.failure(TransportError.timeout)) { onTimeout?() }
            }
        }
    } onCancel: {
        box.finish(.failure(CancellationError()))
    }
}

/// E2E tunnel to the paired host, with automatic reconnect: straight to the
/// computer when it can be reached (the same Mac, the local network,
/// Tailscale: the addresses its `hello` told, `DirectEndpoints`), else
/// through the cloud relay. Either way the same sealed channel.
///
/// Each connect first dials the direct addresses at once (`directTimeout`),
/// the best route that completes the handshake winning, then the relay.
/// While on the relay it tries direct again every `probeInterval` and when
/// the network changes; once a direct link has handshaken, at a quiet moment
/// (nothing sent or received for `quietBeforeSwitch`), the relay link is
/// closed and the direct one taken up, a normal reconnect for the store
/// (which re-syncs). A direct link that dies falls back to the relay at
/// once, and the probing brings it back.
public actor RelayTransport: HostTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    public let host: PairedHost
    let identity: DeviceIdentity
    let linkFactory: UnitLinkFactory
    let backoff: Backoff
    let handshakeTimeout: Double
    let pingInterval: Double
    let pingTimeout: Double

    private var runTask: Task<Void, Never>?
    private var link: (any UnitLink)?
    private var channel: SecureChannel?
    private var stopped = true
    private var wakeup: CheckedContinuation<Void, Never>?
    private var attempt = 0
    private var skipNextBackoff = false

    // Direct links (DirectRoute.swift).
    let directCache: DirectEndpointCache
    let directTimeout: Double
    let probeTimeout: Double
    let probeInterval: Double
    let quietBeforeSwitch: Double
    private var direct: DirectEndpoints?
    /// How the current link goes (nil while not connected).
    private var route: TransportRoute?
    /// A direct link the prober opened, taken up by the next connect.
    private var pendingDirect: OpenedLink?
    /// The next connect goes to the relay without trying direct (a direct link just died).
    private var skipDirectOnce = false
    /// When dialing direct last found nothing, and on which network: not
    /// tried again on each reconnect until the network changes or a while passes.
    private var directFailedAt: Double?
    private var directFailedOnPath = 0
    private var pathGeneration = 0
    private var lastTraffic: Double = 0
    private var prober: Task<Void, Never>?
    private var proberWake: CheckedContinuation<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let watchNetwork: Bool

    public init(host: PairedHost, identity: DeviceIdentity, linkFactory: @escaping UnitLinkFactory = WebSocketUnitLink.factory,
                backoff: Backoff = Backoff(), handshakeTimeout: Double = 15, pingInterval: Double = 20,
                pingTimeout: Double = 10, directCache: DirectEndpointCache = DirectEndpointCache(),
                directTimeout: Double = 0.8, probeTimeout: Double = 3, probeInterval: Double = 60,
                quietBeforeSwitch: Double = 1.5, watchNetwork: Bool = true) {
        self.host = host
        self.identity = identity
        self.linkFactory = linkFactory
        self.backoff = backoff
        self.handshakeTimeout = handshakeTimeout
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.directCache = directCache
        self.directTimeout = directTimeout
        self.probeTimeout = probeTimeout
        self.probeInterval = probeInterval
        self.quietBeforeSwitch = quietBeforeSwitch
        self.watchNetwork = watchNetwork
        direct = directCache.load(host.daemonID)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    public var isConnected: Bool { channel != nil }

    public func start() {
        guard runTask == nil else { return }
        stopped = false
        runTask = Task { await self.runLoop() }
        prober = Task { await self.probeLoop() }
        if watchNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { await self?.networkChanged() }
            }
            monitor.start(queue: .global(qos: .utility))
            pathMonitor = monitor
        }
    }

    public func stop() {
        stopped = true
        runTask?.cancel()
        runTask = nil
        prober?.cancel()
        prober = nil
        wakeProber()
        pathMonitor?.cancel()
        pathMonitor = nil
        pendingDirect?.link.close()
        pendingDirect = nil
        link?.close()
        link = nil
        channel = nil
        route = nil
        wake()
    }

    /// How the link goes now (nil while not connected).
    public func currentRoute() -> TransportRoute? {
        channel == nil ? nil : route
    }

    /// What the computer's `hello` said (nil: nothing, an older host). Kept
    /// for the next launch; new ones are tried at once.
    public func directEndpointsAdvertised(_ endpoints: DirectEndpoints?) {
        guard let endpoints, endpoints != direct else { return }
        direct = endpoints
        directCache.save(endpoints, for: host.daemonID)
        directFailedAt = nil
        wakeProber()
    }

    public func reconnectNow() {
        attempt = 0
        wake()
    }

    /// Treats the current link as dead: closes it and reconnects right away
    /// (no backoff). Used after a ping / RPC timeout and when the app returns
    /// from a long stay in the background, where the socket is often stale.
    public func forceReconnect() {
        guard !stopped else { return }
        attempt = 0
        skipNextBackoff = true
        if let link {
            link.close()
        }
        wake()
    }

    private var linkGeneration: UUID?

    private func pingFailed(_ generation: UUID) {
        guard linkGeneration == generation else { return }
        forceReconnect()
    }

    public func send(_ message: Data) async throws {
        guard var ch = channel, let link else { throw TransportError.notConnected }
        // Seal and commit the counter before suspending: actor re-entrancy
        // then can't reorder two sends relative to their nonces.
        let unit = try ch.seal(message)
        channel = ch
        lastTraffic = ProcessInfo.processInfo.systemUptime
        try await link.send(unit)
    }

    private func wake() {
        wakeup?.resume()
        wakeup = nil
    }

    private func sleep(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeup = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.wake()
            }
        }
    }

    private func runLoop() async {
        while !stopped && !Task.isCancelled {
            skipNextBackoff = false
            let reason = await connectAndPump()
            let wasDirect = route?.isDirect == true
            channel = nil
            link?.close()
            link = nil
            route = nil
            if stopped { break }
            // A direct link that died (not one the prober is replacing):
            // straight to the relay, no waiting.
            if wasDirect && pendingDirect == nil {
                skipDirectOnce = true
                skipNextBackoff = true
            }
            continuation.yield(.disconnected(reason))
            if skipNextBackoff {
                skipNextBackoff = false
                continue
            }
            let d = backoff.delay(attempt: attempt)
            attempt += 1
            await sleep(seconds: d)
        }
        continuation.yield(.disconnected(.closed))
    }

    /// Connects, handshakes, then pumps inbound units until the link dies.
    private func connectAndPump() async -> DisconnectReason {
        guard let hostKey = host.hostPublicKey else { return .rejected("bad host key") }
        var opened: OpenedLink?
        if let p = pendingDirect {
            pendingDirect = nil
            opened = p
        } else if shouldTryDirect() {
            opened = await dialDirect(timeout: directTimeout)
            if opened == nil { noteDirectFailed() }
        }
        skipDirectOnce = false
        if stopped {
            opened?.link.close()
            return .closed
        }
        let l: any UnitLink
        if let opened {
            l = opened.link
            link = l
            channel = opened.channel
            route = opened.route
            debugLog("relay: direct link (\(opened.route.rawValue))")
        } else {
            let handshake = ClientHandshake(identity: identity, deviceID: host.deviceID, hostKey: hostKey)
            do {
                let url = try host.tunnelURL(identity: identity)
                l = try await linkFactory(url)
                link = l
                try await l.send(try handshake.helloUnit())
                let welcome = try await withTimeout(handshakeTimeout, onTimeout: { l.close() }) { try await l.receive() }
                channel = try handshake.finish(welcomeUnit: welcome)
                route = .relay
            } catch let e as E2EError {
                debugLog("relay handshake failed: \(e)")
                switch e {
                case .rejected(let m): return .rejected(m)
                default: return .network(e.localizedDescription)
                }
            } catch {
                debugLog("relay connect failed: \(error)")
                return .network(error.localizedDescription)
            }
        }
        if stopped { return .closed }
        lastTraffic = ProcessInfo.processInfo.systemUptime
        attempt = 0
        continuation.yield(.connected)

        let generation = UUID()
        linkGeneration = generation
        let pinger = Task { [pingInterval, pingTimeout, weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                if Task.isCancelled { break }
                do {
                    try await withTimeout(pingTimeout) { try await l.ping() }
                } catch {
                    if Task.isCancelled { break }
                    // Dead link: close it so the pump's receive fails and the
                    // run loop reconnects immediately.
                    debugLog("relay ping timed out; reconnecting")
                    l.close()
                    await self?.pingFailed(generation)
                    break
                }
            }
        }
        defer { pinger.cancel() }

        do {
            while true {
                let unit = try await l.receive()
                lastTraffic = ProcessInfo.processInfo.systemUptime
                guard let type = unit.first else { continue }
                if type == UnitType.sealed.rawValue {
                    guard var ch = channel else { return .closed }
                    let pt = try ch.open(unit)
                    channel = ch
                    continuation.yield(.message(pt))
                } else if type == UnitType.handshake.rawValue {
                    if let msg = try? HandshakeMessage.parse(unit: unit), msg.t == "error" {
                        return .rejected(msg.error ?? "error")
                    }
                }
                // Unknown unit types are ignored (forward compatibility).
            }
        } catch {
            return stopped ? .closed : .network(error.localizedDescription)
        }
    }
}

// MARK: - direct links

extension RelayTransport {
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func shouldTryDirect() -> Bool {
        guard !skipDirectOnce, let direct, !direct.candidates.isEmpty else { return false }
        // Nothing answered a moment ago on this same network: the relay
        // straight away; the prober keeps trying meanwhile.
        if let at = directFailedAt, directFailedOnPath == pathGeneration, now - at < 30 { return false }
        return true
    }

    private func noteDirectFailed() {
        directFailedAt = now
        directFailedOnPath = pathGeneration
    }

    /// Dials every direct address at once; the best route that completes the
    /// handshake within `timeout` (nil: none).
    func dialDirect(timeout: Double) async -> OpenedLink? {
        guard let direct, let hostKey = host.hostPublicKey else { return nil }
        let candidates = direct.candidates
        guard !candidates.isEmpty else { return nil }
        let race = DirectRace(ranks: candidates.map(\.route.rank))
        for c in candidates {
            let rank = c.route.rank
            guard let url = try? direct.url(addr: c.addr, host: host, identity: identity) else {
                race.finished(rank: rank, nil)
                continue
            }
            let handshake = ClientHandshake(identity: identity, deviceID: host.deviceID, hostKey: hostKey)
            let factory = linkFactory
            let route = c.route
            Task {
                var opened: OpenedLink?
                var dialed: (any UnitLink)?
                do {
                    // The dial itself is bounded too: a factory that hangs
                    // mustn't hold the race up.
                    let l = try await withTimeout(timeout) { try await factory(url) }
                    dialed = l
                    let welcome = try await withTimeout(timeout, onTimeout: { l.close() }) {
                        try await l.send(try handshake.helloUnit())
                        return try await l.receive()
                    }
                    opened = OpenedLink(link: l, channel: try handshake.finish(welcomeUnit: welcome), route: route)
                } catch {
                    dialed?.close()
                }
                race.finished(rank: rank, opened)
            }
        }
        return await race.wait()
    }

    private func wakeProber() {
        proberWake?.resume()
        proberWake = nil
    }

    private func networkChanged() {
        pathGeneration += 1
        // A direct link over the network may be gone with it: check it now
        // rather than at the next ping.
        if let route, route.isDirect, route != .local, let l = link {
            let timeout = min(pingTimeout, 3)
            Task {
                do { try await withTimeout(timeout) { try await l.ping() } } catch {
                    debugLog("relay: direct link silent after a network change")
                    l.close()
                }
            }
        }
        wakeProber()
    }

    /// Waits `probeInterval`, or less when woken (new endpoints, a network
    /// change, stop).
    private func probeWait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            proberWake?.resume()
            proberWake = c
            let interval = probeInterval
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                await self?.wakeProber()
            }
        }
    }

    private func probeLoop() async {
        while !stopped && !Task.isCancelled {
            await probeWait()
            if stopped || Task.isCancelled { break }
            // Let a network change settle (addresses arrive a beat later).
            try? await Task.sleep(for: .seconds(0.3))
            await probeOnce()
        }
    }

    /// On the relay with direct addresses known: dial them, and if one
    /// handshakes, switch over at a quiet moment.
    private func probeOnce() async {
        guard !stopped, route == .relay, channel != nil, let direct, !direct.candidates.isEmpty else { return }
        // A quiet moment: a reply being written or a file coming in isn't cut.
        let waitedSince = now
        while now - lastTraffic < quietBeforeSwitch {
            if stopped || route != .relay || now - waitedSince > 20 { return }
            try? await Task.sleep(for: .seconds(0.25))
        }
        guard let opened = await dialDirect(timeout: probeTimeout) else {
            noteDirectFailed()
            return
        }
        guard !stopped, route == .relay, let current = link, pendingDirect == nil else {
            opened.link.close()
            return
        }
        debugLog("relay: switching to the direct link (\(opened.route.rawValue))")
        pendingDirect = opened
        attempt = 0
        skipNextBackoff = true
        current.close()
    }
}


/// A one-shot latch: `claim()` returns true exactly once, from any thread.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
