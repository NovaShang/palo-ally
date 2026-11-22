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

/// What kind of card an item stands for, besides a question or a prompt.
public enum PendingLinkKind: String, TolerantStringEnum {
    /// The assistant's proposal: 开一个会话 (开吧 / 不用) or 接管 (接管 / 不用).
    case proposal
    /// An Ally draft (发送 / 不发).
    case allyDraft
    /// A task that needs the owner.
    case task
    case unknown
    public static let fallback = PendingLinkKind.unknown
}

/// The card an item stands for: answering the item answers the card, and
/// the item closes when the card is settled (the host keeps them in step).
public struct PendingLink: Codable, Sendable, Hashable {
    public var kind: PendingLinkKind
    /// The proposal's, the Ally entry's or the task's id.
    public var id: String

    public init(kind: PendingLinkKind, id: String) { self.kind = kind; self.id = id }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        kind = l.decode(PendingLinkKind.self, "kind", or: .unknown)
        id = l.string("id", or: "")
    }
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
    /// The card it stands for (a proposal, an Ally draft, a task).
    public var link: PendingLink?

    public init(id: String, source: PendingSource, title: String, context: String? = nil, options: [String]? = nil,
                createdAt: Int64, blocking: Bool = false, status: PendingStatus = .open, conclusion: String? = nil,
                resolvedAt: Int64? = nil, messageId: String? = nil, pal: String? = nil, questionId: String? = nil,
                approvalId: String? = nil, link: PendingLink? = nil) {
        self.id = id; self.source = source; self.title = title; self.context = context; self.options = options
        self.createdAt = createdAt; self.blocking = blocking; self.status = status; self.conclusion = conclusion
        self.resolvedAt = resolvedAt; self.messageId = messageId; self.pal = pal; self.questionId = questionId
        self.approvalId = approvalId; self.link = link
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
        link = l.decode(PendingLink.self, "link")
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

// MARK: - deciding: one way for a card in a conversation and a row of the list

/// What an item stands for: the card answering it settles (and settling the
/// card closes the item), or nothing but the item itself.
public enum PendingSubject: Hashable, Sendable {
    /// A permission prompt (允许 / 拒绝).
    case approval(String)
    /// A question card (AskUserQuestion).
    case question(String)
    /// The assistant's proposal: 开一个 agent (开吧) or 接管 (接管), and 不用.
    case proposal(String)
    /// A message to a contact (发送 / 不发).
    case allyDraft(String)
    /// A task that needs the owner.
    case task(String)
    /// An item of its own (the assistant's, a brief's, an agent's), by its id.
    case item(String)
}

/// What the owner decided, on a card or on a row.
public enum PendingChoice: Hashable, Sendable {
    /// One of the item's options, or the owner's own words.
    case option(String)
    /// A permission prompt: 允许 (and 以后都允许), or 拒绝.
    case allow(remember: Bool)
    case deny
    /// A question card's answers: question text → the label(s) or words; a
    /// question left out is skipped (empty: the whole card).
    case answers([String: String])
    /// A proposal's 开吧 / 接管, a draft's 发送; and 不用 / 不发.
    case accept
    case decline
    /// A draft sent with the owner's changed words (改一下 → 发送).
    case sendEdited(String)
    /// 忽略, and 放回 / 撤回.
    case ignore
    case reopen
    /// 以后再说: onto the 待办 of the folder it came from (`AppStore.canPutOff`).
    case later
}

/// One button of a decision: its words, what it decides, and whether it's
/// the one in the theme color.
public struct PendingChoiceButton: Hashable, Sendable, Identifiable {
    public var title: String
    public var choice: PendingChoice
    public var primary: Bool
    public var id: String { title }

    public init(title: String, choice: PendingChoice, primary: Bool = false) {
        self.title = title; self.choice = choice; self.primary = primary
    }
}

extension PendingItem {
    public var subject: PendingSubject {
        if let approvalId { return .approval(approvalId) }
        if let questionId { return .question(questionId) }
        if let link, !link.id.isEmpty {
            switch link.kind {
            case .proposal: return .proposal(link.id)
            case .allyDraft: return .allyDraft(link.id)
            case .task: return .task(link.id)
            case .unknown: break
            }
        }
        return .item(id)
    }

    /// The item's options as buttons, in the order a card shows them. A
    /// card's options (the host lists the yes first: 允许 / 拒绝, 开吧 / 不用,
    /// 发送 / 不发) decide what the card's buttons do, the yes in the theme
    /// color and last; anyone else's are answers, in their order.
    public var choices: [PendingChoiceButton] {
        let options = (options ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let yesNo: (PendingChoice, PendingChoice)? = switch subject {
        case .approval: (.allow(remember: false), .deny)
        case .proposal, .allyDraft: (.accept, .decline)
        default: nil
        }
        if let (yes, no) = yesNo, options.count == 2 {
            return [PendingChoiceButton(title: options[1], choice: no),
                    PendingChoiceButton(title: options[0], choice: yes, primary: true)]
        }
        return options.map { PendingChoiceButton(title: $0, choice: .option($0)) }
    }

    /// Whether the owner's own words are an answer here: anything but a
    /// permission prompt (yes or no only).
    public var takesWords: Bool { approvalId == nil }
}
