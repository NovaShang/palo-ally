import Foundation
import Testing
@testable import PaloAllyKit

/// 「TL;DR」 (chat.tldr): the answer as the app reads it, and as 拷贝 writes it.
struct TldrTests {
    @Test func decodesAndCopiesAsMarkdown() throws {
        let json: JSONValue = [
            "points": ["订了周六 12 点的餐厅"],
            "ownWords": [["text": "要靠窗\n别太吵", "messageId": "m3", "ts": 1_793_000_000_000]],
            "relayed": [["who": "网站", "gist": "今晚不部署"]],
            "covered": 12, "since": 1_792_999_000_000, "until": 1_793_000_000_000, "lastMessageId": "m9", "cached": false,
        ]
        let r = try json.decode(TldrResult.self)
        #expect(r.covered == 12 && r.ownWords.first?.messageId == "m3" && r.relayed.first?.who == "网站")
        let md = r.markdown(title: "要点", ownTitle: "原话", relayedTitle: "转述", time: { _ in "9:00" })
        #expect(md == "## 要点\n\n- 订了周六 12 点的餐厅\n\n### 原话\n\n> 要靠窗\n> 别太吵\n> (9:00)\n\n### 转述\n\n- 网站: 今晚不部署\n")
    }

    @Test func missingPartsAreEmpty() throws {
        let r = try JSONValue.object(["points": ["a"], "covered": 1]).decode(TldrResult.self)
        #expect(r.ownWords.isEmpty && r.relayed.isEmpty && !r.cached)
    }
}
