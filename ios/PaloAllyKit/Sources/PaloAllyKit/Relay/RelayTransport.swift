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
            task.sendPing { error in
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

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TransportError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
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

    private var runTask: Task<Void, Never>?
    private var link: (any UnitLink)?
    private var channel: SecureChannel?
    private var stopped = true
    private var wakeup: CheckedContinuation<Void, Never>?
    private var attempt = 0

    public init(host: PairedHost, identity: DeviceIdentity, linkFactory: @escaping UnitLinkFactory = WebSocketUnitLink.factory,
                backoff: Backoff = Backoff(), handshakeTimeout: Double = 15, pingInterval: Double = 20) {
        self.host = host
        self.identity = identity
        self.linkFactory = linkFactory
        self.backoff = backoff
        self.handshakeTimeout = handshakeTimeout
        self.pingInterval = pingInterval
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
            let reason = await connectAndPump()
            channel = nil
            link?.close()
            link = nil
            if stopped { break }
            continuation.yield(.disconnected(reason))
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
            let welcome = try await withTimeout(handshakeTimeout) { try await l.receive() }
            channel = try handshake.finish(welcomeUnit: welcome)
        } catch let e as E2EError {
            switch e {
            case .rejected(let m): return .rejected(m)
            default: return .network(e.localizedDescription)
            }
        } catch {
            return .network(error.localizedDescription)
        }
        if stopped { return .closed }
        attempt = 0
        continuation.yield(.connected)

        let pinger = Task { [pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                if Task.isCancelled { break }
                do { try await withTimeout(10) { try await l.ping() } } catch { l.close(); break }
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
