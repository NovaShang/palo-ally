import Foundation

public enum RPCError: Error, LocalizedError, Equatable {
    case notConnected
    case disconnected
    case timeout
    case remote(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConnected, .disconnected: "暂时连不上，等连上了再试"
        case .timeout: "等太久了，稍后再试"
        case .remote(let m): Friendly.remote(m)
        case .badResponse: "收到的回复看不懂"
        }
    }
}

public enum RPCInbound: Sendable {
    case connected
    case disconnected(DisconnectReason)
    case event(name: String, data: JSONValue)
}

/// Parsed application message (design.md §5.3).
public enum WireMessage: Sendable, Equatable {
    case response(id: Int, result: JSONValue)
    case errorResponse(id: Int, message: String)
    case event(name: String, data: JSONValue)
    case request(id: Int, method: String, params: JSONValue)

    public static func parse(_ data: Data) -> WireMessage? {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        if let name = o["event"]?.stringValue {
            return .event(name: name, data: o["data"] ?? .null)
        }
        guard let idNum = o["id"]?.doubleValue else { return nil }
        let id = Int(idNum)
        if let method = o["method"]?.stringValue {
            return .request(id: id, method: method, params: o["params"] ?? .null)
        }
        if let err = o["error"], err != .null {
            let message = err["message"]?.stringValue ?? err.stringValue ?? "error"
            return .errorResponse(id: id, message: message)
        }
        return .response(id: id, result: o["result"] ?? .null)
    }
}

struct RequestEnvelope<P: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: P
}

/// JSON-RPC-ish client: numeric request ids, pending continuations with
/// timeouts, and a single inbound stream for connection changes + events.
public actor RPCClient {
    public nonisolated let inbound: AsyncStream<RPCInbound>
    private let inboundContinuation: AsyncStream<RPCInbound>.Continuation
    public nonisolated let transport: any HostTransport

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var pumpTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private let outbox: AsyncStream<(Int, Data)>.Continuation
    private let outboxStream: AsyncStream<(Int, Data)>
    public private(set) var isConnected = false
    public var defaultTimeout: Double

    public init(transport: any HostTransport, defaultTimeout: Double = 20) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
        (inbound, inboundContinuation) = AsyncStream.makeStream(of: RPCInbound.self, bufferingPolicy: .unbounded)
        (outboxStream, outbox) = AsyncStream.makeStream(of: (Int, Data).self, bufferingPolicy: .unbounded)
    }

    public func start() async {
        guard pumpTask == nil else { return }
        let events = transport.events
        pumpTask = Task { [weak self] in
            for await ev in events {
                guard let self else { return }
                await self.handle(ev)
            }
        }
        let stream = outboxStream
        let transport = transport
        senderTask = Task { [weak self] in
            for await (id, data) in stream {
                do {
                    try await transport.send(data)
                } catch {
                    await self?.failOne(id, error: RPCError.notConnected)
                }
            }
        }
        await transport.start()
    }

    public func stop() async {
        await transport.stop()
    }

    private func handle(_ ev: TransportEvent) {
        switch ev {
        case .connected:
            isConnected = true
            inboundContinuation.yield(.connected)
        case .disconnected(let reason):
            let wasConnected = isConnected
            isConnected = false
            failAll(RPCError.disconnected)
            if wasConnected || reason != .closed { inboundContinuation.yield(.disconnected(reason)) }
        case .message(let data):
            guard let msg = WireMessage.parse(data) else { return }
            switch msg {
            case .response(let id, let result):
                pending.removeValue(forKey: id)?.resume(returning: result)
            case .errorResponse(let id, let message):
                pending.removeValue(forKey: id)?.resume(throwing: RPCError.remote(message))
            case .event(let name, let data):
                inboundContinuation.yield(.event(name: name, data: data))
            case .request:
                break // host → client requests are not part of the protocol yet
            }
        }
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c.resume(throwing: error) }
    }

    /// Number of requests that hit their deadline (for tests / diagnostics).
    public private(set) var timeoutCount = 0

    private func expire(_ id: Int) {
        guard let c = pending.removeValue(forKey: id) else { return }
        c.resume(throwing: RPCError.timeout)
        timeoutCount += 1
        // No answer in time usually means a stale socket that still looks
        // open. Drop it and reconnect; the store re-syncs on `.connected`.
        if isConnected && reconnectOnTimeout {
            let transport = transport
            Task { await transport.forceReconnect() }
        }
    }

    /// Force a reconnect when a request times out (on by default).
    public var reconnectOnTimeout = true
    public func setReconnectOnTimeout(_ on: Bool) { reconnectOnTimeout = on }

    /// Sends a request and waits for its result.
    public func callRaw<P: Encodable & Sendable>(_ method: String, params: P, timeout: Double? = nil) async throws -> JSONValue {
        guard isConnected else { throw RPCError.notConnected }
        let id = nextID
        nextID += 1
        let data = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params))
        let limit = timeout ?? defaultTimeout
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
            pending[id] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                await self?.expire(id)
            }
            // FIFO outbox: requests hit the wire in call order (chat order matters).
            outbox.yield((id, data))
        }
    }

    private func failOne(_ id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    public func call<P: Encodable & Sendable, R: Decodable>(_ method: String, params: P, as: R.Type = R.self,
                                                            timeout: Double? = nil) async throws -> R {
        let raw = try await callRaw(method, params: params, timeout: timeout)
        do { return try raw.decode(R.self) } catch { throw RPCError.badResponse }
    }

    public var pendingCount: Int { pending.count }
}
