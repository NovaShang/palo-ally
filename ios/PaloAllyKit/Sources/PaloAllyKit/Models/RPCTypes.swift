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
    public static let kill = "kill"
    public static let resume = "resume"
    public static let pushRegister = "push.register"
    public static let auditTail = "audit.tail"
    public static let commandsList = "commands.list"
    public static let modelGet = "model.get"
    public static let modelSet = "model.set"
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
}

public struct EmptyParams: Codable, Sendable { public init() {} }

public struct OKResult: Decodable, Sendable {
    public var ok: Bool
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        ok = l.bool("ok") ?? true
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
        hostName = l.string("hostName") ?? ""
        version = l.string("version") ?? ""
        status = l.decode(HostStatus.self, "status")
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
        seq = l.int64("seq") ?? 0
        messages = l.array(ChatMessage.self, "messages") ?? []
        tasks = l.array(AllyTask.self, "tasks")
        approvals = l.array(Approval.self, "approvals")
        watches = l.array(Watch.self, "watches")
        artifacts = l.array(Artifact.self, "artifacts")
        settings = l.decode(HostSettings.self, "settings")
        status = l.decode(HostStatus.self, "status")
    }

    /// Max messages a `sync{sinceSeq}` returns per call (design.md §5.3).
    public static let pageLimit = 500
}

public struct ChatSendParams: Codable, Sendable {
    public var text: String
    public var clientMsgId: String?
    public init(text: String, clientMsgId: String?) { self.text = text; self.clientMsgId = clientMsgId }
}

public struct ChatSendResult: Decodable, Sendable {
    public var id: String
    public var seq: Int64
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id") ?? ""
        seq = l.int64("seq") ?? 0
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
        messages = try Lenient(decoder).array(ChatMessage.self, "messages") ?? []
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
        task = l.decode(AllyTask.self, "task")
        activity = l.array(TaskActivity.self, "activity") ?? []
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
    public init(from decoder: Decoder) throws { status = try Lenient(decoder).string("status") ?? "" }
}

public struct WatchResult: Decodable, Sendable {
    public var watch: Watch?
    public init(from decoder: Decoder) throws { watch = try Lenient(decoder).decode(Watch.self, "watch") }
}

public struct PatchParams: Codable, Sendable {
    public var id: String?
    public var patch: JSONValue
    public init(id: String? = nil, patch: JSONValue) { self.id = id; self.patch = patch }
}

public struct ArtifactsResult: Decodable, Sendable {
    public var artifacts: [Artifact]
    public init(from decoder: Decoder) throws {
        artifacts = try Lenient(decoder).array(Artifact.self, "artifacts") ?? []
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
        data = Data(base64Encoded: l.string("data") ?? "", options: .ignoreUnknownCharacters) ?? Data()
        size = l.int64("size") ?? 0
        mime = l.string("mime") ?? "application/octet-stream"
        eof = l.bool("eof") ?? true
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
    public init(from decoder: Decoder) throws { artifact = try Lenient(decoder).decode(Artifact.self, "artifact") }
}

public struct MemoryFilesResult: Decodable, Sendable {
    public var files: [MemoryFile]
    public init(from decoder: Decoder) throws { files = try Lenient(decoder).array(MemoryFile.self, "files") ?? [] }
}

public struct PathParams: Codable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct MemoryContentResult: Decodable, Sendable {
    public var content: String
    public init(from decoder: Decoder) throws { content = try Lenient(decoder).string("content") ?? "" }
}

public struct MemoryWriteParams: Codable, Sendable {
    public var path: String
    public var content: String
    public init(path: String, content: String) { self.path = path; self.content = content }
}

public struct SettingsResult: Decodable, Sendable {
    public var settings: HostSettings?
    public init(from decoder: Decoder) throws { settings = try Lenient(decoder).decode(HostSettings.self, "settings") }
}

/// `kill` / `resume` return `{status}`; we accept a Status object or a string.
public struct KillResult: Decodable, Sendable {
    public var status: HostStatus?
    public init(from decoder: Decoder) throws { status = try Lenient(decoder).decode(HostStatus.self, "status") }
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
    public init(from decoder: Decoder) throws { entries = try Lenient(decoder).decode([JSONValue].self, "entries") ?? [] }
}

/// `chat.delta` payload.
public struct ChatDelta: Codable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id") ?? ""
        text = l.string("text") ?? ""
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
