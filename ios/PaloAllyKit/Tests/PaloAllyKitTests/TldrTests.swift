import Foundation
import Testing
@testable import PaloAllyKit

/// 「TL;DR」: which reply gets the button, and the ask as the app reads it back.
struct TldrTests {
    private func msg(_ id: String, _ role: ChatRole, _ text: String, seq: Int64 = 1, tldr: Bool? = nil) -> ChatMessage {
        var m = ChatMessage(seq: seq, id: id, role: role, text: text, ts: 1)
        m.tldr = tldr
        return m
    }

    private let long = String(repeating: "字", count: TldrAsk.longChars)

    @Test func longIsCharactersOrLines() {
        #expect(TldrAsk.isLong(String(repeating: "a", count: TldrAsk.longChars)))
        #expect(!TldrAsk.isLong(String(repeating: "a", count: TldrAsk.longChars - 1)))
        #expect(TldrAsk.isLong((1...TldrAsk.longLines).map { "- \($0)" }.joined(separator: "\n")))
        // Blank lines aren't lines of text.
        #expect(!TldrAsk.isLong((1..<TldrAsk.longLines).map { "- \($0)" }.joined(separator: "\n\n\n")))
    }

    @Test func onlyUnderTheLatestFinishedLongReply() {
        let ask = msg("u1", .user, "帮我订餐厅")
        #expect(AppStore.tldrOffer(in: [ask, msg("a1", .assistant, long)]) == "a1")
        // A notice after it doesn't count; the owner's words after it do.
        #expect(AppStore.tldrOffer(in: [ask, msg("a1", .assistant, long), msg("n", .system, "已压缩")]) == "a1")
        #expect(AppStore.tldrOffer(in: [msg("a1", .assistant, long), msg("u2", .user, "好")]) == nil)
        // Only the latest: an older long reply gets nothing once a short one follows.
        #expect(AppStore.tldrOffer(in: [msg("a1", .assistant, long), msg("u2", .user, "好"), msg("a2", .assistant, "好的")]) == nil)
        // Still being written, or not yet the host's.
        var writing = msg("a1", .assistant, long)
        writing.isStreaming = true
        #expect(AppStore.tldrOffer(in: [ask, writing]) == nil)
        #expect(AppStore.tldrOffer(in: [ask, msg("a1", .assistant, long, seq: 0)]) == nil)
        // A TL;DR's own answer gets none.
        #expect(AppStore.tldrOffer(in: [msg("t", .user, "要点…", tldr: true), msg("a1", .assistant, long)]) == nil)
        #expect(AppStore.tldrOffer(in: []) == nil)
    }

    @Test func theAskIsMarkedOrTheMarker() throws {
        let kept = try JSONValue.object(["seq": 3, "id": "m3", "role": "user", "kind": "text", "text": "请总结", "channel": "app", "ts": 1, "tldr": true])
            .decode(ChatMessage.self)
        #expect(kept.isTldrAsk && kept.text == "请总结")
        #expect(msg("local-1", .user, TldrAsk.marker).isTldrAsk)
        #expect(!msg("m1", .user, "TL;DR").isTldrAsk)
        #expect(!msg("m1", .assistant, TldrAsk.marker).isTldrAsk)
        #expect(TldrAsk.shown("\(TldrAsk.marker)\n请总结") == "请总结")
        #expect(TldrAsk.shown(TldrAsk.marker).isEmpty)
        let cc = try JSONValue.object(["id": "c5", "ts": 1, "role": "owner", "text": "请总结", "tldr": true]).decode(CCMessage.self)
        #expect(cc.tldr == true)
    }
}
