import Foundation

// Pals (docs/pals-prd.md §8): Claude Code sessions PaloAlly hosts itself,
// by resuming their records. A Pal's page is a remote Claude Code: its
// conversation streams in like the assistant's (`chat.delta` / `chat.message`
// carrying `pal`), the owner's words go in as typed (`pals.send`), and its
// approvals and questions are ordinary cards with `source.kind == "pal"`.
// The computer's other live sessions come with the list, to adopt.

/// What a Pal is doing (§8). `waiting` = a card waits on the owner;
/// `starting` = its process is coming up (adopting, or after a restart).
public enum PalStatus: String, TolerantStringEnum {
    case busy, idle, waiting, starting, stopped, unknown
    public static let fallback = PalStatus.unknown
}

/// Who made it a Pal: the owner adopted it, or the assistant opened it.
public enum PalCreator: String, TolerantStringEnum {
    case owner, palo, unknown
    public static let fallback = PalCreator.unknown
}

/// A Pal as the list shows it.
public struct Pal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Its fixed name: the list's, and the one the assistant reaches it by.
    public var name: String
    /// Its project folder on the computer.
    public var cwd: String
    /// The Claude Code session it resumes (`claude --resume <sessionId>`).
    public var sessionId: String
    public var status: PalStatus
    /// The last thing said in it.
    public var lastLine: String?
    /// How many of its cards wait on the owner.
    public var pending: Int
    public var model: String?
    public var createdBy: PalCreator
    /// Busy: what it's doing, in plain words.
    public var activity: String?
    /// Stopped: why (its spending limit, it couldn't start, it's open elsewhere).
    public var note: String?
    public var updatedAt: Int64?

    enum CodingKeys: String, CodingKey { case id, name, cwd, sessionId, status, lastLine, pending, model, createdBy, activity, note, updatedAt }

    public init(id: String, name: String, cwd: String, sessionId: String, status: PalStatus, lastLine: String? = nil,
                pending: Int = 0, model: String? = nil, createdBy: PalCreator = .owner, activity: String? = nil,
                note: String? = nil, updatedAt: Int64? = nil) {
        self.id = id; self.name = name; self.cwd = cwd; self.sessionId = sessionId; self.status = status
        self.lastLine = lastLine; self.pending = pending; self.model = model; self.createdBy = createdBy
        self.activity = activity; self.note = note; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        name = l.string("name", or: "")
        cwd = l.string("cwd", or: "")
        sessionId = l.string("sessionId", or: "")
        status = l.decode(PalStatus.self, "status", or: .unknown)
        lastLine = l.string("lastLine")
        pending = l.int("pending", or: 0)
        model = l.string("model")
        createdBy = l.decode(PalCreator.self, "createdBy", or: .unknown)
        activity = l.string("activity")
        note = l.string("note")
        updatedAt = l.millis("updatedAt")
    }

    /// In a turn: working, or stopped in it on a card the owner must answer.
    public var inTurn: Bool { status == .busy || status == .waiting }

    /// What it's called: its name, else its folder's.
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? "Pal" : folder
    }

    /// The folder for people: the home folder as 「~」.
    public var shortCwd: String { CCSession.shortPath(cwd) }

    /// The line that opens its record in a terminal, when the host gave none.
    public var resumeCommand: String { "claude --resume \(sessionId.isEmpty ? id : sessionId)" }
}

/// `pals.list → {pals, others, hooks}`: the Pals, the computer's other live
/// Claude Code sessions (to adopt), and whether the global hooks are on.
public struct PalsResult: Decodable, Sendable {
    public var pals: [Pal]
    public var others: [CCSession]
    public var hooks: Bool?

    public init(pals: [Pal], others: [CCSession] = [], hooks: Bool? = nil) {
        self.pals = pals; self.others = others; self.hooks = hooks
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        pals = l.array(Pal.self, "pals", or: [])
        others = l.array(CCSession.self, "others", or: [])
        hooks = l.expect("hooks", l.bool("hooks"))
    }
}

/// `pals.adopt {sessionId}`; with `cancel`, the host stops waiting for that
/// terminal session to be quit.
public struct PalAdoptParams: Codable, Sendable {
    public var sessionId: String
    public var cancel: Bool?
    public init(sessionId: String, cancel: Bool? = nil) { self.sessionId = sessionId; self.cancel = cancel }
}

/// Why an adoption hasn't finished yet.
public enum PalAdoptWaiting: String, TolerantStringEnum {
    /// A session in a terminal: the owner quits it there (/exit), then the
    /// host carries on by itself.
    case exitInTerminal = "exit-in-terminal"
    case unknown
    public static let fallback = PalAdoptWaiting.unknown
}

/// `pals.adopt → {pal}` once it's a Pal, or `{waiting: "exit-in-terminal"}`.
/// Cancelling: `{cancelled}` (whether the host was waiting), with `pal` when
/// it had become one already.
public struct PalAdoptResult: Decodable, Sendable {
    public var pal: Pal?
    public var waiting: PalAdoptWaiting?
    public var cancelled: Bool?

    public init(pal: Pal? = nil, waiting: PalAdoptWaiting? = nil, cancelled: Bool? = nil) {
        self.pal = pal; self.waiting = waiting; self.cancelled = cancelled
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        pal = l.decode(Pal.self, "pal")
        waiting = l.decode(PalAdoptWaiting.self, "waiting")
        cancelled = l.bool("cancelled")
        if pal == nil && waiting == nil && cancelled == nil { _ = l.expect("pal", pal) }
    }
}

/// `pals.release → {resumeCommand}`: the line that picks it up in a terminal.
public struct PalReleaseResult: Decodable, Sendable {
    public var resumeCommand: String
    public init(resumeCommand: String) { self.resumeCommand = resumeCommand }
    public init(from decoder: Decoder) throws {
        resumeCommand = try Lenient(decoder).string("resumeCommand", or: "")
    }
}

/// `pals.history {id, before?, limit?}`: a Pal's conversation, the newest
/// page, or the one before message `before` (its id). `{messages}` as
/// `chat.history` gives them.
public struct PalHistoryParams: Codable, Sendable {
    public var id: String
    public var before: String?
    public var limit: Int?
    public init(id: String, before: String? = nil, limit: Int? = nil) { self.id = id; self.before = before; self.limit = limit }
}

/// `pals.history → {messages, streaming?}`: oldest first, as `chat.history`
/// gives them (their `seq` is the host's, and may skip); the newest page
/// also has the reply being written right now, whose later `chat.delta`
/// events append to it (as `sync` gives it).
public struct PalHistoryResult: Decodable, Sendable {
    public var messages: [ChatMessage]
    public var streaming: SyncResult.Streaming?
    public init(messages: [ChatMessage], streaming: SyncResult.Streaming? = nil) { self.messages = messages; self.streaming = streaming }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        messages = l.array(ChatMessage.self, "messages", or: [])
        streaming = l.decode(SyncResult.Streaming.self, "streaming").flatMap { $0.id.isEmpty ? nil : $0 }
    }
}

/// `pals.send {id, text, clientMsgId?}` → `{id, seq}`: the owner's words,
/// as typed, into a Pal.
public struct PalSendParams: Codable, Sendable {
    public var id: String
    public var text: String
    public var clientMsgId: String?
    public init(id: String, text: String, clientMsgId: String? = nil) { self.id = id; self.text = text; self.clientMsgId = clientMsgId }
}

/// `pals.updated`: read as the whole list (`{pals, others?, hooks?}`, as
/// `pals.list` gives it), one Pal (`{pal}`), `{removed: id}`; anything else:
/// fetch the list again.
public enum PalsUpdate: Sendable {
    case list(PalsResult, hasOthers: Bool)
    case upsert(Pal)
    case removed(String)
    case refetch

    public init(json: JSONValue) {
        if let removed = json["removed"]?.stringValue { self = .removed(removed); return }
        if case .array? = json["pals"], let r = try? json.decode(PalsResult.self) {
            var hasOthers = false
            if case .array? = json["others"] { hasOthers = true }
            self = .list(r, hasOthers: hasOthers)
            return
        }
        if let p = json["pal"], case .object = p, let pal = try? p.decode(Pal.self) { self = .upsert(pal); return }
        self = .refetch
    }
}
