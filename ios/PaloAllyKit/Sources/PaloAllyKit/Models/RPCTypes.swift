import Foundation

// Request params / response results for the methods in design.md §5.3.

public enum RPCMethod {
    public static let hello = "hello"
    public static let sync = "sync"
    public static let chatSend = "chat.send"
    public static let chatHistory = "chat.history"
    /// Substring search over the whole conversation, newest first (成果's search).
    public static let chatSearch = "chat.search"
    /// A window of messages around a seq, for jumping to a search hit.
    public static let chatAround = "chat.around"
    public static let taskGet = "task.get"
    public static let taskStop = "task.stop"
    public static let approvalAnswer = "approval.answer"
    /// The owner's choices for a question card (AskUserQuestion).
    public static let questionAnswer = "question.answer"
    public static let watchAdd = "watch.add"
    public static let watchUpdate = "watch.update"
    public static let watchRemove = "watch.remove"
    public static let artifactList = "artifact.list"
    public static let artifactRead = "artifact.read"
    public static let artifactPin = "artifact.pin"
    public static let memoryList = "memory.list"
    public static let memoryRead = "memory.read"
    public static let memoryWrite = "memory.write"
    public static let settingsUpdate = "settings.update"
    /// The stop button: interrupts whatever the assistant is doing. Nothing
    /// stays blocked afterwards; the next message works as usual.
    public static let stop = "stop"
    public static let pushRegister = "push.register"
    public static let pushUnregister = "push.unregister"
    public static let deviceUnpair = "device.unpair"
    public static let auditTail = "audit.tail"
    public static let commandsList = "commands.list"
    public static let modelGet = "model.get"
    public static let modelSet = "model.set"
    /// One image per call (the relay caps a frame at 1 MiB); chat.send then
    /// references the returned ids.
    public static let mediaUpload = "media.upload"
    public static let mediaGet = "media.get"
    /// A file from the app, in ≤256 KiB chunks (the relay caps a frame at 1 MiB).
    public static let mediaUploadChunk = "media.uploadChunk"
    /// A file the assistant sent, in 256 KiB chunks (same shape as artifact.read).
    public static let mediaRead = "media.read"
    /// 「试试」 chips: the unused suggestions, and dismissing one for good.
    public static let suggestionsList = "suggestions.list"
    public static let suggestionsDismiss = "suggestions.dismiss"
    /// The host's own update: `check` only looks; otherwise it stages the newest
    /// release and switches as soon as nothing is in flight (Settings → 立即更新).
    public static let hostUpdate = "host.update"

    /// Every method the client knows. The contract test checks this equals
    /// the host's method set exactly.
    public static let all: [String] = [
        hello, sync, chatSend, chatHistory, chatSearch, chatAround, commandsList, modelGet, modelSet, taskGet, taskStop,
        approvalAnswer, questionAnswer, watchAdd, watchUpdate, watchRemove, artifactList, artifactRead, artifactPin,
        memoryList, memoryRead, memoryWrite, settingsUpdate, stop, pushRegister, pushUnregister,
        deviceUnpair, auditTail, mediaUpload, mediaUploadChunk, mediaGet, mediaRead,
        suggestionsList, suggestionsDismiss, hostUpdate,
    ]
}

public enum RPCEventName {
    public static let chatMessage = "chat.message"
    public static let chatDelta = "chat.delta"
    public static let taskUpdated = "task.updated"
    public static let approvalUpdated = "approval.updated"
    public static let questionUpdated = "question.updated"
    public static let watchUpdated = "watch.updated"
    public static let artifactUpdated = "artifact.updated"
    public static let settingsUpdated = "settings.updated"
    public static let status = "status"
    public static let commandsUpdated = "commands.updated"
    public static let suggestionsUpdated = "suggestions.updated"

    public static let all: [String] = [
        chatMessage, chatDelta, taskUpdated, approvalUpdated, questionUpdated, watchUpdated, artifactUpdated, settingsUpdated,
        status, commandsUpdated, suggestionsUpdated,
    ]
}

public struct EmptyParams: Codable, Sendable { public init() {} }

public struct OKResult: Decodable, Sendable {
    public var ok: Bool
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        ok = l.bool("ok", or: true)
    }
}

public struct HelloParams: Codable, Sendable {
    public var client: String
    public var version: String
    public init(client: String, version: String) { self.client = client; self.version = version }
}

public struct HelloResult: Decodable, Sendable {
    public var hostName: String
    public var version: String
    public var status: HostStatus?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        hostName = l.string("hostName", or: "")
        version = l.string("version", or: "")
        status = l.expect("status", l.decode(HostStatus.self, "status"))
    }
}

public struct SyncParams: Codable, Sendable {
    public var sinceSeq: Int64?
    public init(sinceSeq: Int64?) { self.sinceSeq = sinceSeq }
}

public struct SyncResult: Codable, Sendable {
    public var seq: Int64
    public var messages: [ChatMessage]
    public var tasks: [AllyTask]?
    public var approvals: [Approval]?
    /// Absent on hosts that predate question cards.
    public var questions: [Question]?
    public var watches: [Watch]?
    public var artifacts: [Artifact]?
    public var settings: HostSettings?
    public var status: HostStatus?

    public init(seq: Int64, messages: [ChatMessage], tasks: [AllyTask]? = nil, approvals: [Approval]? = nil,
                questions: [Question]? = nil,
                watches: [Watch]? = nil, artifacts: [Artifact]? = nil, settings: HostSettings? = nil,
                status: HostStatus? = nil) {
        self.seq = seq; self.messages = messages; self.tasks = tasks; self.approvals = approvals
        self.questions = questions
        self.watches = watches; self.artifacts = artifacts; self.settings = settings; self.status = status
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        seq = l.int64("seq", or: 0)
        messages = l.array(ChatMessage.self, "messages", or: [])
        tasks = l.expect("tasks", l.array(AllyTask.self, "tasks"))
        approvals = l.expect("approvals", l.array(Approval.self, "approvals"))
        questions = l.array(Question.self, "questions")
        watches = l.expect("watches", l.array(Watch.self, "watches"))
        artifacts = l.expect("artifacts", l.array(Artifact.self, "artifacts"))
        settings = l.expect("settings", l.decode(HostSettings.self, "settings"))
        status = l.expect("status", l.decode(HostStatus.self, "status"))
    }

    /// Max messages a `sync{sinceSeq}` returns per call (design.md §5.3).
    public static let pageLimit = 500
}

public struct ChatSendParams: Codable, Sendable {
    public var text: String
    public var clientMsgId: String?
    public var attachments: [String]?
    /// Set when the message came from tapping a 「试试」 chip (it's used up).
    public var suggestionId: String?
    /// The quoted part of an earlier message.
    public var replyTo: ReplyTo?
    public init(text: String, clientMsgId: String?, attachments: [String]? = nil, suggestionId: String? = nil, replyTo: ReplyTo? = nil) {
        self.text = text; self.clientMsgId = clientMsgId; self.attachments = attachments; self.suggestionId = suggestionId
        self.replyTo = replyTo
    }
}

public struct MediaUploadParams: Codable, Sendable {
    public var mediaType: String
    public var data: String // base64
    public init(mediaType: String, data: String) { self.mediaType = mediaType; self.data = data }
}

public struct MediaUploadChunkParams: Codable, Sendable {
    public var uploadId: String?
    public var name: String
    public var mediaType: String
    public var offset: Int64
    public var data: String // base64
    public var done: Bool
    public init(uploadId: String?, name: String, mediaType: String, offset: Int64, data: String, done: Bool) {
        self.uploadId = uploadId; self.name = name; self.mediaType = mediaType
        self.offset = offset; self.data = data; self.done = done
    }
}

/// `{uploadId}` while more chunks are expected; the file's Attachment after the last.
public struct MediaUploadChunkResult: Decodable, Sendable {
    public var uploadId: String?
    public var attachment: Attachment?

    enum CodingKeys: String, CodingKey { case uploadId, id, kind, mediaType, name, size }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        uploadId = l.string("uploadId")
        attachment = l.string("id") == nil ? nil : try Attachment(from: decoder)
    }
}

public struct MediaReadParams: Codable, Sendable {
    public var id: String
    public var offset: Int64
    public var length: Int64
    public init(id: String, offset: Int64, length: Int64) { self.id = id; self.offset = offset; self.length = length }
}

public struct MediaGetParams: Codable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct MediaData: Decodable, Sendable {
    public var mediaType: String
    public var data: String
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        mediaType = l.string("mediaType", or: "image/jpeg")
        data = l.string("data", or: "")
    }
}

public struct ChatSendResult: Decodable, Sendable {
    public var id: String
    public var seq: Int64
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        seq = l.int64("seq", or: 0)
    }
}

public struct ChatHistoryParams: Codable, Sendable {
    public var beforeSeq: Int64
    public var limit: Int
    public init(beforeSeq: Int64, limit: Int) { self.beforeSeq = beforeSeq; self.limit = limit }
}

public struct ChatSearchParams: Codable, Sendable {
    public var query: String
    public var limit: Int?
    public var beforeSeq: Int64?
    public init(query: String, limit: Int? = nil, beforeSeq: Int64? = nil) {
        self.query = query; self.limit = limit; self.beforeSeq = beforeSeq
    }
}

public struct ChatAroundParams: Codable, Sendable {
    public var seq: Int64
    public var before: Int
    public var after: Int
    public init(seq: Int64, before: Int = 25, after: Int = 25) { self.seq = seq; self.before = before; self.after = after }
}

/// One conversation hit: who said it, when, and a snippet around the match.
public struct ChatSearchHit: Decodable, Sendable, Hashable, Identifiable {
    public var seq: Int64
    public var id: String
    public var role: ChatRole
    public var ts: Int64
    public var channel: ChatChannel
    public var snippet: String

    public init(seq: Int64, id: String, role: ChatRole, ts: Int64, channel: ChatChannel = .app, snippet: String) {
        self.seq = seq; self.id = id; self.role = role; self.ts = ts; self.channel = channel; self.snippet = snippet
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        seq = l.int64("seq", or: 0)
        id = l.string("id", or: "")
        role = l.decode(ChatRole.self, "role", or: .unknown)
        ts = l.millis("ts", or: 0)
        channel = l.decode(ChatChannel.self, "channel", or: .unknown)
        snippet = l.string("snippet", or: "")
    }
}

public struct ChatSearchResult: Decodable, Sendable {
    public var messages: [ChatSearchHit]
    public init(messages: [ChatSearchHit]) { self.messages = messages }
    public init(from decoder: Decoder) throws {
        messages = try Lenient(decoder).array(ChatSearchHit.self, "messages", or: [])
    }
}

public struct MessagesResult: Decodable, Sendable {
    public var messages: [ChatMessage]
    public init(from decoder: Decoder) throws {
        messages = try Lenient(decoder).array(ChatMessage.self, "messages", or: [])
    }
}

public struct IDParams: Codable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct TaskDetail: Decodable, Sendable {
    public var task: AllyTask?
    public var activity: [TaskActivity]
    public init(task: AllyTask?, activity: [TaskActivity]) { self.task = task; self.activity = activity }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        task = l.expect("task", l.decode(AllyTask.self, "task"))
        activity = l.array(TaskActivity.self, "activity", or: [])
    }
}

public struct ApprovalAnswerParams: Codable, Sendable {
    public var id: String
    public var allow: Bool
    public var remember: Bool?
    public init(id: String, allow: Bool, remember: Bool?) { self.id = id; self.allow = allow; self.remember = remember }
}

public struct QuestionAnswerParams: Codable, Sendable {
    public var id: String
    /// question text → chosen label(s) joined by ", ", or the owner's own words
    public var answers: [String: String]
    public init(id: String, answers: [String: String]) { self.id = id; self.answers = answers }
}

public struct QuestionResult: Decodable, Sendable {
    public var question: Question?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        question = l.expect("question", l.decode(Question.self, "question"))
    }
}

/// host.update: "manual" | "latest" | "available" | "staged" | "updating" | "dirty" | "failed" | "waiting".
public struct HostUpdateResult: Decodable, Sendable {
    public var status: String
    public var current: String
    public var latest: String?
    public var detail: String?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        status = l.string("status", or: "")
        current = l.string("current", or: "")
        latest = l.string("latest")
        detail = l.string("detail")
    }
}

public struct HostUpdateParams: Encodable, Sendable {
    public var check: Bool
    public init(check: Bool) { self.check = check }
}

public struct StatusStringResult: Decodable, Sendable {
    public var status: String
    public init(from decoder: Decoder) throws { status = try Lenient(decoder).string("status", or: "") }
}

public struct WatchResult: Decodable, Sendable {
    public var watch: Watch?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        watch = l.expect("watch", l.decode(Watch.self, "watch"))
    }
}

public struct PatchParams: Codable, Sendable {
    public var id: String?
    public var patch: JSONValue
    public init(id: String? = nil, patch: JSONValue) { self.id = id; self.patch = patch }
}

public struct ArtifactsResult: Decodable, Sendable {
    public var artifacts: [Artifact]
    public init(from decoder: Decoder) throws {
        artifacts = try Lenient(decoder).array(Artifact.self, "artifacts", or: [])
    }
}

public struct ArtifactReadParams: Codable, Sendable {
    public var id: String
    public var path: String?
    public var offset: Int64?
    public var length: Int64?
    public init(id: String, path: String?, offset: Int64?, length: Int64?) {
        self.id = id; self.path = path; self.offset = offset; self.length = length
    }
}

public struct ArtifactChunk: Decodable, Sendable {
    public var data: Data
    public var size: Int64
    public var mime: String
    public var eof: Bool
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        data = Data(base64Encoded: l.string("data", or: ""), options: .ignoreUnknownCharacters) ?? Data()
        size = l.int64("size", or: 0)
        mime = l.string("mime", or: "application/octet-stream")
        eof = l.bool("eof", or: true)
    }
    /// design.md §5.3: each chunk ≤ 256 KiB.
    public static let maxChunk: Int64 = 256 * 1024
}

public struct ArtifactPinParams: Codable, Sendable {
    public var id: String
    public var pinned: Bool
    public init(id: String, pinned: Bool) { self.id = id; self.pinned = pinned }
}

public struct ArtifactResult: Decodable, Sendable {
    public var artifact: Artifact?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        artifact = l.expect("artifact", l.decode(Artifact.self, "artifact"))
    }
}

public struct MemoryFilesResult: Decodable, Sendable {
    public var files: [MemoryFile]
    public init(from decoder: Decoder) throws { files = try Lenient(decoder).array(MemoryFile.self, "files", or: []) }
}

public struct PathParams: Codable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// `memory.read → {content, updatedAt}`.
public struct MemoryContentResult: Decodable, Sendable, Equatable {
    public var content: String
    /// Host's modification time; send it back as `baseUpdatedAt` on write.
    public var updatedAt: Int64?
    public init(content: String, updatedAt: Int64?) { self.content = content; self.updatedAt = updatedAt }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        content = l.string("content", or: "")
        updatedAt = l.expect("updatedAt", l.millis("updatedAt"))
    }
}

/// `memory.write {path, content, baseUpdatedAt}`. The host refuses the write
/// if the file changed after `baseUpdatedAt`.
public struct MemoryWriteParams: Codable, Sendable {
    public var path: String
    public var content: String
    public var baseUpdatedAt: Int64?
    public init(path: String, content: String, baseUpdatedAt: Int64? = nil) {
        self.path = path; self.content = content; self.baseUpdatedAt = baseUpdatedAt
    }
}

/// `memory.write → {ok, updatedAt}`; `updatedAt` is the base for the next write.
public struct MemoryWriteResult: Decodable, Sendable {
    public var ok: Bool
    public var updatedAt: Int64?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        ok = l.bool("ok", or: true)
        updatedAt = l.expect("updatedAt", l.millis("updatedAt"))
    }
}

public struct PushUnregisterParams: Codable, Sendable {
    public var token: String
    public init(token: String) { self.token = token }
}

public struct SettingsResult: Decodable, Sendable {
    public var settings: HostSettings?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        settings = l.expect("settings", l.decode(HostSettings.self, "settings"))
    }
}

/// `stop` / `model.set` return `{status}`.
public struct StatusResult: Decodable, Sendable {
    public var status: HostStatus?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        status = l.expect("status", l.decode(HostStatus.self, "status"))
    }
}

public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }

public struct PushRegisterParams: Codable, Sendable {
    public var token: String
    public var env: PushEnvironment
    public init(token: String, env: PushEnvironment) { self.token = token; self.env = env }
}

public struct AuditTailParams: Codable, Sendable {
    public var limit: Int
    public init(limit: Int) { self.limit = limit }
}

public struct AuditResult: Decodable, Sendable {
    public var entries: [JSONValue]
    public init(from decoder: Decoder) throws { entries = try Lenient(decoder).decode([JSONValue].self, "entries", or: []) }
}

/// `chat.delta` payload.
public struct ChatDelta: Codable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        text = l.string("text", or: "")
    }
}

/// `watch.updated` payload: `{watch}` or `{removed:id}`.
public enum WatchUpdate: Sendable {
    case upsert(Watch)
    case removed(String)
    case unknown

    public init(json: JSONValue) {
        if let removed = json["removed"]?.stringValue { self = .removed(removed); return }
        if let w = json["watch"], let watch = try? w.decode(Watch.self) { self = .upsert(watch); return }
        // Be forgiving: a bare Watch object.
        if json["id"] != nil, let watch = try? json.decode(Watch.self) { self = .upsert(watch); return }
        self = .unknown
    }
}
