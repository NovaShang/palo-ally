import Foundation

// Wire models — design.md §5.3. Every decoder is tolerant: unknown fields are
// ignored, unknown enum strings map to `.unknown`, malformed optional fields
// become nil, and missing required fields fall back to neutral defaults.

// MARK: - Enums

public enum ChatRole: String, TolerantStringEnum {
    case user, assistant, system, unknown
    public static let fallback = ChatRole.unknown
}

public enum ChatKind: String, TolerantStringEnum {
    case text, task, approval, notice, unknown
    public static let fallback = ChatKind.unknown
}

public enum ChatChannel: String, TolerantStringEnum {
    case app, cli, wechat, probe, schedule, system, unknown
    public static let fallback = ChatChannel.unknown
}

public enum TaskStatus: String, TolerantStringEnum {
    case running, done, failed, stopped, unknown
    case needsInput = "needs_input"
    public static let fallback = TaskStatus.unknown
}

public enum TaskSource: String, TolerantStringEnum {
    case auto, report, unknown
    public static let fallback = TaskSource.unknown
}

public enum ActivityKind: String, TolerantStringEnum {
    case text, unknown
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    public static let fallback = ActivityKind.unknown
}

public enum ApprovalStatus: String, TolerantStringEnum {
    case pending, allowed, denied, expired, unknown
    public static let fallback = ApprovalStatus.unknown
}

public enum WatchKind: String, TolerantStringEnum {
    case check, schedule, unknown
    public static let fallback = WatchKind.unknown
}

public enum WatchCreator: String, TolerantStringEnum {
    case agent, user, unknown
    public static let fallback = WatchCreator.unknown
}

public enum MemoryScope: String, TolerantStringEnum {
    case core, auto, unknown
    public static let fallback = MemoryScope.unknown
}

public enum WechatState: String, TolerantStringEnum {
    case off, connected, expired, unknown
    public static let fallback = WechatState.unknown
}

/// How much the assistant may reach out on WeChat on its own.
public enum WechatProactive: String, TolerantStringEnum {
    case off, hint, full, unknown
    public static let fallback = WechatProactive.unknown
}

// MARK: - ChatMessage

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    /// Local delivery state for optimistic echoes. Not on the wire.
    public enum Delivery: Sendable, Hashable {
        case sending, sent, failed
        /// Couldn't go out because we're offline; resent automatically on reconnect.
        case queued
    }

    /// 0 means "no seq yet" (optimistic echo or an in-flight stream).
    public var seq: Int64
    public var id: String
    public var role: ChatRole
    public var kind: ChatKind
    public var text: String
    public var channel: ChatChannel
    public var ts: Int64
    public var proactive: Bool?
    public var taskId: String?
    public var approvalId: String?
    /// Not in §5.3 but accepted if the host echoes it on the broadcast
    /// `chat.message` for a user turn (lets us merge the optimistic echo
    /// before the `chat.send` response lands).
    public var clientMsgId: String?

    // Local-only state.
    public var isStreaming: Bool = false
    public var delivery: Delivery = .sent

    enum CodingKeys: String, CodingKey {
        case seq, id, role, kind, text, channel, ts, proactive, taskId, approvalId, clientMsgId
    }

    public init(
        seq: Int64, id: String, role: ChatRole, kind: ChatKind = .text, text: String,
        channel: ChatChannel = .app, ts: Int64, proactive: Bool? = nil, taskId: String? = nil,
        approvalId: String? = nil, clientMsgId: String? = nil
    ) {
        self.seq = seq; self.id = id; self.role = role; self.kind = kind; self.text = text
        self.channel = channel; self.ts = ts; self.proactive = proactive; self.taskId = taskId
        self.approvalId = approvalId; self.clientMsgId = clientMsgId
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        seq = l.int64("seq", or: 0)
        id = l.string("id", or: UUID().uuidString)
        role = l.decode(ChatRole.self, "role", or: .unknown)
        kind = l.decode(ChatKind.self, "kind", or: .text)
        text = l.string("text", or: "")
        channel = l.decode(ChatChannel.self, "channel", or: .unknown)
        ts = l.millis("ts", or: 0)
        proactive = l.bool("proactive")
        taskId = l.string("taskId")
        approvalId = l.string("approvalId")
        clientMsgId = l.string("clientMsgId")
    }

    public var date: Date { ts.msDate }
}

// MARK: - Task

/// `Task` on the wire. Named `AllyTask` to avoid clashing with Swift's `Task`.
public struct AllyTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var status: TaskStatus
    public var source: TaskSource
    public var createdAt: Int64
    public var updatedAt: Int64
    public var activityCount: Int

    enum CodingKeys: String, CodingKey { case id, title, summary, status, source, createdAt, updatedAt, activityCount }

    public init(id: String, title: String, summary: String, status: TaskStatus, source: TaskSource = .report,
                createdAt: Int64, updatedAt: Int64, activityCount: Int = 0) {
        self.id = id; self.title = title; self.summary = summary; self.status = status; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.activityCount = activityCount
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        title = l.string("title", or: "")
        summary = l.string("summary", or: "")
        status = l.decode(TaskStatus.self, "status", or: .unknown)
        source = l.decode(TaskSource.self, "source", or: .unknown)
        createdAt = l.millis("createdAt", or: 0)
        updatedAt = l.millis("updatedAt", or: createdAt)
        activityCount = l.int("activityCount", or: 0)
    }

    public var isActive: Bool { status == .running || status == .needsInput }
}

public struct TaskActivity: Codable, Sendable, Hashable {
    public var ts: Int64
    public var kind: ActivityKind
    public var tool: String?
    /// Plain words for the step ("跑命令"), worded by the host.
    public var label: String?
    public var text: String

    enum CodingKeys: String, CodingKey { case ts, kind, tool, label, text }

    public init(ts: Int64, kind: ActivityKind, tool: String? = nil, label: String? = nil, text: String) {
        self.ts = ts; self.kind = kind; self.tool = tool; self.label = label; self.text = text
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        ts = l.millis("ts", or: 0)
        kind = l.decode(ActivityKind.self, "kind", or: .unknown)
        tool = l.string("tool")
        label = l.string("label")
        text = l.string("text", or: "")
    }
}

// MARK: - Approval

public struct Approval: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var tool: String
    public var title: String
    public var detail: String
    public var taskId: String?
    /// The harness marked this prompt as needing care (it defaults to "no").
    /// Such prompts never offer "always allow".
    public var careful: Bool
    public var status: ApprovalStatus
    public var createdAt: Int64
    public var decidedAt: Int64?
    public var decidedBy: String?
    public var suggestedScope: String?
    /// Why the harness asked, in its own words, when it says.
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case id, tool, title, detail, taskId, careful, status, createdAt, decidedAt, decidedBy, suggestedScope, reason
    }

    public init(id: String, tool: String, title: String, detail: String, taskId: String? = nil,
                careful: Bool, status: ApprovalStatus = .pending, createdAt: Int64,
                decidedAt: Int64? = nil, decidedBy: String? = nil, suggestedScope: String? = nil, reason: String? = nil) {
        self.id = id; self.tool = tool; self.title = title; self.detail = detail; self.taskId = taskId
        self.careful = careful; self.status = status; self.createdAt = createdAt
        self.decidedAt = decidedAt; self.decidedBy = decidedBy; self.suggestedScope = suggestedScope
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        tool = l.string("tool", or: "")
        title = l.string("title", or: "")
        detail = l.string("detail", or: "")
        taskId = l.string("taskId")
        // Fail safe: if the host omits the flag, treat it as careful so the
        // "always allow" shortcut is never offered by mistake.
        careful = l.bool("careful", or: true)
        status = l.decode(ApprovalStatus.self, "status", or: .unknown)
        createdAt = l.millis("createdAt", or: 0)
        decidedAt = l.millis("decidedAt")
        decidedBy = l.string("decidedBy")
        suggestedScope = l.string("suggestedScope")
        reason = l.string("reason")
    }

    public var isPending: Bool { status == .pending }
    /// "以后这类都允许" is only offered when the harness didn't mark the prompt
    /// as needing care and the host can describe it as a rule (a suggested scope).
    public var canRemember: Bool {
        guard !careful, let s = suggestedScope?.trimmingCharacters(in: .whitespaces) else { return false }
        return !s.isEmpty
    }

    /// The suggested scope in plain words: `cmd:git` → 「git」这类命令,
    /// `domain:x.com` → x.com 这个网站, `path:/a/b` → 「b」这个文件夹,
    /// `tool:Name` → 这个工具. Never shows the raw prefix.
    public var friendlyScope: String? { suggestedScope.flatMap(Self.friendlyScope) }

    public static func friendlyScope(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let kind = trimmed[..<colon].lowercased()
        let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        switch kind {
        case "cmd":
            return value.isEmpty ? "这类命令" : "「\(value)」这类命令"
        case "domain":
            return value.isEmpty ? "这个网站" : "\(value) 这个网站"
        case "path":
            let name = (value as NSString).lastPathComponent
            return name.isEmpty || name == "/" ? "这个文件夹" : "「\(name)」这个文件夹"
        case "tool":
            return "这个工具"
        default:
            return nil
        }
    }
}

// MARK: - Watch

public struct Watch: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var kind: WatchKind
    public var instruction: String
    public var intervalMinutes: Int?
    /// "HH:MM" in the host's local timezone.
    public var at: [String]?
    public var enabled: Bool
    public var createdBy: WatchCreator
    public var lastCheckedAt: Int64?
    public var lastTriggeredAt: Int64?
    public var skipIfActiveMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, instruction, intervalMinutes, at, enabled, createdBy, lastCheckedAt,
             lastTriggeredAt, skipIfActiveMinutes
    }

    public init(id: String, title: String, kind: WatchKind, instruction: String, intervalMinutes: Int? = nil,
                at: [String]? = nil, enabled: Bool = true, createdBy: WatchCreator = .user,
                lastCheckedAt: Int64? = nil, lastTriggeredAt: Int64? = nil, skipIfActiveMinutes: Int? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.instruction = instruction
        self.intervalMinutes = intervalMinutes; self.at = at; self.enabled = enabled; self.createdBy = createdBy
        self.lastCheckedAt = lastCheckedAt; self.lastTriggeredAt = lastTriggeredAt
        self.skipIfActiveMinutes = skipIfActiveMinutes
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        title = l.string("title", or: "")
        kind = l.decode(WatchKind.self, "kind", or: .unknown)
        instruction = l.string("instruction", or: "")
        intervalMinutes = l.int("intervalMinutes")
        at = l.array(String.self, "at")
        enabled = l.bool("enabled", or: true)
        createdBy = l.decode(WatchCreator.self, "createdBy", or: .unknown)
        lastCheckedAt = l.millis("lastCheckedAt")
        lastTriggeredAt = l.millis("lastTriggeredAt")
        skipIfActiveMinutes = l.int("skipIfActiveMinutes")
    }
}

/// `watch.add` params: a Watch without id / createdBy.
public struct WatchDraft: Codable, Sendable, Hashable {
    public var title: String
    public var kind: WatchKind
    public var instruction: String
    public var intervalMinutes: Int?
    public var at: [String]?
    public var enabled: Bool
    public var skipIfActiveMinutes: Int?

    public init(title: String, kind: WatchKind, instruction: String, intervalMinutes: Int? = nil,
                at: [String]? = nil, enabled: Bool = true, skipIfActiveMinutes: Int? = nil) {
        self.title = title; self.kind = kind; self.instruction = instruction
        self.intervalMinutes = intervalMinutes; self.at = at; self.enabled = enabled
        self.skipIfActiveMinutes = skipIfActiveMinutes
    }

    public init(_ w: Watch) {
        self.init(title: w.title, kind: w.kind, instruction: w.instruction, intervalMinutes: w.intervalMinutes,
                  at: w.at, enabled: w.enabled, skipIfActiveMinutes: w.skipIfActiveMinutes)
    }
}

/// Interval stepping for "every N minutes": 5-minute steps up to an hour,
/// 30-minute steps above. Stepping down from 60 goes to 55 (not 30).
public enum IntervalStep {
    public static let range = 5...1440

    public static func up(_ v: Int) -> Int {
        let next = v < 60 ? v + 5 : v + 30
        return min(range.upperBound, next)
    }

    public static func down(_ v: Int) -> Int {
        let next = v <= 60 ? v - 5 : v - 30
        return max(range.lowerBound, next)
    }
}

extension Watch {
    /// A schedule watch that runs every N minutes instead of at fixed times.
    public var isIntervalSchedule: Bool {
        kind == .schedule && (at ?? []).isEmpty && (intervalMinutes ?? 0) > 0
    }
}

// MARK: - Artifact

public struct ArtifactFile: Codable, Sendable, Hashable {
    public var path: String
    public var size: Int64

    enum CodingKeys: String, CodingKey { case path, size }

    public init(path: String, size: Int64) { self.path = path; self.size = size }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        path = l.string("path", or: "")
        size = l.int64("size", or: 0)
    }
}

public struct Artifact: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// Free-form ("markdown", "html", "pdf", "image", …). Not an enum on purpose.
    public var type: String
    public var mainFile: String
    public var pinned: Bool
    public var updatedAt: Int64
    public var files: [ArtifactFile]

    enum CodingKeys: String, CodingKey { case id, title, type, mainFile, pinned, updatedAt, files }

    public init(id: String, title: String, type: String, mainFile: String, pinned: Bool = false,
                updatedAt: Int64, files: [ArtifactFile] = []) {
        self.id = id; self.title = title; self.type = type; self.mainFile = mainFile; self.pinned = pinned
        self.updatedAt = updatedAt; self.files = files
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        title = l.string("title", or: "")
        type = l.string("type", or: "")
        mainFile = l.string("mainFile", or: "")
        pinned = l.bool("pinned", or: false)
        updatedAt = l.millis("updatedAt", or: 0)
        files = l.array(ArtifactFile.self, "files", or: [])
    }

    /// File extension of the main file, lowercased ("md", "html", "pdf", …).
    public var mainExtension: String {
        (mainFile as NSString).pathExtension.lowercased()
    }

    public enum PreviewStyle: Sendable { case markdown, html, quickLook }

    public var previewStyle: PreviewStyle {
        let t = type.lowercased()
        let ext = mainExtension
        if t == "markdown" || t == "md" || ext == "md" || ext == "markdown" { return .markdown }
        if t == "html" || ext == "html" || ext == "htm" { return .html }
        return .quickLook
    }
}

// MARK: - Settings

public struct QuietHours: Codable, Sendable, Hashable {
    public var start: String
    public var end: String

    enum CodingKeys: String, CodingKey { case start, end }

    public init(start: String, end: String) { self.start = start; self.end = end }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        start = l.string("start", or: "22:00")
        end = l.string("end", or: "08:00")
    }
}

public struct HostSettings: Codable, Sendable, Hashable {
    public var timezone: String
    public var quietHours: QuietHours?
    public var probeIntervalMinutes: Int
    public var approvalTimeoutMinutes: Int
    public var wechatProactive: WechatProactive

    enum CodingKeys: String, CodingKey {
        case timezone, quietHours, probeIntervalMinutes, approvalTimeoutMinutes, wechatProactive
    }

    public init(timezone: String = TimeZone.current.identifier, quietHours: QuietHours? = nil,
                probeIntervalMinutes: Int = 15, approvalTimeoutMinutes: Int = 30,
                wechatProactive: WechatProactive = .hint) {
        self.timezone = timezone; self.quietHours = quietHours
        self.probeIntervalMinutes = probeIntervalMinutes; self.approvalTimeoutMinutes = approvalTimeoutMinutes
        self.wechatProactive = wechatProactive
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        let d = HostSettings()
        timezone = l.string("timezone", or: d.timezone)
        quietHours = l.decode(QuietHours.self, "quietHours")
        probeIntervalMinutes = l.int("probeIntervalMinutes", or: d.probeIntervalMinutes)
        approvalTimeoutMinutes = l.int("approvalTimeoutMinutes", or: d.approvalTimeoutMinutes)
        wechatProactive = l.decode(WechatProactive.self, "wechatProactive", or: d.wechatProactive)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timezone, forKey: .timezone)
        // quietHours: null means "off" — encode it explicitly.
        if let q = quietHours { try c.encode(q, forKey: .quietHours) } else { try c.encodeNil(forKey: .quietHours) }
        try c.encode(probeIntervalMinutes, forKey: .probeIntervalMinutes)
        try c.encode(approvalTimeoutMinutes, forKey: .approvalTimeoutMinutes)
        // Never send a value we didn't understand back to the host.
        if wechatProactive != .unknown { try c.encode(wechatProactive, forKey: .wechatProactive) }
    }
}

// MARK: - Status

public struct HostStatus: Codable, Sendable, Hashable {
    public var online: Bool
    public var busy: Bool
    /// What it is doing right now in plain words ("正在写文件"), only while busy.
    public var activity: String?
    public var model: String
    public var sessionId: String?
    public var wechat: WechatState
    public var version: String

    enum CodingKeys: String, CodingKey { case online, busy, activity, model, effort, sessionId, wechat, version }

    public var effort: String?

    public init(online: Bool = true, busy: Bool = false, model: String = "",
                sessionId: String? = nil, wechat: WechatState = .off, version: String = "") {
        self.online = online; self.busy = busy; self.model = model
        self.sessionId = sessionId; self.wechat = wechat; self.version = version
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        online = l.bool("online", or: true)
        busy = l.bool("busy", or: false)
        activity = l.string("activity")
        model = l.string("model", or: "")
        effort = l.string("effort")
        sessionId = l.string("sessionId")
        wechat = l.decode(WechatState.self, "wechat", or: .off)
        version = l.string("version", or: "")
    }
}

// MARK: - Memory

public struct MemoryFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var scope: MemoryScope
    public var size: Int64
    public var updatedAt: Int64
    public var id: String { path }

    enum CodingKeys: String, CodingKey { case path, scope, size, updatedAt }

    public init(path: String, scope: MemoryScope, size: Int64, updatedAt: Int64) {
        self.path = path; self.scope = scope; self.size = size; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        path = l.string("path", or: "")
        scope = l.decode(MemoryScope.self, "scope", or: .unknown)
        size = l.int64("size", or: 0)
        updatedAt = l.millis("updatedAt", or: 0)
    }
}
