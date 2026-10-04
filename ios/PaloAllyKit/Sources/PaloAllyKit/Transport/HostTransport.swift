import Foundation

public enum DisconnectReason: Sendable, Equatable {
    /// Voluntary stop.
    case closed
    /// Network / relay trouble; will retry.
    case network(String)
    /// The host refused us (e.g. this device was unpaired). Retrying won't help
    /// until the user pairs again, but we still retry with backoff.
    case rejected(String)
}

public enum TransportEvent: Sendable, Equatable {
    /// A (new) secure session is up. Emitted again after every reconnect.
    case connected
    case disconnected(DisconnectReason)
    /// One plaintext application message (design.md §5.3 JSON).
    case message(Data)
}

public enum TransportError: Error, LocalizedError, Equatable {
    case notConnected
    case timeout
    public var errorDescription: String? {
        switch self {
        case .notConnected: "还没连上"
        case .timeout: "等太久了"
        }
    }
}

/// A message pipe to the host. The store doesn't care whether it's the E2E
/// relay tunnel, a local socket, or an in-memory fake.
///
/// `events` has a single consumer (the RPC client).
public protocol HostTransport: AnyObject, Sendable {
    var events: AsyncStream<TransportEvent> { get }
    /// Begin connecting; reconnects automatically until `stop()`.
    func start() async
    func stop() async
    /// Sends one plaintext application message.
    func send(_ message: Data) async throws
    /// Skip any pending backoff and try right away (e.g. app foregrounded).
    func reconnectNow() async
    /// Treat the link as dead (e.g. after a timeout) and reconnect right away.
    func forceReconnect() async
}

/// In-process transport. The "host side" is whatever sets `onSend`; it talks
/// back with `deliver(_:)`. Used by tests and the demo host.
public final class InMemoryTransport: HostTransport, @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var _connected = false
    private var _sent: [Data] = []
    private var _onSend: (@Sendable (Data) async -> Void)?
    private var _onConnect: (@Sendable () async -> Void)?

    /// Connect immediately on `start()`.
    public var autoConnect: Bool

    public init(autoConnect: Bool = true) {
        self.autoConnect = autoConnect
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    /// Host-side receiver for client → host messages.
    public var onSend: (@Sendable (Data) async -> Void)? {
        get { lock.withLock { _onSend } }
        set { lock.withLock { _onSend = newValue } }
    }

    /// Called (before `.connected` is emitted) on every connect.
    public var onConnect: (@Sendable () async -> Void)? {
        get { lock.withLock { _onConnect } }
        set { lock.withLock { _onConnect = newValue } }
    }

    public var isConnected: Bool { lock.withLock { _connected } }
    /// Every message the client sent, in order.
    public var sent: [Data] { lock.withLock { _sent } }

    public func start() async {
        if autoConnect { await simulateConnect() }
    }

    public func stop() async {
        let was = lock.withLock { () -> Bool in let w = _connected; _connected = false; return w }
        if was { continuation.yield(.disconnected(.closed)) }
    }

    public func reconnectNow() async {
        if !isConnected { await simulateConnect() }
    }

    /// Number of `forceReconnect()` calls (for tests).
    public var forcedReconnects: Int { lock.withLock { _forced } }
    private var _forced = 0

    public func forceReconnect() async {
        lock.withLock { _forced += 1 }
        if isConnected { simulateDisconnect(.network("timeout")) }
        if autoConnect { await simulateConnect() }
    }

    public func send(_ message: Data) async throws {
        let handler = try lock.withLock { () throws -> (@Sendable (Data) async -> Void)? in
            guard _connected else { throw TransportError.notConnected }
            _sent.append(message)
            return _onSend
        }
        await handler?(message)
    }

    // MARK: host-side controls

    public func deliver(_ message: Data) {
        continuation.yield(.message(message))
    }

    public func deliver(json: JSONValue) {
        if let d = try? JSONEncoder().encode(json) { deliver(d) }
    }

    public func simulateConnect() async {
        let hook = lock.withLock { () -> (@Sendable () async -> Void)? in _connected = true; return _onConnect }
        await hook?()
        continuation.yield(.connected)
    }

    public func simulateDisconnect(_ reason: DisconnectReason = .network("simulated")) {
        lock.withLock { _connected = false }
        continuation.yield(.disconnected(reason))
    }
}
