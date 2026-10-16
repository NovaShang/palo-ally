import CryptoKit
import Foundation

/// `paloally://pair?relay=<url>&daemon=<daemon_id>&code=<6 digits>&hostkey=<base64url>`
public struct PairingLink: Sendable, Equatable {
    public var relay: URL
    public var daemonID: String
    /// May be empty if the user will type the code separately.
    public var code: String
    /// Raw 32-byte host Ed25519 public key.
    public var hostKey: Data

    public static let defaultRelay = URL(string: "https://relay.bentoai.dev")!

    public init(relay: URL, daemonID: String, code: String, hostKey: Data) {
        self.relay = relay; self.daemonID = daemonID; self.code = code; self.hostKey = hostKey
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case notAPairingLink, missingDaemon, badHostKey, badRelay, badCode
        public var errorDescription: String? {
            switch self {
            case .notAPairingLink: "这不是配对链接"
            case .missingDaemon, .badHostKey, .badRelay: "配对链接不完整，请重新复制一次"
            case .badCode: "配对码应该是 6 位数字"
            }
        }
    }

    /// Accepts the link itself, or text containing it (e.g. a pasted message).
    /// `code` is optional at parse time; `requireCode` enforces it.
    public static func parse(_ text: String, requireCode: Bool = false) throws -> PairingLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let r = trimmed.range(of: "paloally://", options: .caseInsensitive) {
            candidate = String(trimmed[r.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" && $0 != "<" && $0 != ">" })
        } else {
            candidate = trimmed
        }
        guard let comps = URLComponents(string: candidate),
              comps.scheme?.lowercased() == "paloally",
              (comps.host?.lowercased() == "pair" || comps.path.lowercased().hasSuffix("pair"))
        else { throw ParseError.notAPairingLink }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { if let v = item.value { q[item.name.lowercased()] = v } }

        let relayString = q["relay"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultRelay.absoluteString
        guard let relay = URL(string: relayString), let scheme = relay.scheme?.lowercased(),
              ["https", "http", "wss", "ws"].contains(scheme), relay.host != nil
        else { throw ParseError.badRelay }
        guard let daemon = q["daemon"], !daemon.isEmpty else { throw ParseError.missingDaemon }
        guard let hk = q["hostkey"], let hostKey = Data(base64URLEncoded: hk), hostKey.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: hostKey)) != nil
        else { throw ParseError.badHostKey }
        let code = (q["code"] ?? "").filter { !$0.isWhitespace }
        if !code.isEmpty || requireCode {
            guard isValidCode(code) else { throw ParseError.badCode }
        }
        return PairingLink(relay: relay, daemonID: daemon, code: code, hostKey: hostKey)
    }

    public static func isValidCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The host key's fingerprint as the host reports it in `pair.ack`:
    /// `SHA256:` + base64 of SHA-256(raw key), without padding.
    public static func fingerprint(of hostKey: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: hostKey)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "paloally"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "relay", value: relay.absoluteString),
            URLQueryItem(name: "daemon", value: daemonID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "hostkey", value: hostKey.base64URLEncodedString()),
        ]
        return c.url!
    }
}

/// Everything needed to reconnect to a paired host. Contains no secrets (the
/// device private key lives in the SecretStore).
public struct PairedHost: Codable, Sendable, Equatable {
    public var relay: URL
    public var daemonID: String
    public var deviceID: String
    public var hostKey: Data
    public var hostLabel: String
    public var hostFingerprint: String
    public var pairedAt: Date

    public init(relay: URL, daemonID: String, deviceID: String, hostKey: Data, hostLabel: String,
                hostFingerprint: String, pairedAt: Date = Date()) {
        self.relay = relay; self.daemonID = daemonID; self.deviceID = deviceID; self.hostKey = hostKey
        self.hostLabel = hostLabel; self.hostFingerprint = hostFingerprint; self.pairedAt = pairedAt
    }

    public var hostPublicKey: Curve25519.Signing.PublicKey? {
        try? Curve25519.Signing.PublicKey(rawRepresentation: hostKey)
    }

    static let account = "paired-host"

    public static func load(from store: SecretStore) -> PairedHost? {
        guard let data = try? store.load(account) else { return nil }
        return try? JSONDecoder().decode(PairedHost.self, from: data)
    }

    public func save(to store: SecretStore) throws {
        try store.save(JSONEncoder().encode(self), for: Self.account)
    }

    public static func forget(in store: SecretStore) {
        try? store.delete(account)
    }

    /// `wss://…/v1/tunnel?daemon_id&device_id&ts&pubkey&sig`.
    public func tunnelURL(identity: DeviceIdentity, now: Date = Date()) throws -> URL {
        guard var c = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "wss"
        case "http": c.scheme = "ws"
        default: break
        }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/v1/tunnel"
        c.queryItems = try identity.tunnelQuery(daemonID: daemonID, deviceID: deviceID, now: now)
        guard let url = c.url else { throw URLError(.badURL) }
        return url
    }
}

public enum PairingError: Error, LocalizedError, Equatable {
    case invalidCode
    /// The computer that answered isn't the one the QR code names.
    case wrongHost
    case network(String)
    case rejected(status: Int, message: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return "配对码应该是 6 位数字"
        case .wrongHost: return "回应的电脑和二维码上的对不上，在电脑上重新生成一个再扫"
        case .network: return "网络好像不太通，稍后再试试"
        case .rejected(let status, let message):
            switch status {
            case 401: return "配对码不对，再核对一下"
            case 429: return "试错太多次了，等一分钟再来"
            case 503: return "电脑那边好像没开着，先打开它再试"
            case 400 where message.contains("no pairing window"): return "配对码过期了，在电脑上重新生成一个"
            default: return "没能连上（\(message)）"
            }
        case .malformedResponse: return "电脑那边的回复看不懂，可能需要更新一下"
        }
    }
}

/// HTTP abstraction so pairing can be unit tested.
public protocol HTTPClient: Sendable {
    func post(_ url: URL, json: Data) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = json
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// `POST <relay>/v1/pair?daemon_id=…` (relay/src/daemon-do.ts handlePair).
public struct PairingClient: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    struct Body: Encodable { let code: String; let device_pubkey: String; let device_label: String }

    struct Ack: Decodable {
        var status: String?
        var device_id: String?
        var host_fingerprint: String?
        var daemon_label: String?
        var error: String?
    }

    public static func pairURL(relay: URL, daemonID: String) -> URL {
        var c = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        switch c.scheme?.lowercased() {
        case "wss": c.scheme = "https"
        case "ws": c.scheme = "http"
        default: break
        }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/v1/pair"
        c.queryItems = [URLQueryItem(name: "daemon_id", value: daemonID)]
        return c.url!
    }

    public func pair(link: PairingLink, identity: DeviceIdentity, deviceLabel: String) async throws -> PairedHost {
        guard PairingLink.isValidCode(link.code) else { throw PairingError.invalidCode }
        let body = try JSONEncoder().encode(Body(code: link.code, device_pubkey: identity.sshWirePublicKeyBase64,
                                                 device_label: deviceLabel))
        let data: Data
        let status: Int
        do {
            (data, status) = try await http.post(Self.pairURL(relay: link.relay, daemonID: link.daemonID), json: body)
        } catch {
            throw PairingError.network(error.localizedDescription)
        }
        let ack = (try? JSONDecoder().decode(Ack.self, from: data)) ?? Ack()
        guard status == 200, ack.status == "ok" else {
            throw PairingError.rejected(status: status, message: ack.error ?? ack.status ?? "HTTP \(status)")
        }
        guard let deviceID = ack.device_id, !deviceID.isEmpty else { throw PairingError.malformedResponse }
        // The computer says which key it holds; it must be the one in the link
        // (allies-prd §7.2). An older relay that drops the field is let through:
        // the encrypted link checks the key again on every connection.
        if let fp = ack.host_fingerprint, !fp.isEmpty, fp != PairingLink.fingerprint(of: link.hostKey) {
            throw PairingError.wrongHost
        }
        return PairedHost(relay: link.relay, daemonID: link.daemonID, deviceID: deviceID, hostKey: link.hostKey,
                          hostLabel: ack.daemon_label ?? "", hostFingerprint: ack.host_fingerprint ?? "")
    }
}

/// `paloally:` links (a computer's pairing link, an Ally's invite) on their
/// way into the app.
public enum AppLink {
    public static let scheme = "paloally"

    /// A link for the app: `paloally:` or the scheme this build registered
    /// instead (a test build's, e.g. `paloally-devtest`), given back as
    /// `paloally:` for the parsers. nil for anything else.
    public static func normalized(_ url: URL, ownScheme: String = scheme) -> URL? {
        guard let s = url.scheme?.lowercased(), s == scheme || s == ownScheme.lowercased() else { return nil }
        guard s != scheme, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = scheme
        return c.url
    }

    /// Inline Markdown with each bare `paloally://` link in angle brackets,
    /// so it comes out as a link (Markdown links only bare web addresses).
    /// Links already in `<…>`, `[…](…)` or a code span stay as they are.
    public static func markingBareLinks(in markdown: String) -> String {
        guard markdown.range(of: "paloally://", options: .caseInsensitive) != nil else { return markdown }
        let ns = markdown as NSString
        let out = NSMutableString(string: markdown)
        for m in bareLink.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            var range = m.range
            // Sentence punctuation after a link isn't part of it.
            while range.length > 0, ".,;:!?'*".contains(Character(ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)))) {
                range.length -= 1
            }
            if range.location > 0, "<([`".contains(Character(ns.substring(with: NSRange(location: range.location - 1, length: 1)))) { continue }
            // Inside a code span: an odd number of backticks before it on its line.
            let lineStart = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: range.location)).location
            let from = lineStart == NSNotFound ? 0 : lineStart + 1
            let before = ns.substring(with: NSRange(location: from, length: range.location - from))
            if before.filter({ $0 == "`" }).count % 2 == 1 { continue }
            out.replaceCharacters(in: range, with: "<\(ns.substring(with: range))>")
        }
        return out as String
    }

    private static let bareLink = try! NSRegularExpression(pattern: "paloally://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+", options: .caseInsensitive)
}
