import Foundation

// 回到这里重来 (docs/rewind-prd.md): the conversation goes back to just
// before one of the owner's messages; that message and everything after it
// leave it, and its words come back for the composer. In a Pal the files
// can go back too.

/// `chat.rewind {messageId}`.
public struct ChatRewindParams: Codable, Sendable {
    public var messageId: String
    public init(messageId: String) { self.messageId = messageId }
}

/// `chat.rewind → {text}`: the message's words, for the composer.
public struct ChatRewindResult: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        text = l.string("text", or: "")
    }
}

/// `pals.rewind {id, messageId, restoreFiles?}`, or `{id, messageId, check: true}`.
public struct PalRewindParams: Codable, Sendable {
    public var id: String
    public var messageId: String
    public var restoreFiles: Bool?
    public var check: Bool?
    public init(id: String, messageId: String, restoreFiles: Bool? = nil, check: Bool? = nil) {
        self.id = id; self.messageId = messageId; self.restoreFiles = restoreFiles; self.check = check
    }
}

/// `pals.rewind → {text, filesRestored}`.
public struct PalRewindResult: Codable, Sendable {
    public var text: String
    public var filesRestored: Bool
    public init(text: String, filesRestored: Bool) { self.text = text; self.filesRestored = filesRestored }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        text = l.string("text", or: "")
        filesRestored = l.bool("filesRestored", or: false)
    }
}

/// `pals.rewind {check: true} → {canRestoreFiles}`: Claude Code kept the
/// files as they were before that message.
public struct PalRewindCheck: Codable, Sendable {
    public var canRestoreFiles: Bool
    public init(canRestoreFiles: Bool) { self.canRestoreFiles = canRestoreFiles }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        canRestoreFiles = l.bool("canRestoreFiles", or: false)
    }
}

/// `chat.rewound {id, ids, pal?}`: `id` and everything after it left the
/// conversation (the assistant's, or the Pal's); `ids` are those the host knew.
public struct ChatRewound: Codable, Sendable, Equatable {
    public var id: String
    public var ids: [String]
    public var pal: String?
    public init(id: String, ids: [String], pal: String? = nil) { self.id = id; self.ids = ids; self.pal = pal }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        ids = l.array(String.self, "ids", or: [])
        pal = l.string("pal")
    }
}

/// What a rewind gave back: the words for the composer, and whether the
/// files went back too.
public struct RewindOutcome: Sendable, Equatable {
    public var text: String
    public var filesRestored: Bool
    public init(text: String, filesRestored: Bool) { self.text = text; self.filesRestored = filesRestored }
}
