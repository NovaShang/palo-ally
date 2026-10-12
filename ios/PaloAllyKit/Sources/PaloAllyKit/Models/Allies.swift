import Foundation

// Allies (docs/allies-prd.md §7.5): other people's assistants this computer
// has met in person. The owner's assistant passes messages to them and back;
// every word that goes out is a draft the owner approves first.

/// What an Ally is to the owner. Both behave the same in the first version.
public enum AllyKind: String, TolerantStringEnum {
    /// 家人朋友
    case family
    /// 我的: the owner's own other computer.
    case mine
    case unknown
    public static let fallback = AllyKind.unknown
}

/// Which way an exchange went, as seen from this computer.
public enum AllyDirection: String, TolerantStringEnum {
    case incoming = "in"
    case outgoing = "out"
    case unknown
    public static let fallback = AllyDirection.unknown
}

/// An exchange's state. Outgoing: draft (waiting for the owner) → queued →
/// sent → delivered → seen, or rejected (not sent). Incoming ones arrive
/// delivered and become seen once the owner has had them on screen.
public enum AllyEntryStatus: String, TolerantStringEnum {
    case draft, queued, sent, delivered, seen, rejected, unknown
    public static let fallback = AllyEntryStatus.unknown
}

/// A proposed time, ISO 8601 with the sender's time zone (§7.3).
public struct AllySlot: Codable, Sendable, Hashable {
    public var start: String
    public var end: String

    public init(start: String, end: String) { self.start = start; self.end = end }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        start = l.string("start", or: "")
        end = l.string("end", or: "")
    }

    public var startDate: Date? { Self.date(start) }
    public var endDate: Date? { Self.date(end) }

    static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let d = Lenient.iso.date(from: t) ?? Lenient.isoNoFrac.date(from: t) { return d }
        if let n = Double(t) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        return nil
    }
}

/// One exchange with an Ally: a message either way, or a draft of one.
public struct AllyEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Which Ally. Not in the §6.1 record; present on `ally.entry` events
    /// when the host includes it, and filled in by the store otherwise.
    public var allyId: String?
    public var dir: AllyDirection
    public var ts: Int64
    public var text: String
    /// Marked 急: pushed to the other side right away.
    public var urgent: Bool
    public var slots: [AllySlot]?
    /// The entry this one answers.
    public var replyTo: String?
    public var status: AllyEntryStatus

    enum CodingKeys: String, CodingKey { case id, allyId, dir, ts, text, urgent, slots, replyTo, status }

    public init(id: String, allyId: String? = nil, dir: AllyDirection, ts: Int64, text: String, urgent: Bool = false,
                slots: [AllySlot]? = nil, replyTo: String? = nil, status: AllyEntryStatus) {
        self.id = id; self.allyId = allyId; self.dir = dir; self.ts = ts; self.text = text; self.urgent = urgent
        self.slots = slots; self.replyTo = replyTo; self.status = status
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        allyId = l.string("allyId")
        dir = l.decode(AllyDirection.self, "dir", or: .unknown)
        ts = l.millis("ts", or: 0)
        text = l.string("text", or: "")
        urgent = l.bool("urgent", or: false)
        slots = l.array(AllySlot.self, "slots")
        replyTo = l.string("replyTo")
        status = l.decode(AllyEntryStatus.self, "status", or: .unknown)
    }

    /// A draft waiting for the owner's 发送 / 改一下 / 不发.
    public var isPendingDraft: Bool { status == .draft && dir != .incoming }
}

/// An Ally as the list shows it.
public struct AllyInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: AllyKind
    /// What the other owner is called (「家人」, 「小林」).
    public var ownerName: String
    /// Their assistant's own name.
    public var assistantName: String
    public var online: Bool
    /// When their computer was last reached (ms); nil if never.
    public var lastSeen: Int64?
    /// The latest exchange either way.
    public var lastEntry: AllyEntry?

    enum CodingKeys: String, CodingKey { case id, kind, ownerName, assistantName, online, lastSeen, lastEntry }

    public init(id: String, kind: AllyKind, ownerName: String, assistantName: String, online: Bool,
                lastSeen: Int64? = nil, lastEntry: AllyEntry? = nil) {
        self.id = id; self.kind = kind; self.ownerName = ownerName; self.assistantName = assistantName
        self.online = online; self.lastSeen = lastSeen; self.lastEntry = lastEntry
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        kind = l.decode(AllyKind.self, "kind", or: .unknown)
        ownerName = l.string("ownerName", or: "")
        assistantName = l.string("assistantName", or: "")
        online = l.bool("online", or: false)
        // Required, but null means never reached.
        lastSeen = l.has("lastSeen") ? l.millis("lastSeen") : l.expect("lastSeen", l.millis("lastSeen"))
        lastEntry = l.decode(AllyEntry.self, "lastEntry")
    }

    /// Who they are, in a word: the other owner's name, else their assistant's.
    public var displayName: String {
        let o = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return o }
        let a = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "Ally" : a
    }

    /// 「家人的助理」: how their messages are labelled.
    public var assistantLabel: String { Self.assistantLabel(displayName) }

    public static func assistantLabel(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "对方的助理" }
        return n.hasSuffix("的助理") ? n : "\(n)的助理"
    }
}

/// An invite link from another computer's QR code (§7.2):
/// `paloally://ally?relay=…&daemon=…&code=…&hostkey=…&name=…&exp=…`.
/// The app reads only what it shows (the name, the expiry); the host checks
/// the rest when it accepts.
public struct AllyInviteLink: Sendable, Equatable {
    /// The link as received, handed to `ally.accept` unchanged.
    public var link: String
    /// The other owner's name, cleaned for display.
    public var name: String
    public var daemonID: String
    public var code: String
    public var expiresAt: Date?

    public init(link: String, name: String, daemonID: String, code: String, expiresAt: Date?) {
        self.link = link; self.name = name; self.daemonID = daemonID; self.code = code; self.expiresAt = expiresAt
    }

    /// Is this text a `paloally://ally` link at all (complete or not)?
    public static func isAllyLink(_ text: String) -> Bool {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return c.scheme?.lowercased() == "paloally" && c.host?.lowercased() == "ally"
    }

    /// nil unless it's a `paloally://ally` link carrying a computer and a code.
    public static func parse(_ text: String) -> AllyInviteLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAllyLink(trimmed), let c = URLComponents(string: trimmed) else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { if let v = item.value { q[item.name.lowercased()] = v } }
        guard let daemon = q["daemon"], !daemon.isEmpty, let code = q["code"], !code.isEmpty else { return nil }
        return AllyInviteLink(link: trimmed, name: cleanName(q["name"] ?? ""), daemonID: daemon, code: code,
                              expiresAt: q["exp"].flatMap(expiry))
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// The name comes from someone else's QR code: one line, no control
    /// characters, short.
    static func cleanName(_ s: String) -> String {
        let oneLine = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let t = String(String.UnicodeScalarView(oneLine)).trimmingCharacters(in: .whitespaces)
        return String(t.prefix(24))
    }

    /// `exp`: epoch milliseconds, epoch seconds, or ISO 8601.
    static func expiry(_ s: String) -> Date? {
        if let n = Double(s) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        return AllySlot.date(s)
    }
}

/// `ally.updated` payload. The PRD leaves its shape open, so any of:
/// `{allies: [...]}` (the whole list), `{ally: {...}}` or a bare AllyInfo
/// (one changed), `{removed: id}`. Anything else: fetch the list again.
public enum AllyUpdate: Sendable {
    case list([AllyInfo])
    case upsert(AllyInfo)
    case removed(String)
    case refetch

    public init(json: JSONValue) {
        if let removed = json["removed"]?.stringValue { self = .removed(removed); return }
        if case .array? = json["allies"], let r = try? json.decode(AlliesResult.self) { self = .list(r.allies); return }
        if let a = json["ally"], let ally = try? a.decode(AllyInfo.self) { self = .upsert(ally); return }
        if json["id"] != nil, json["ownerName"] != nil, let ally = try? json.decode(AllyInfo.self) { self = .upsert(ally); return }
        self = .refetch
    }
}

/// `ally.entry` payload: `{allyId, entry}`, or a bare entry (with its `allyId`).
public struct AllyEntryEvent: Sendable {
    public var allyId: String?
    public var entry: AllyEntry

    public init?(json: JSONValue) {
        if let e = json["entry"], let entry = try? e.decode(AllyEntry.self) {
            self.entry = entry
            allyId = json["allyId"]?.stringValue ?? entry.allyId
        } else if json["id"] != nil, json["dir"] != nil, let entry = try? json.decode(AllyEntry.self) {
            self.entry = entry
            allyId = entry.allyId
        } else {
            return nil
        }
    }
}
