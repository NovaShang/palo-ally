import Foundation

/// How the app reaches a computer right now: straight to it (the same Mac,
/// the local network, Tailscale) or through the cloud relay. Every way is
/// the same end-to-end sealed channel; only the path differs.
public enum TransportRoute: String, Sendable, Equatable, Codable {
    case local, lan, tailscale, relay

    /// Lower is preferred when several direct ways answer.
    var rank: Int {
        switch self {
        case .local: 0
        case .lan: 1
        case .tailscale: 2
        case .relay: 3
        }
    }

    public var isDirect: Bool { self != .relay }
}

/// Where a computer says it can be reached without the relay (`hello`'s
/// `direct`, host/src/channels/localTunnel.ts): one port, its addresses.
public struct DirectEndpoints: Codable, Sendable, Equatable {
    public var port: Int
    public var addrs: [String]

    public init(port: Int, addrs: [String]) {
        self.port = port; self.addrs = addrs
    }

    /// Each address with its route, loopback first, then the local network,
    /// then Tailscale. IPv4 literals only (no names: App Transport Security
    /// lets plain ws:// through to IP addresses, the channel is sealed anyway).
    public var candidates: [(addr: String, route: TransportRoute)] {
        guard (1...65535).contains(port) else { return [] }
        var seen = Set<String>()
        let list = addrs.compactMap { a -> (String, TransportRoute)? in
            guard Self.isIPv4(a), seen.insert(a).inserted else { return nil }
            return (a, Self.route(of: a))
        }
        return list.enumerated().sorted { ($0.element.1.rank, $0.offset) < ($1.element.1.rank, $1.offset) }.map(\.element)
    }

    static func route(of addr: String) -> TransportRoute {
        if addr.hasPrefix("127.") { return .local }
        let parts = addr.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return .tailscale }
        return .lan
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && Int(p).map { (0...255).contains($0) } == true
        }
    }

    /// `ws://<addr>:<port>/v1/tunnel?<the query the relay gets>`.
    func url(addr: String, host: PairedHost, identity: DeviceIdentity, now: Date = Date()) throws -> URL {
        var c = URLComponents()
        c.scheme = "ws"
        c.host = addr
        c.port = port
        c.path = "/v1/tunnel"
        c.queryItems = try identity.tunnelQuery(daemonID: host.daemonID, deviceID: host.deviceID, now: now)
        guard let url = c.url else { throw URLError(.badURL) }
        return url
    }
}

/// The endpoints each computer last told, kept per computer (its daemon id)
/// so the next launch can try them before the relay.
public struct DirectEndpointCache: @unchecked Sendable { // UserDefaults is thread-safe
    let defaults: UserDefaults?
    static let prefix = "direct-endpoints."

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    public func load(_ daemonID: String) -> DirectEndpoints? {
        guard let data = defaults?.data(forKey: Self.prefix + daemonID) else { return nil }
        return try? JSONDecoder().decode(DirectEndpoints.self, from: data)
    }

    public func save(_ endpoints: DirectEndpoints?, for daemonID: String) {
        guard let defaults else { return }
        if let endpoints, let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: Self.prefix + daemonID)
        } else {
            defaults.removeObject(forKey: Self.prefix + daemonID)
        }
    }
}

/// A link to the computer whose E2E handshake is done, and how it goes.
struct OpenedLink: Sendable {
    let link: any UnitLink
    let channel: SecureChannel
    let route: TransportRoute
}

/// The direct candidates dialed at once: the best route that completes the
/// handshake wins, decided as soon as no better one is still trying (so a
/// local network address that answers isn't kept waiting on a Tailscale one
/// that never will). Links that lose, or arrive after the decision, are closed.
final class DirectRace: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Int]
    private var best: OpenedLink?
    private var decided = false
    private var result: OpenedLink??
    private var continuation: CheckedContinuation<OpenedLink?, Never>?

    init(ranks: [Int]) {
        running = ranks
    }

    func finished(rank: Int, _ opened: OpenedLink?) {
        var toClose: [any UnitLink] = []
        var resume: (CheckedContinuation<OpenedLink?, Never>, OpenedLink?)?
        lock.withLock {
            if let i = running.firstIndex(of: rank) { running.remove(at: i) }
            if decided {
                if let opened { toClose.append(opened.link) }
                return
            }
            if let opened {
                if let b = best, b.route.rank <= opened.route.rank {
                    toClose.append(opened.link)
                } else {
                    if let b = best { toClose.append(b.link) }
                    best = opened
                }
            }
            let done: Bool
            if let b = best { done = !running.contains { $0 < b.route.rank } } else { done = running.isEmpty }
            guard done else { return }
            decided = true
            if let c = continuation {
                continuation = nil
                resume = (c, best)
            } else {
                result = .some(best)
            }
        }
        for l in toClose { l.close() }
        if let (c, v) = resume { c.resume(returning: v) }
    }

    func wait() async -> OpenedLink? {
        await withCheckedContinuation { (c: CheckedContinuation<OpenedLink?, Never>) in
            let ready: OpenedLink?? = lock.withLock {
                if let r = result { return .some(r) }
                continuation = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}
