import Testing
@testable import PaloAllyKit

@Suite struct ReadAloudTextTests {
    @Test func markdownBecomesWords() {
        let md = """
        ## 标题

        - **重点**：见[清单](https://example.com/a)
        1. 第一步 `ls`

        ```swift
        let x = 1
        ```

        > 引用
        https://example.com/raw 结尾
        """
        let out = SpeechText.plain(md, codeOmitted: "代码略")  // i18n-ok: test data
        #expect(out == "标题\n\n重点：见清单\n1. 第一步 ls\n\n代码略\n\n引用\n结尾")
    }

    @Test func tablesReadAsCells() {
        let out = SpeechText.plain("| 项目 | 价格 |\n|:--|--:|\n| 机票 | 1280 |", codeOmitted: "code omitted")
        #expect(out == "项目, 价格\n机票, 1280")
    }

    @Test func englishCodeAndLanguage() {
        #expect(SpeechText.plain("Run:\n```\nmake\n```\nDone.", codeOmitted: "code omitted") == "Run:\ncode omitted\nDone.")
        #expect(SpeechText.language(of: "Your flight leaves at nine tomorrow morning, so please be early.") == .english)
        #expect(SpeechText.language(of: "明天早上九点的航班，记得早点出门。") == .chinese)
    }

    @Test func quotesFoldWhenLong() {
        #expect(!MessageFold.quoteFolds("周日下午去超市"))  // i18n-ok: test data
        #expect(MessageFold.quoteFolds("a\nb\nc\nd"))
        #expect(!MessageFold.quoteFolds("a\nb\nc"))
        #expect(MessageFold.quoteFolds(String(repeating: "字", count: 121)))  // i18n-ok: test data
        #expect(!MessageFold.quoteFolds(String(repeating: "字", count: 120)))  // i18n-ok: test data
    }
}
