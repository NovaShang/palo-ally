import Foundation

// 「TL;DR」 (Models/Tldr.swift): the button under the conversation's latest
// long reply, and the ask it sends.

extension AppStore {
    /// The reply the 「TL;DR」 button goes under: the conversation's latest,
    /// once its turn is over, when it's long. None while a turn is on, under
    /// a TL;DR's own answer, offline, or in a session only looked at.
    public var tldrOfferID: String? {
        if case .session = scope { return nil }
        guard connection.isOnline, !busyForRewind else { return nil }
        return Self.tldrOffer(in: messages)
    }

    /// The latest reply, if it's finished, long and not a TL;DR's answer
    /// (the owner's last words before it weren't a TL;DR ask). Notices
    /// after it don't count; anything else after it does.
    nonisolated static func tldrOffer(in messages: [ChatMessage]) -> String? {
        guard let i = messages.lastIndex(where: { $0.role != .system }) else { return nil }
        let reply = messages[i]
        guard reply.role == .assistant, reply.kind == .text, !reply.isStreaming, reply.seq > 0,
              TldrAsk.isLong(reply.text) else { return nil }
        if let asked = messages[..<i].last(where: { $0.role == .user }), asked.isTldrAsk { return nil }
        return reply.id
    }

    /// The button: the ask goes to this conversation's agent like any
    /// message (the assistant's chat.send, a session's pals.send), alone:
    /// no quote goes with it.
    public func askTldr() {
        send(TldrAsk.marker)
    }
}
