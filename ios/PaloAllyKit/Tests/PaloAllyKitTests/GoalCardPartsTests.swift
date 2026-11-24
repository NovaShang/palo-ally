import Testing
@testable import PaloAllyKit

struct GoalCardPartsTests {
    @Test func plainItemsAsBefore() {
        #expect(GoalCardPart.split("今天：\n- 一\n* 二\n• 三\n· 四\n完") == [
            .markdown("今天："), .item("一", under: ""), .item("二", under: ""), .item("三", under: ""), .item("四", under: ""), .markdown("完"),
        ])
    }

    @Test func aTableStaysWhole() {
        let table = "| | 工作线 | 现状 |\n|---|---|---|\n| 🟢 | Cut sim / 229 | #1463 已合 |\n| 🔴 | 归档 / 38 | 等 D33 |"
        #expect(GoalCardPart.split("W48：七条线。\n\(table)\n- **风险最大的是 52**\n- D25 要动") == [
            .markdown("W48：七条线。\n\(table)"), .item("**风险最大的是 52**", under: ""), .item("D25 要动", under: ""),
        ])
    }

    @Test func whatIsUnderAnItemStaysWithIt() {
        #expect(GoalCardPart.split("- 合 #1466\n  - 先跑测试\n  - 再合\n\n  说明一句\n- 下一条\n\n后记") == [
            .item("合 #1466", under: "- 先跑测试\n- 再合\n\n说明一句"), .item("下一条", under: ""), .markdown("后记"),
        ])
    }

    @Test func codeHeadingsNumbersAndRulesAreMarkdown() {
        #expect(GoalCardPart.split("## 标题\n1. 一\n2. 二\n\n```\n- 不是条目\n```\n---\n* * *\n段落") == [
            .markdown("## 标题\n1. 一\n2. 二\n\n```\n- 不是条目\n```\n---\n* * *\n段落"),
        ])
    }

    @Test func nothing() {
        #expect(GoalCardPart.split(" \n\n").isEmpty)
    }
}
