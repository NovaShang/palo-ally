import Testing
@testable import PaloAllyKit

@Suite("Markdown tables")
struct MarkdownTableTests {
    @Test func splitsProseAndTables() {
        let md = """
        两台机器比一下：

        | 项目 | MacBook Air | dev |
        |:---|:---:|---:|
        | 内存 | 16 GB | 64 GB |
        | 适合 | 日常 | 跑重活 |

        结论：**dev** 更适合。
        """
        let segs = MarkdownSegments.split(md)
        #expect(segs.count == 3)
        guard case .text(let a) = segs[0], case .table(let t) = segs[1], case .text(let b) = segs[2] else {
            Issue.record("unexpected segments \(segs)"); return
        }
        #expect(a == "两台机器比一下：")
        #expect(b == "结论：**dev** 更适合。")
        #expect(t.header == ["项目", "MacBook Air", "dev"])
        #expect(t.rows == [["内存", "16 GB", "64 GB"], ["适合", "日常", "跑重活"]])
        #expect(t.alignments == [.leading, .center, .trailing])
        #expect(t.source.hasPrefix("| 项目 |") && t.source.hasSuffix("| 适合 | 日常 | 跑重活 |"))
    }

    @Test func proseOnlyIsOneSegment() {
        #expect(MarkdownSegments.split("你好\n\n- 一\n- 二") == [.text("你好\n\n- 一\n- 二")])
    }

    @Test func pipesInsideCodeFencesStayProse() {
        let md = "```\n| not | a table |\n```"
        #expect(MarkdownSegments.split(md) == [.text(md)])
    }

    @Test func noSeparatorMeansNoHeader() {
        let segs = MarkdownSegments.split("| a | b |\n| c | d |")
        guard case .table(let t) = segs.first else { Issue.record("no table"); return }
        #expect(t.header == nil)
        #expect(t.rows == [["a", "b"], ["c", "d"]])
        #expect(t.columnCount == 2)
    }

    @Test func raggedRowsArePadded() {
        let segs = MarkdownSegments.split("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")
        guard case .table(let t) = segs.first else { Issue.record("no table"); return }
        #expect(t.columnCount == 4)
        #expect(t.header == ["a", "b", "c", ""])
        #expect(t.rows == [["1", "", "", ""], ["1", "2", "3", "4"]])
        #expect(t.alignments == [.leading, .leading, .leading, .leading])
    }

    @Test func escapedPipesStayInTheCell() {
        #expect(MarkdownSegments.cells(#"| a \| b | `c` |"#) == ["a | b", "`c`"])
    }

    @Test func aHalfStreamedSeparatorStillMakesAHeader() {
        let segs = MarkdownSegments.split("| 项目 | 价格 |\n|--")
        guard case .table(let t) = segs.first else { Issue.record("no table"); return }
        #expect(t.header == ["项目", "价格"])
        #expect(t.rows.isEmpty)
    }
}
