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
        self = Self(rawValue: s) ?? Self.fallback
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

/// Field accessors that never throw: a malformed field becomes nil, and the
/// caller supplies a default.
struct Lenient {
    let c: KeyedDecodingContainer<AnyKey>

    init(_ decoder: Decoder) throws {
        c = try decoder.container(keyedBy: AnyKey.self)
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
        return raw.compactMap { try? $0.decode(T.self) }
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
