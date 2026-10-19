import Foundation

// Pals (docs/pals-prd.md §8): Claude Code sessions PaloAlly hosts itself,
// by resuming their records. A Pal's page is a remote Claude Code: its
// conversation streams in like the assistant's (`chat.delta` / `chat.message`
// carrying `pal`), the owner's words go in as typed (`pals.send`), and its
// approvals and questions are ordinary cards with `source.kind == "pal"`.
// The computer's other live sessions come with the list, to adopt.

/// What a Pal is doing (§8). `waiting` = a card waits on the owner;
/// `starting` = its process is coming up (adopting, after a restart, or
/// being woken); `asleep` = idle a while, its process ended (§12): its
/// conversation is all there, and words for it wake it first.
public enum PalStatus: String, TolerantStringEnum {
    case busy, idle, waiting, starting, stopped, asleep, unknown
    public static let fallback = PalStatus.unknown
}

/// What the owner should know about a session at a glance (workbench-rpc §1),
/// the host's reading of its state: `waiting` = a card waits on the owner;
/// `working` = in a turn; `done` = a turn ended that the owner hasn't looked
/// at; `idle` = anything else (asleep, starting and stopped too).
public enum PalAttention: String, TolerantStringEnum {
    case working, waiting, done, idle, unknown
    public static let fallback = PalAttention.unknown
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
    /// What the first turn after its last wake cost (USD): a cold start
    /// writes its context to the cache again (§12).
    public var lastWakeUsd: Double?
    public var createdBy: PalCreator
    /// Busy: what it's doing, in plain words.
    public var activity: String?
    /// Stopped: why (its spending limit, it couldn't start, it's open elsewhere).
    public var note: String?
    public var updatedAt: Int64?
    /// What the owner should see in the dot (workbench-rpc §1). A host from
    /// before the workbench doesn't say: it's worked out from `status`.
    public var attention: PalAttention
    /// When its last turn ended normally, and when the owner last looked
    /// (every device shares it).
    public var finishedAt: Int64?
    public var seenAt: Int64?
    /// Context used, 0 to 100.
    public var contextPct: Int?
    /// The workspace it belongs to, if any (at most one).
    public var workspaceId: String?
    /// Thinking depth; nil follows the default.
    public var effort: String?
    /// Not touched for a few days and in no workspace: it's listed under
    /// 以前的, not among the sessions.
    public var folded: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, cwd, sessionId, status, lastLine, pending, model, lastWakeUsd, createdBy, activity, note, updatedAt
        case attention, finishedAt, seenAt, contextPct, workspaceId, effort, folded
    }

    public init(id: String, name: String, cwd: String, sessionId: String, status: PalStatus, lastLine: String? = nil,
                pending: Int = 0, model: String? = nil, createdBy: PalCreator = .owner, activity: String? = nil,
                note: String? = nil, updatedAt: Int64? = nil, lastWakeUsd: Double? = nil,
                attention: PalAttention? = nil, finishedAt: Int64? = nil, seenAt: Int64? = nil, contextPct: Int? = nil,
                workspaceId: String? = nil, effort: String? = nil, folded: Bool = false) {
        self.id = id; self.name = name; self.cwd = cwd; self.sessionId = sessionId; self.status = status
        self.lastLine = lastLine; self.pending = pending; self.model = model; self.createdBy = createdBy
        self.activity = activity; self.note = note; self.updatedAt = updatedAt; self.lastWakeUsd = lastWakeUsd
        self.attention = attention ?? Self.derivedAttention(status: status, pending: pending, finishedAt: finishedAt, seenAt: seenAt)
        self.finishedAt = finishedAt; self.seenAt = seenAt; self.contextPct = contextPct
        self.workspaceId = workspaceId; self.effort = effort; self.folded = folded
    }

    /// The host's rule (workbench-rpc §1): a card waiting wins; then a turn
    /// running; then a finished turn the owner hasn't looked at; else idle.
    public static func derivedAttention(status: PalStatus, pending: Int, finishedAt: Int64?, seenAt: Int64?) -> PalAttention {
        if pending > 0 || status == .waiting { return .waiting }
        if status == .busy { return .working }
        if status != .stopped, let f = finishedAt, f > (seenAt ?? 0) { return .done }
        return .idle
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
        lastWakeUsd = l.double("lastWakeUsd")
        createdBy = l.decode(PalCreator.self, "createdBy", or: .unknown)
        activity = l.string("activity")
        note = l.string("note")
        updatedAt = l.millis("updatedAt")
        finishedAt = l.millis("finishedAt")
        seenAt = l.millis("seenAt")
        contextPct = l.int("contextPct")
        workspaceId = l.string("workspaceId")
        effort = l.string("effort")
        folded = l.bool("folded") ?? false
        // New fields a host from before the workbench lacks: worked out, not reported as missing.
        if let a = l.decode(PalAttention.self, "attention"), a != .unknown {
            attention = a
        } else {
            attention = Self.derivedAttention(status: status, pending: pending, finishedAt: finishedAt, seenAt: seenAt)
        }
    }

    /// In a turn: working, or stopped in it on a card the owner must answer.
    public var inTurn: Bool { status == .busy || status == .waiting }

    /// Asleep (§12): no process; words for it wake it first.
    public var isAsleep: Bool { status == .asleep }

    /// The list's order: the awake ones, then those asleep, each the most
    /// lately used first (as the host has them when it doesn't say).
    public static func listed(_ pals: [Pal]) -> [Pal] {
        pals.enumerated()
            .sorted { a, b in
                if a.element.isAsleep != b.element.isAsleep { return !a.element.isAsleep }
                let (x, y) = (a.element.updatedAt ?? 0, b.element.updatedAt ?? 0)
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
    }

    /// What it's called: its name, else its folder's.
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Not named yet: the host's `session-<short id>` shows as 新会话.
        if Self.isUnnamed(n) { return loc("新会话") }
        if !n.isEmpty { return n }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? "Pal" : folder
    }

    /// The host's placeholder name for a session nobody has named or spoken in.
    public static func isUnnamed(_ name: String) -> Bool {
        name.range(of: #"^session-[0-9a-f]{4,}$"#, options: .regularExpression) != nil
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

/// `pals.wake {id}` → `{pal}`: an asleep Pal resumed (§12; the host
/// answers once it's up). Words for it (`pals.send`) wake it as well.
public struct PalWakeResult: Decodable, Sendable {
    public var pal: Pal?
    public init(pal: Pal?) { self.pal = pal }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        pal = l.expect("pal", l.decode(Pal.self, "pal"))
    }
}

/// `pals.rename {id, name}` (§13): Claude Code's title for the session
/// changes too; a name another Pal has comes back with a number.
public struct PalRenameParams: Codable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// `pals.rename → {pal}`, as `pals.wake` answers.
public typealias PalRenameResult = PalWakeResult

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

/// `pals.send {id, text, clientMsgId?, attachments?}` → `{id, seq}`: the
/// owner's words, as typed, into a Pal, with images and files as Palo takes
/// them (media ids from media.upload / uploadChunk; pals-prd §15).
public struct PalSendParams: Codable, Sendable {
    public var id: String
    public var text: String
    public var clientMsgId: String?
    public var attachments: [String]?
    public init(id: String, text: String, clientMsgId: String? = nil, attachments: [String]? = nil) {
        self.id = id; self.text = text; self.clientMsgId = clientMsgId; self.attachments = attachments
    }
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

// MARK: - Recent conversations (§10)

/// A Claude Code conversation on the computer that has ended (in the last
/// 30 days), not a Pal and not PaloAlly's own: `pals.adopt {sessionId}`
/// resumes it as a Pal straight away, with no process to stop.
public struct RecentSession: Codable, Sendable, Hashable, Identifiable {
    public var sessionId: String
    /// Its project folder.
    public var cwd: String
    /// Its custom title, else Claude Code's summary, else the start of its first words.
    public var title: String
    /// When its record last changed (epoch ms).
    public var lastModified: Int64
    /// Its record's size in bytes.
    public var size: Int64

    public var id: String { sessionId }

    enum CodingKeys: String, CodingKey { case sessionId, cwd, title, lastModified, size }

    public init(sessionId: String, cwd: String, title: String, lastModified: Int64, size: Int64 = 0) {
        self.sessionId = sessionId; self.cwd = cwd; self.title = title; self.lastModified = lastModified; self.size = size
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        sessionId = l.string("sessionId", or: "")
        cwd = l.string("cwd", or: "")
        title = l.string("title", or: "")
        lastModified = l.millis("lastModified", or: 0)
        size = l.int64("size", or: 0)
    }

    /// What it's called: its title on one line, else its folder's name.
    public var displayTitle: String {
        let t = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? RecentFolder.name(of: cwd) : t
    }
}

/// `pals.recent {folder?, limit?}`: one folder's, or all of them.
public struct PalsRecentParams: Codable, Sendable {
    public var folder: String?
    public var limit: Int?
    public init(folder: String? = nil, limit: Int? = nil) { self.folder = folder; self.limit = limit }
}

/// `pals.recent → {sessions}`.
public struct PalsRecentResult: Decodable, Sendable {
    public var sessions: [RecentSession]
    public init(sessions: [RecentSession]) { self.sessions = sessions }
    public init(from decoder: Decoder) throws {
        sessions = try Lenient(decoder).array(RecentSession.self, "sessions", or: [])
    }
}

/// One folder's recent conversations, newest first.
public struct RecentFolder: Sendable, Hashable, Identifiable {
    public var cwd: String
    public var sessions: [RecentSession]
    public var id: String { cwd }

    /// Its last path component (「site」), the home folder as 「~」.
    public var name: String { Self.name(of: cwd) }
    /// The whole path, the home folder as 「~」.
    public var path: String { CCSession.shortPath(cwd) }

    static func name(of cwd: String) -> String {
        let short = CCSession.shortPath(cwd)
        let last = (short as NSString).lastPathComponent
        return last.isEmpty ? short : last
    }

    /// By folder: the folder used most lately first, each one's newest first.
    /// With a query, only those whose title or folder has it (any case).
    public static func group(_ sessions: [RecentSession], matching query: String = "") -> [RecentFolder] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = q.isEmpty ? sessions : sessions.filter {
            $0.displayTitle.lowercased().contains(q) || CCSession.shortPath($0.cwd).lowercased().contains(q)
        }
        var byFolder: [String: [RecentSession]] = [:]
        for s in shown { byFolder[s.cwd, default: []].append(s) }
        return byFolder.map { cwd, list in
            RecentFolder(cwd: cwd, sessions: list.sorted { ($0.lastModified, $0.sessionId) > ($1.lastModified, $1.sessionId) })
        }
        .sorted { a, b in
            let (x, y) = (a.sessions.first?.lastModified ?? 0, b.sessions.first?.lastModified ?? 0)
            return x != y ? x > y : a.cwd < b.cwd
        }
    }
}

// MARK: - The assistant proposing to adopt one (§10, `pal_adopt`)

/// Where a `pal_adopt` card stands.
public enum PalAdoptProposalStatus: String, TolerantStringEnum {
    /// Waiting for the owner's 接管 / 不用.
    case pending
    /// 接管: it's a Pal now (`palId`).
    case adopted
    /// 不用.
    case discarded
    /// 接管 didn't work: `note` says why. Still on offer: 接管 can be tapped again.
    case failed
    case unknown
    public static let fallback = PalAdoptProposalStatus.unknown
}

/// The assistant proposing to adopt a recent conversation: a card in its
/// conversation (`kind: "pal_adopt"`); nothing is adopted until the owner's
/// 接管 (`helper.decide`, as a helper proposal).
public struct PalAdoptProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The conversation to adopt.
    public var sessionId: String
    public var cwd: String
    public var title: String
    public var status: PalAdoptProposalStatus
    /// Adopted: the Pal it became.
    public var palId: String?
    /// Why it wasn't adopted, when it wasn't.
    public var note: String?

    enum CodingKeys: String, CodingKey { case id, sessionId, cwd, title, status, palId, note }

    public init(id: String, sessionId: String, cwd: String, title: String, status: PalAdoptProposalStatus = .pending,
                palId: String? = nil, note: String? = nil) {
        self.id = id; self.sessionId = sessionId; self.cwd = cwd; self.title = title; self.status = status
        self.palId = palId; self.note = note
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        sessionId = l.string("sessionId", or: "")
        cwd = l.string("cwd", or: "")
        title = l.string("title", or: "")
        status = l.decode(PalAdoptProposalStatus.self, "status", or: .pending)
        palId = l.string("palId")
        note = l.string("note")
    }

    public var isPending: Bool { status == .pending }

    /// Its title on one line, else its folder's name.
    public var displayTitle: String {
        RecentSession(sessionId: sessionId, cwd: cwd, title: title, lastModified: 0).displayTitle
    }

    /// The folder for people: the home folder as 「~」.
    public var shortCwd: String { CCSession.shortPath(cwd) }
}
