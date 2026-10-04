import CryptoKit
import Foundation

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

/// E2E relay tunnel to the paired host, with automatic reconnect.
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

    public init(host: PairedHost, identity: DeviceIdentity, linkFactory: @escaping UnitLinkFactory = WebSocketUnitLink.factory,
                backoff: Backoff = Backoff(), handshakeTimeout: Double = 15, pingInterval: Double = 20,
                pingTimeout: Double = 10) {
        self.host = host
        self.identity = identity
        self.linkFactory = linkFactory
        self.backoff = backoff
        self.handshakeTimeout = handshakeTimeout
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    public var isConnected: Bool { channel != nil }

    public func start() {
        guard runTask == nil else { return }
        stopped = false
        runTask = Task { await self.runLoop() }
    }

    public func stop() {
        stopped = true
        runTask?.cancel()
        runTask = nil
        link?.close()
        link = nil
        channel = nil
        wake()
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
            channel = nil
            link?.close()
            link = nil
            if stopped { break }
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
        let l: any UnitLink
        let handshake = ClientHandshake(identity: identity, deviceID: host.deviceID, hostKey: hostKey)
        do {
            let url = try host.tunnelURL(identity: identity)
            l = try await linkFactory(url)
            link = l
            try await l.send(try handshake.helloUnit())
            let welcome = try await withTimeout(handshakeTimeout, onTimeout: { l.close() }) { try await l.receive() }
            channel = try handshake.finish(welcomeUnit: welcome)
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
        if stopped { return .closed }
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
