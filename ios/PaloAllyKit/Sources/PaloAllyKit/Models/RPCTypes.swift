import Foundation

// Request params / response results for the methods in design.md §5.3.

public enum RPCMethod {
    public static let hello = "hello"
    public static let sync = "sync"
    public static let chatSend = "chat.send"
    public static let chatHistory = "chat.history"
    public static let taskGet = "task.get"
    public static let taskStop = "task.stop"
    public static let approvalAnswer = "approval.answer"
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

    /// Every method the client knows. The contract test checks this equals
    /// the host's method set exactly.
    public static let all: [String] = [
        hello, sync, chatSend, chatHistory, commandsList, modelGet, modelSet, taskGet, taskStop,
        approvalAnswer, watchAdd, watchUpdate, watchRemove, artifactList, artifactRead, artifactPin,
        memoryList, memoryRead, memoryWrite, settingsUpdate, stop, pushRegister, pushUnregister,
        deviceUnpair, auditTail, mediaUpload, mediaGet,
    ]
}

public enum RPCEventName {
    public static let chatMessage = "chat.message"
    public static let chatDelta = "chat.delta"
    public static let taskUpdated = "task.updated"
    public static let approvalUpdated = "approval.updated"
    public static let watchUpdated = "watch.updated"
    public static let artifactUpdated = "artifact.updated"
    public static let settingsUpdated = "settings.updated"
    public static let status = "status"
    public static let commandsUpdated = "commands.updated"

    public static let all: [String] = [
        chatMessage, chatDelta, taskUpdated, approvalUpdated, watchUpdated, artifactUpdated, settingsUpdated,
        status, commandsUpdated,
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
    public var watches: [Watch]?
    public var artifacts: [Artifact]?
    public var settings: HostSettings?
    public var status: HostStatus?

    public init(seq: Int64, messages: [ChatMessage], tasks: [AllyTask]? = nil, approvals: [Approval]? = nil,
                watches: [Watch]? = nil, artifacts: [Artifact]? = nil, settings: HostSettings? = nil,
                status: HostStatus? = nil) {
        self.seq = seq; self.messages = messages; self.tasks = tasks; self.approvals = approvals
        self.watches = watches; self.artifacts = artifacts; self.settings = settings; self.status = status
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        seq = l.int64("seq", or: 0)
        messages = l.array(ChatMessage.self, "messages", or: [])
        tasks = l.expect("tasks", l.array(AllyTask.self, "tasks"))
        approvals = l.expect("approvals", l.array(Approval.self, "approvals"))
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
    public init(text: String, clientMsgId: String?, attachments: [String]? = nil) {
        self.text = text; self.clientMsgId = clientMsgId; self.attachments = attachments
    }
}

public struct MediaUploadParams: Codable, Sendable {
    public var mediaType: String
    public var data: String // base64
    public init(mediaType: String, data: String) { self.mediaType = mediaType; self.data = data }
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
