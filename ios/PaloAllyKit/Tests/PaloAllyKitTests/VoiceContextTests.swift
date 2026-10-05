import Testing
@testable import PaloAllyKit

@Suite("Voice context")
struct VoiceContextTests {
    private func msg(_ i: Int, _ role: ChatRole, _ text: String, kind: ChatKind = .text) -> ChatMessage {
        ChatMessage(seq: Int64(i), id: "m\(i)", role: role, kind: kind, text: text, ts: Int64(i))
    }

    @Test func plainTextStripsMarkdown() {
        let md = """
        ## 结果
        - **东航 MU5100**，¥1,280，详见 [上海出行比价](https://example.com/a)
        ```swift
        let secret = 1
        ```
        | 航班 | 价格 |
        |---|---|
        | MU5100 | 1280 |
        > 原文见 https://ceair.com/x?y=1 ![图](img.png)
        用 `paloally pair` 配对
        """
        let s = VoiceContext.plainText(md)
        #expect(s.contains("东航 MU5100"))
        #expect(s.contains("上海出行比价"))
        #expect(s.contains("paloally pair"))
        #expect(!s.contains("**") && !s.contains("`") && !s.contains("##"))
        #expect(!s.contains("secret"))       // code block gone
        #expect(!s.contains("|"))            // table gone
        #expect(!s.contains("http"))         // urls gone
        #expect(!s.contains("img.png"))      // image gone
        #expect(!s.contains("\n"))
    }

    @Test func newestWinsWithinBudget() {
        var messages: [ChatMessage] = []
        for i in 0..<12 { messages.append(msg(i, i % 2 == 0 ? .user : .assistant, "第\(i)条消息，内容比较长" + String(repeating: "啊", count: 60))) }
        let s = VoiceContext.build(messages: messages, maxChars: 400)
        #expect(s.count <= 400)
        #expect(s.contains("第11条"))         // the newest message is always in
        #expect(!s.contains("第0条消息"))      // the oldest prose falls out
        // Oldest → newest order in what remains.
        let i9 = s.range(of: "第9条")!.lowerBound, i11 = s.range(of: "第11条")!.lowerBound
        #expect(i9 < i11)
    }

    @Test func titlesQuoteAndOlderTermsAreKept() {
        var messages = [msg(0, .user, "帮我看看 SmartSLD 的数据，还有《满汉全席》的文档")]
        for i in 1...11 { messages.append(msg(i, .assistant, "好的" + String(repeating: "嗯", count: 200))) }
        let s = VoiceContext.build(
            messages: messages, assistantName: "Palo",
            goalTitles: ["十一月回国机票", "晨报"], artifactTitles: ["上海出行比价", "晨报"],
            quote: "MU5100 降到 ¥4,860", maxChars: 700)
        #expect(s.count <= 700)
        #expect(s.hasPrefix("MU5100 降到 ¥4,860"))
        #expect(s.contains("Palo、十一月回国机票、晨报、上海出行比价"))  // de-duplicated
        #expect(s.contains("SmartSLD"))        // a term from a message whose prose didn't fit
        #expect(s.contains("满汉全席"))
    }

    @Test func skipsNoticesAndEmptyInput() {
        #expect(VoiceContext.build(messages: []).isEmpty)
        let s = VoiceContext.build(messages: [msg(0, .system, "助理刚刚重启了", kind: .notice),
                                              msg(1, .assistant, "", kind: .text)])
        #expect(s.isEmpty)
    }
}
