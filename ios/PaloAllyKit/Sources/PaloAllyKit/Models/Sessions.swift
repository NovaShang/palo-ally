import Foundation

// Sessions (docs/sessions-prd.md §7): the Claude Code sessions on the
// owner's computer. Helpers are background sessions PaloAlly started for the
// owner; the rest are the owner's own, in a terminal or in the background.

/// Who started a session and how it runs.
public enum CCSessionKind: String, TolerantStringEnum {
    /// 帮手: a background session PaloAlly opened for the owner.
    case helper
    /// The owner's own, in a terminal.
    case terminal
    /// The owner's own background session (`claude --bg`).
    case background
    case unknown
    public static let fallback = CCSessionKind.unknown
}

/// What a session is doing (§6.1). `waiting` = it asked the owner something.
public enum CCSessionStatus: String, TolerantStringEnum {
    case busy, idle, waiting, stopped, unknown
    public static let fallback = CCSessionStatus.unknown
}

/// A session as the list shows it.
public struct CCSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Its project folder on the computer.
    public var cwd: String
    public var kind: CCSessionKind
    public var status: CCSessionStatus
    /// While waiting: what for, in the session's words.
    public var waitingFor: String?
    /// The last thing said in it.
    public var lastLine: String?
    /// How much of its context is in use (tokens). Shown as plain information.
    public var contextTokens: Int?
    public var updatedAt: Int64

    enum CodingKeys: String, CodingKey { case id, name, cwd, kind, status, waitingFor, lastLine, contextTokens, updatedAt }

    public init(id: String, name: String, cwd: String, kind: CCSessionKind, status: CCSessionStatus,
                waitingFor: String? = nil, lastLine: String? = nil, contextTokens: Int? = nil, updatedAt: Int64) {
        self.id = id; self.name = name; self.cwd = cwd; self.kind = kind; self.status = status
        self.waitingFor = waitingFor; self.lastLine = lastLine; self.contextTokens = contextTokens; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        name = l.string("name", or: "")
        cwd = l.string("cwd", or: "")
        kind = l.decode(CCSessionKind.self, "kind", or: .unknown)
        status = l.decode(CCSessionStatus.self, "status", or: .unknown)
        waitingFor = l.string("waitingFor")
        lastLine = l.string("lastLine")
        contextTokens = l.int("contextTokens")
        updatedAt = l.millis("updatedAt", or: 0)
    }

    public var isHelper: Bool { kind == .helper }
    /// Running: it can be stopped, and it hears what's sent to it.
    public var isRunning: Bool { status == .busy || status == .idle || status == .waiting }
    /// A background job the terminal can attach to (`claude attach`).
    public var canAttach: Bool { kind == .helper || kind == .background }

    /// The line that opens it in a terminal. Claude Code names a background
    /// job by its session id's first part (`claude attach 5d821f3c`).
    public var attachCommand: String {
        let first = id.split(separator: "-", maxSplits: 1).first.map(String.init) ?? id
        let short = first.count == 8 && first.allSatisfy(\.isHexDigit) && id.count > 8 ? first : id
        return "claude attach \(short)"
    }

    /// What it's called: its name, else its folder's.
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? "会话" : folder
    }

    /// The folder for people: the home folder as 「~」.
    public var shortCwd: String { Self.shortPath(cwd) }

    public static func shortPath(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // /Users/<name>/… and /home/<name>/… read as ~/…
        for root in ["/Users/", "/home/"] where p.hasPrefix(root) {
            let rest = p.dropFirst(root.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return p
    }

    /// The order the list shows: helpers first, then the owner's own; the
    /// host's order within each.
    public static func listOrder(_ all: [CCSession]) -> [CCSession] {
        all.filter(\.isHelper) + all.filter { !$0.isHelper }
    }
}

/// Who said a line in a session (§6.2 `origin`).
public enum CCMessageRole: String, TolerantStringEnum {
    /// The owner, typing at the computer.
    case owner
    /// The session itself.
    case assistant
    /// Another session (SendMessage between sessions); `from` names it.
    case peer
    /// Sent through PaloAlly: the owner's words from the app, or Palo's.
    case palo
    case unknown
    public static let fallback = CCMessageRole.unknown
}

/// One line of a session's conversation.
public struct CCMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var ts: Int64
    public var role: CCMessageRole
    public var text: String
    /// peer: which session it came from. palo: 「主人」 for the owner's words
    /// from the app, else the assistant's name for its own.
    public var from: String?

    enum CodingKeys: String, CodingKey { case id, ts, role, text, from }

    public init(id: String, ts: Int64, role: CCMessageRole, text: String, from: String? = nil) {
        self.id = id; self.ts = ts; self.role = role; self.text = text; self.from = from
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        ts = l.millis("ts", or: 0)
        role = l.decode(CCMessageRole.self, "role", or: .unknown)
        text = l.string("text", or: "")
        from = l.string("from")
    }

    /// What it says, as shown. Words sent through PaloAlly may arrive with
    /// the 「主人：」 or 「主人的助理：」 the host puts in front for the session (§6.4).
    public var shownText: String {
        guard role == .palo else { return text }
        for prefix in ["主人的助理：", "主人：", "主人:"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// Where an approval or a question came from, when it isn't the assistant's
/// own (§7): `{kind: "session", id, name}`.
public enum CardSourceKind: String, TolerantStringEnum {
    case session, unknown
    public static let fallback = CardSourceKind.unknown
}

public struct CardSource: Codable, Sendable, Hashable {
    public var kind: CardSourceKind
    public var id: String
    public var name: String

    enum CodingKeys: String, CodingKey { case kind, id, name }

    public init(kind: CardSourceKind = .session, id: String, name: String) {
        self.kind = kind; self.id = id; self.name = name
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        kind = l.decode(CardSourceKind.self, "kind", or: .unknown)
        id = l.string("id", or: "")
        name = l.string("name", or: "")
    }

    public var isSession: Bool { kind == .session }
}

// MARK: - Helper proposals

/// Where a helper proposal stands.
public enum HelperProposalStatus: String, TolerantStringEnum {
    /// Waiting for the owner's 开吧 / 不用.
    case pending
    /// 开吧: the helper was started.
    case created
    /// 不用.
    case discarded
    /// No longer on offer.
    case expired
    case unknown
    public static let fallback = HelperProposalStatus.unknown
}

/// The assistant proposing a helper (§6.6 `helper_propose`): a card in the
/// conversation, the helper starts only on the owner's 开吧.
public struct HelperProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Its project folder.
    public var cwd: String
    /// What it's for, in the assistant's words.
    public var duty: String
    /// The most it may spend a day, in US dollars.
    public var dailyUsd: Double?
    public var status: HelperProposalStatus
    /// Once started: the helper's session.
    public var sessionId: String?
    /// Why it didn't start, when it didn't.
    public var note: String?

    enum CodingKeys: String, CodingKey { case id, name, cwd, duty, dailyUsd, status, sessionId, note }

    public init(id: String, name: String, cwd: String, duty: String, dailyUsd: Double? = nil,
                status: HelperProposalStatus = .pending, sessionId: String? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.cwd = cwd; self.duty = duty; self.dailyUsd = dailyUsd
        self.status = status; self.sessionId = sessionId; self.note = note
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.expect("id", l.string("id") ?? l.string("proposalId")) ?? UUID().uuidString
        name = l.string("name", or: "")
        cwd = l.expect("cwd", l.string("cwd") ?? l.string("dir")) ?? ""
        duty = l.string("duty", or: "")
        dailyUsd = l.double("dailyUsd") ?? l.double("dailyLimitUsd")
        // A proposal that doesn't say is still on offer.
        status = l.decode(HelperProposalStatus.self, "status") ?? .pending
        sessionId = l.string("sessionId")
        note = l.string("note")
    }

    public var isPending: Bool { status == .pending }
}

// MARK: - Events

/// `sessions.updated` payload (§7): the list or one session changed. Read:
/// `{sessions}` (the whole list), `{session}` or a bare CCSession (one),
/// `{removed: id}`, or `{id}` alone (that one changed: fetch again).
/// Anything else: fetch the list again.
public enum SessionsUpdate: Sendable {
    case list([CCSession])
    case upsert(CCSession)
    case removed(String)
    case changed(String)
    case refetch

    public init(json: JSONValue) {
        if let removed = json["removed"]?.stringValue { self = .removed(removed); return }
        if case .array? = json["sessions"], let r = try? json.decode(SessionsResult.self) { self = .list(r.sessions); return }
        if let s = json["session"], case .object = s, let session = try? s.decode(CCSession.self) { self = .upsert(session); return }
        if json["id"] != nil, json["kind"] != nil, json["status"] != nil, let session = try? json.decode(CCSession.self) {
            self = .upsert(session); return
        }
        if let id = json["id"]?.stringValue ?? json["sessionId"]?.stringValue { self = .changed(id); return }
        self = .refetch
    }
}
