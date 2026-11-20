import Foundation

// MARK: - 等你的事 (host/src/pending.ts)

/// Who put an item on the owner's list.
public enum PendingSourceKind: String, TolerantStringEnum {
    /// The assistant itself.
    case palo
    /// One of the Pals.
    case pal
    /// A Claude Code session on the computer (its question or prompt).
    case session
    /// A brief's run (a schedule goal: 晨报).
    case brief
    case ally
    case unknown
    public static let fallback = PendingSourceKind.unknown
}

public struct PendingSource: Codable, Sendable, Hashable {
    public var kind: PendingSourceKind
    /// The Pal's / session's / goal's / Ally's id.
    public var id: String?
    public var name: String

    public init(kind: PendingSourceKind, id: String? = nil, name: String) {
        self.kind = kind; self.id = id; self.name = name
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        kind = l.decode(PendingSourceKind.self, "kind", or: .unknown)
        id = l.string("id")
        name = l.string("name", or: "")
    }
}

public enum PendingStatus: String, TolerantStringEnum {
    case open, done, ignored, snoozed, unknown
    public static let fallback = PendingStatus.unknown
}

/// One thing the owner has to decide, as the host keeps it. `blocking`: a
/// session is actually stopped on it (its question or permission prompt).
public struct PendingItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var source: PendingSource
    /// One sentence: what to decide.
    public var title: String
    /// A sentence or two of background.
    public var context: String?
    /// Answers to pick from, when there are some.
    public var options: [String]?
    public var createdAt: Int64
    public var blocking: Bool
    public var status: PendingStatus
    /// When done: what was decided, one line.
    public var conclusion: String?
    /// When it left the open list.
    public var resolvedAt: Int64?
    /// The message it came from (看原文).
    public var messageId: String?
    /// …in this Pal's conversation (nil: the assistant's).
    public var pal: String?
    public var questionId: String?
    public var approvalId: String?
    /// Open a long while: when a brief mentioned it.
    public var remindedAt: Int64?

    public init(id: String, source: PendingSource, title: String, context: String? = nil, options: [String]? = nil,
                createdAt: Int64, blocking: Bool = false, status: PendingStatus = .open, conclusion: String? = nil,
                resolvedAt: Int64? = nil, messageId: String? = nil, pal: String? = nil, questionId: String? = nil,
                approvalId: String? = nil) {
        self.id = id; self.source = source; self.title = title; self.context = context; self.options = options
        self.createdAt = createdAt; self.blocking = blocking; self.status = status; self.conclusion = conclusion
        self.resolvedAt = resolvedAt; self.messageId = messageId; self.pal = pal; self.questionId = questionId
        self.approvalId = approvalId
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        source = l.decode(PendingSource.self, "source", or: PendingSource(kind: .unknown, name: ""))
        title = l.string("title", or: "")
        context = l.string("context")
        options = l.decode([String].self, "options")
        createdAt = l.millis("createdAt", or: 0)
        blocking = l.bool("blocking", or: false)
        status = l.decode(PendingStatus.self, "status", or: .unknown)
        conclusion = l.string("conclusion")
        resolvedAt = l.millis("resolvedAt")
        messageId = l.string("messageId")
        pal = l.string("pal")
        questionId = l.string("questionId")
        approvalId = l.string("approvalId")
        remindedAt = l.millis("remindedAt")
    }

    public var isOpen: Bool { status == .open }
    public var date: Date { createdAt.msDate }
    /// Answered through a session's question or prompt (not a message).
    public var isCard: Bool { questionId != nil || approvalId != nil }
}

public struct PendingListResult: Decodable, Sendable {
    public var items: [PendingItem]
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        items = l.array(PendingItem.self, "items", or: [])
    }
}

public struct PendingItemResult: Decodable, Sendable {
    public var item: PendingItem?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        item = l.expect("item", l.decode(PendingItem.self, "item"))
    }
}

public struct PendingUpdateParams: Codable, Sendable {
    public var id: String
    /// "ignore" | "reopen" | "snooze"
    public var action: String
    public init(id: String, action: String) { self.id = id; self.action = action }
}

public struct PendingAnswerParams: Codable, Sendable {
    public var id: String
    public var answer: String
    public init(id: String, answer: String) { self.id = id; self.answer = answer }
}

public struct PendingIDParams: Codable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}
