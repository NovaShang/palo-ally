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

    /// Fed a reply piece by piece, the cache gives exactly what splitting
    /// the whole text gives, at every step (tables, prose, fences with pipes
    /// inside, blank lines, a table cut mid-row).
    @Test func segmentCacheMatchesAFullSplitAtEveryStep() {
        let reply = """
        先说结论：

        | 方案 | 费用 |
        |:---|---:|
        | dev | ¥140 |
        | Air | ¥0 |

        细节如下，代码里的竖线不是表格：

        ```
        | 这一行在代码里 |
        echo a | b
        ```

        | 月份 | 合计 |
        |---|---|
        | 7 月 | ¥358 |
        最后一段，紧跟在表格后面。


        - 一条
        - 两条
        """
        let cache = MarkdownSegmentCache()
        var text = ""
        var i = 0
        var step = 1
        let chars = Array(reply)
        while i < chars.count {
            let n = min(chars.count - i, step)
            text += String(chars[i..<i + n])
            i += n
            step = step % 7 + 1
            #expect(cache.split(text) == MarkdownSegments.split(text), "differs after \(text.count) characters")
        }
        // Not a continuation (a final text that differs): starts over, still right.
        let other = "完全不同的一段\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        #expect(cache.split(other) == MarkdownSegments.split(other))
    }

    @Test func aTableBeingWrittenShowsWholeRowsOnly() {
        let rows = MarkdownSegments.completeTableRows
        #expect(rows("Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 |") == "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        #expect(rows("Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n") == "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        // The header waits for its separator.
        #expect(rows("Intro\n\n| a | b |\n|--") == "Intro\n\n")
        #expect(rows("Intro\n\n| a | b |\n") == "Intro\n\n")
        #expect(rows("| a |") == "")
        #expect(rows("| a | b |\n|---|---|\n") == "| a | b |\n|---|---|\n")
        // Prose is untouched, mid-line too.
        #expect(rows("Some text\nmore te") == "Some text\nmore te")
        #expect(rows("") == "")
    }

    @Test func bytePrefix() {
        #expect("你好，世界".hasBytePrefix("你好"))
        #expect("你好".hasBytePrefix(""))
        #expect("".hasBytePrefix(""))
        #expect(!"你".hasBytePrefix("你好"))
        #expect(!"abc".hasBytePrefix("abd"))
    }
}
