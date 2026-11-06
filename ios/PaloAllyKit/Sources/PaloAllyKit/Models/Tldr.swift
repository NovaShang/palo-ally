import Foundation

/// 「TL;DR」 (`chat.tldr`): the recent stretch of a conversation, the
/// assistant's or a session's, in a few points, with the owner's own words
/// (checked verbatim on the computer) apart from what assistants said or
/// passed on. Nothing goes into the conversation; the computer keeps the
/// last answer in memory until a new message comes.
public struct TldrResult: Decodable, Sendable, Equatable {
    public var points: [String]
    public var ownWords: [TldrQuote]
    public var relayed: [TldrRelayed]
    /// How many messages it covers, from `since` to `until` (ms).
    public var covered: Int
    public var since: Int64
    public var until: Int64
    public var lastMessageId: String
    /// The same answer as last time: nothing new since.
    public var cached: Bool

    public init(points: [String], ownWords: [TldrQuote] = [], relayed: [TldrRelayed] = [], covered: Int,
                since: Int64 = 0, until: Int64 = 0, lastMessageId: String = "", cached: Bool = false) {
        self.points = points; self.ownWords = ownWords; self.relayed = relayed; self.covered = covered
        self.since = since; self.until = until; self.lastMessageId = lastMessageId; self.cached = cached
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        points = l.array(String.self, "points", or: [])
        ownWords = l.array(TldrQuote.self, "ownWords", or: [])
        relayed = l.array(TldrRelayed.self, "relayed", or: [])
        covered = l.int("covered", or: 0)
        since = l.millis("since", or: 0)
        until = l.millis("until", or: 0)
        lastMessageId = l.string("lastMessageId", or: "")
        cached = l.bool("cached", or: false)
    }

    /// The summary as Markdown, for 拷贝.
    public func markdown(title: String, ownTitle: String, relayedTitle: String, time: (Int64) -> String) -> String {
        var out = "## \(title)\n\n" + points.map { "- \($0)" }.joined(separator: "\n")
        if !ownWords.isEmpty {
            out += "\n\n### \(ownTitle)\n\n" + ownWords.map { "> \($0.text.replacingOccurrences(of: "\n", with: "\n> "))\n> (\(time($0.ts)))" }
                .joined(separator: "\n\n")
        }
        if !relayed.isEmpty {
            out += "\n\n### \(relayedTitle)\n\n" + relayed.map { "- \($0.who): \($0.gist)" }.joined(separator: "\n")
        }
        return out + "\n"
    }
}

/// One of the owner's own sentences, verbatim, and the message it is in.
public struct TldrQuote: Decodable, Sendable, Equatable, Hashable {
    public var text: String
    public var messageId: String
    public var ts: Int64

    public init(text: String, messageId: String, ts: Int64) {
        self.text = text; self.messageId = messageId; self.ts = ts
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        text = l.string("text", or: "")
        messageId = l.string("messageId", or: "")
        ts = l.millis("ts", or: 0)
    }
}

/// What an assistant, a session or someone's assistant said or passed on.
public struct TldrRelayed: Decodable, Sendable, Equatable, Hashable {
    public var who: String
    public var gist: String

    public init(who: String, gist: String) {
        self.who = who; self.gist = gist
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        who = l.string("who", or: "")
        gist = l.string("gist", or: "")
    }
}

public struct TldrParams: Codable, Sendable {
    public var scope: String
    public var id: String?
    public init(scope: String, id: String? = nil) { self.scope = scope; self.id = id }
}
