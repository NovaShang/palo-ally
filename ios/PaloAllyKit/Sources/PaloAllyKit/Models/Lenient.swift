import Foundation

/// A string enum that decodes unknown raw values to a fallback case instead of
/// throwing. Host and client evolve independently; a new status string must
/// never make the client drop a whole sync payload.
public protocol TolerantStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

extension TolerantStringEnum {
    public init(from decoder: Decoder) throws {
        let s = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        if let v = Self(rawValue: s), v != Self.fallback {
            self = v
        } else {
            LenientDiagnostics.record(decoder.codingPath, "unknown \(Self.self) value \"\(s)\"")
            self = Self.fallback
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Generic coding key so we can read any field by name.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Strict-mode diagnostics for the tolerant decoders. Production decoding
/// never throws on a missing or malformed field; it falls back to a default.
/// Contract tests run decoding inside `LenientDiagnostics.collect` to learn
/// every place such a fallback happened (a required key missing, an unknown
/// enum value, a dropped array element).
public final class LenientDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var _issues: [String] = []

    public init() {}

    public var issues: [String] { lock.withLock { _issues } }

    func add(_ issue: String) { lock.withLock { _issues.append(issue) } }

    @TaskLocal static var current: LenientDiagnostics?

    static func record(_ path: [CodingKey], _ what: String) {
        guard let current else { return }
        let p = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        current.add(p.isEmpty ? what : "\(p): \(what)")
    }

    /// Runs `body` (synchronous decoding) and returns every fallback it hit.
    public static func collect<T>(_ body: () throws -> T) rethrows -> (value: T, issues: [String]) {
        let d = LenientDiagnostics()
        let v = try $current.withValue(d) { try body() }
        return (v, d.issues)
    }
}

/// Field accessors that never throw: a malformed field becomes nil, and the
/// caller supplies a default. The `or:` variants mark a field as required by
/// the protocol: they fall back the same way, but report the fallback when
/// strict diagnostics are on.
struct Lenient {
    let c: KeyedDecodingContainer<AnyKey>
    let path: [CodingKey]

    init(_ decoder: Decoder) throws {
        c = try decoder.container(keyedBy: AnyKey.self)
        path = decoder.codingPath
    }

    /// Marks `key` as required: reports a missing / malformed value in strict mode.
    func expect<T>(_ key: String, _ value: T?) -> T? {
        if value == nil { LenientDiagnostics.record(path, "missing required \"\(key)\"") }
        return value
    }

    private func required<T>(_ key: String, _ value: T?, _ fallback: () -> T) -> T {
        expect(key, value) ?? fallback()
    }

    func string(_ key: String, or fallback: @autoclosure () -> String) -> String { required(key, string(key), fallback) }
    func int(_ key: String, or fallback: @autoclosure () -> Int) -> Int { required(key, int(key), fallback) }
    func int64(_ key: String, or fallback: @autoclosure () -> Int64) -> Int64 { required(key, int64(key), fallback) }
    func bool(_ key: String, or fallback: @autoclosure () -> Bool) -> Bool { required(key, bool(key), fallback) }
    func millis(_ key: String, or fallback: @autoclosure () -> Int64) -> Int64 { required(key, millis(key), fallback) }
    func decode<T: Decodable>(_ type: T.Type, _ key: String, or fallback: @autoclosure () -> T) -> T {
        required(key, decode(type, key), fallback)
    }
    func array<T: Decodable>(_ type: T.Type, _ key: String, or fallback: @autoclosure () -> [T]) -> [T] {
        required(key, array(type, key), fallback)
    }

    func has(_ key: String) -> Bool { c.contains(AnyKey(key)) }

    func isNull(_ key: String) -> Bool {
        (try? c.decodeNil(forKey: AnyKey(key))) ?? false
    }

    func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        (try? c.decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil
    }

    func string(_ key: String) -> String? {
        let k = AnyKey(key)
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil { return s }
        if let n = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil {
            return n.rounded() == n ? String(Int64(n)) : String(n)
        }
        return nil
    }

    func double(_ key: String) -> Double? {
        let k = AnyKey(key)
        if let n = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return n }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil { return Double(s) }
        return nil
    }

    func int(_ key: String) -> Int? { double(key).map { Int($0) } }
    func int64(_ key: String) -> Int64? { double(key).map { Int64($0) } }

    func bool(_ key: String) -> Bool? {
        let k = AnyKey(key)
        if let b = (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil { return b }
        if let n = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return n != 0 }
        return nil
    }

    /// Epoch milliseconds. Accepts a number (ms), a numeric string, or an
    /// ISO-8601 string so a host that serialises Dates differently still works.
    func millis(_ key: String) -> Int64? {
        let k = AnyKey(key)
        if let n = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return Int64(n) }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil {
            if let n = Double(s) { return Int64(n) }
            if let d = Lenient.iso.date(from: s) ?? Lenient.isoNoFrac.date(from: s) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    /// Decode an array, skipping (not failing on) malformed elements.
    func array<T: Decodable>(_ type: T.Type, _ key: String) -> [T]? {
        guard let raw = decode([JSONValue].self, key) else { return nil }
        return raw.enumerated().compactMap { i, v in
            do { return try v.decode(T.self) } catch {
                LenientDiagnostics.record(path, "dropped \(key)[\(i)] (\(error))")
                return nil
            }
        }
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension Int64 {
    /// Interpret as epoch milliseconds.
    public var msDate: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}

extension Date {
    public var epochMillis: Int64 { Int64(timeIntervalSince1970 * 1000) }
}
