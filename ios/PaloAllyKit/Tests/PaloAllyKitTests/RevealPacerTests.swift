import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Reveal pacer")
struct RevealPacerTests {
    /// Every legal cut in `text`, as the prefix it would reveal.
    private func cuts(_ text: String, settled: Bool = false) -> [String] {
        var scan = RevealPacer.Scan(text: text, line: .init(start: 0, inCode: false), cut: 0, revealedChars: 0, settled: settled)
        var out: [String] = []
        while let c = scan.next() { out.append(String(decoding: text.utf8.prefix(c.offset), as: UTF8.self)) }
        return out
    }

    /// The UTF-8 offsets of `text`'s character boundaries.
    private func boundaries(_ text: String) -> Set<Int> {
        var out: Set<Int> = [0]
        var o = 0
        for c in text { o += c.utf8.count; out.insert(o) }
        return out
    }

    private func offsets(_ text: String, settled: Bool = false) -> [Int] {
        cuts(text, settled: settled).map(\.utf8.count)
    }

    // MARK: cut points

    @Test func chineseCutsBetweenWords() {
        let c = cuts("我们今天去公园散步。")
        #expect(c.contains("我们"))
        #expect(c.contains("我们今天"))
        #expect(c.last == "我们今天去公园散步。")
        // Not inside a word.
        #expect(!c.contains("我"))
        #expect(!c.contains("我们今"))
        #expect(!c.contains("我们今天去公"))
    }

    @Test func punctuationIsACut() {
        let c = cuts("好的，这件事我办好了！你看看。")
        #expect(c.contains("好的"))
        #expect(c.contains("好的，"))
        #expect(c.contains("好的，这件事我办好了！"))
    }

    @Test func englishCutsBetweenWords() {
        let c = cuts("Hello, wonderful world.")
        #expect(c.contains("Hello"))
        #expect(c.contains("Hello,"))
        #expect(c.contains("Hello, wonderful"))
        #expect(!c.contains("Hel"))
        #expect(!c.contains("Hello, wonder"))
    }

    @Test func theEndWaitsForTheRestOfItsWord() {
        // More may be coming: "公" could be "公园".
        #expect(!cuts("我们今天去公").contains("我们今天去公"))
        #expect(!cuts("Hello wor").contains("Hello wor"))
        // Unless it ends in a space or punctuation, or stopped coming.
        #expect(cuts("我们今天去，").contains("我们今天去，"))
        #expect(cuts("我们今天去公", settled: true).contains("我们今天去公"))
    }

    @Test func neverInsideAnEmojiSequence() {
        let text = "一家人👨‍👩‍👧‍👦出门了，带着🏳️‍🌈和👍🏽。"
        let b = boundaries(text)
        let o = offsets(text, settled: true)
        #expect(!o.isEmpty)
        #expect(o.allSatisfy(b.contains))
        // The end of what came may be the start of a sequence.
        #expect(!cuts("一家人👨").contains("一家人👨"))
        #expect(!cuts("一家人👨\u{200D}").contains("一家人👨\u{200D}"))
    }

    @Test func neverBetweenALetterAndItsMark() {
        let text = "un cafe\u{0301} noir, re\u{0301}sume\u{0301}."
        let b = boundaries(text)
        let o = offsets(text)
        #expect(o.allSatisfy(b.contains))
        #expect(!cuts(text).contains("un cafe"))
        #expect(cuts(text).contains("un cafe\u{0301}"))
    }

    @Test func notInsideBold() {
        let c = cuts("这是**重点内容**，记住。")
        #expect(c.contains("这是"))
        #expect(c.contains("这是**重点内容**"))
        for bad in ["这是*", "这是**", "这是**重点", "这是**重点内容", "这是**重点内容*"] {
            #expect(!c.contains(bad), "cut at \(bad)")
        }
        // Still open at the end of what came: nothing past the opener.
        let open = cuts("这是**重点内", settled: true)
        #expect(open.allSatisfy { !$0.contains("*") })
        // Closed at the very end, with nothing after it yet: wait for the next character.
        #expect(!cuts("这是**重点**").contains("这是**重点**"))
        #expect(cuts("这是**重点**", settled: true).contains("这是**重点**"))
    }

    @Test func notInsideCode() {
        let c = cuts("用 `git status --short` 看一下。")
        #expect(c.contains("用"))
        #expect(c.contains("用 `git status --short`"))
        #expect(!c.contains { $0.hasSuffix("`git") || $0.hasSuffix("status") || $0.hasSuffix("`") && $0.filter { $0 == "`" }.count == 1 })
    }

    @Test func notInsideALink() {
        let c = cuts("看 [这份文档](https://example.com/a/b?c=d) 吧。")
        #expect(c.contains("看"))
        #expect(c.contains("看 [这份文档](https://example.com/a/b?c=d)"))
        #expect(!c.contains { $0.contains("[") && !$0.contains(")") })
        #expect(!c.contains("看 [这份文档]"))
        // "]" at the end: a link if "(" comes next.
        #expect(!cuts("看 [这份文档]").contains("看 [这份文档]"))
        #expect(cuts("看 [这份文档]", settled: true).contains("看 [这份文档]"))
    }

    @Test func strikethroughAndItalic() {
        let c = cuts("这个 ~~不要了~~ 和 *斜体字* 都行。")
        #expect(!c.contains { $0.hasSuffix("~~不要") })
        #expect(c.contains("这个 ~~不要了~~"))
        #expect(!c.contains { $0.hasSuffix("*斜") })
        // A lone star between spaces, or inside a name, is just text.
        #expect(cuts("3 * 4 = 12，my_var_name 也行。").contains("3 * 4"))
        #expect(cuts("3 * 4 = 12，my_var_name 也行。").contains("3 * 4 = 12，my_var_name"))
    }

    @Test func tableRowsWhole() {
        let text = "比一下：\n\n| 项目 | A | B |\n|---|---|---|\n| 内存 | 16 | 64 |\n| 价格 | 低"
        let c = cuts(text, settled: true)
        #expect(c.contains("比一下："))
        #expect(c.contains("比一下：\n\n| 项目 | A | B |\n"))
        #expect(c.contains("比一下：\n\n| 项目 | A | B |\n|---|---|---|\n| 内存 | 16 | 64 |\n"))
        // Nothing inside a row, nor the unfinished last one.
        #expect(!c.contains { $0.hasSuffix("| 项目") || $0.hasSuffix("| 内存 |") || $0.hasSuffix("| 价格 | 低") })
    }

    @Test func codeBlocksByWholeLines() {
        let text = "看代码：\n```swift\nlet a = 1 // 第一行\nlet b = 2\n```\n就这样。"
        let c = cuts(text)
        #expect(c.contains("看代码：\n```swift\n"))
        #expect(c.contains("看代码：\n```swift\nlet a = 1 // 第一行\n"))
        #expect(c.contains("看代码：\n```swift\nlet a = 1 // 第一行\nlet b = 2\n```\n"))
        #expect(c.contains("看代码：\n```swift\nlet a = 1 // 第一行\nlet b = 2\n```\n就这样。"))
        #expect(!c.contains { $0.hasSuffix("```sw") || $0.hasSuffix("let a") || $0.hasSuffix("第一行") || $0.hasSuffix("let b = 2\n``") })
        // Markdown means nothing in code.
        let code = "```\nx = a ** b\n```\n"
        #expect(cuts(code) == ["```\n", "```\nx = a ** b\n", code])
    }

    @Test func markersComeWithTheirFirstWord() {
        let c = cuts("# 今天的安排\n- 第一项：开会\n1. 买菜\n> 引用的话\n- [ ] 待办事项")
        for bad in ["#", "# ", "# 今天的安排\n-", "# 今天的安排\n- ", "# 今天的安排\n- 第一项：开会\n1.", "# 今天的安排\n- 第一项：开会\n1. "] {
            #expect(!c.contains(bad), "cut at \(bad.debugDescription)")
        }
        #expect(c.contains("# 今天"))
        #expect(c.contains("# 今天的安排\n- 第一"))
        #expect(!c.contains { $0.hasSuffix("- [ ] ") || $0.hasSuffix("- [") })
        // A rule comes whole.
        #expect(!cuts("文字\n--").contains("文字\n-"))
    }

    /// A tick scans from the last cut, not from the start of its line, and
    /// only a little past what it may reveal: the cuts it finds are the
    /// same as a full scan's. (Not for Chinese: ICU's dictionary splits a
    /// run of characters by what's around it, "一家人" alone differently
    /// from "家人" after a cut; either way the cuts are word boundaries.)
    @Test func scanningFromACutFindsTheSameCuts() {
        let texts = [
            "This is **the point**, remember `git status` and [the link](http://a.b/c) . Then ~~drop it~~ and my_var and 3 * 4.",
            "- First: a meeting, **bring the laptop**\n1. Groceries `list`\n> A long quote here\nA plain paragraph, Hello, wonderful world.",
            "The family 👨‍👩‍👧‍👦 went out, with 🏳️‍🌈 and 👍🏽. un cafe\u{0301} noir.\n```swift\nlet a = 1\n```\nDone.",
        ]
        for text in texts {
            var full = RevealPacer.Scan(text: text, line: .init(start: 0, inCode: false), cut: 0, revealedChars: 0, settled: true)
            var all: [RevealPacer.Cut] = []
            while let c = full.next() { all.append(c) }
            for (i, c) in all.enumerated() {
                var from = RevealPacer.Scan(text: text, line: c.line, cut: c.offset, revealedChars: c.chars, settled: true, window: 12)
                var got: [Int] = []
                while let n = from.next(), n.chars <= c.chars + 12 { got.append(n.offset) }
                let want = all[(i + 1)...].filter { $0.chars <= c.chars + 12 }.map(\.offset)
                // The window's last word may be left for the next tick.
                #expect(Array(want.prefix(got.count)) == got, "from \(c.offset) in \(text.prefix(12))")
                #expect(got.count >= want.count - 1, "from \(c.offset) in \(text.prefix(12))")
            }
        }
    }

    @Test func scanningChineseFromACutStaysOutsideMarkdown() {
        let text = "一家人👨‍👩‍👧‍👦出门了，**带着很重要的东西**，还有 `代码片段` 和[链接](http://a.b)。"
        let b = boundaries(text)
        var full = RevealPacer.Scan(text: text, line: .init(start: 0, inCode: false), cut: 0, revealedChars: 0, settled: true)
        var all: [RevealPacer.Cut] = []
        while let c = full.next() { all.append(c) }
        for c in all {
            var from = RevealPacer.Scan(text: text, line: c.line, cut: c.offset, revealedChars: c.chars, settled: true, window: 10)
            while let n = from.next() {
                #expect(b.contains(n.offset))
                let shown = String(decoding: text.utf8.prefix(n.offset), as: UTF8.self)
                #expect(shown.components(separatedBy: "**").count % 2 == 1, "open bold at \(shown)")
                #expect(shown.filter { $0 == "`" }.count % 2 == 0, "open code at \(shown)")
                #expect(shown.filter { $0 == "[" }.count == shown.filter { $0 == ")" }.count, "open link at \(shown)")
            }
        }
    }

    // MARK: pacing

    /// Ticks every frame-ish 1/15 s from `start` until caught up or `until`.
    private func run(_ p: inout RevealPacer, from start: Double, until end: Double, step: Double = 1.0 / 15) -> Double? {
        var t = start
        while t <= end + 1e-9 {
            _ = p.tick(at: t)
            if p.isCaughtUp { return t }
            t += step
        }
        return nil
    }

    @Test func aThousandCharactersAtOnceShowWithinHalfASecond() throws {
        var p = RevealPacer()
        let line = "好的，这件事我已经办好了，结果和下一步都写在下面，你看一下有没有要改的地方。\n"
        let text = String(String(repeating: line, count: 30).prefix(1000))
        #expect(text.count == 1000)
        p.receive(text, at: 10)
        // Not all at once…
        _ = p.tick(at: 10)
        #expect(p.revealed.count < 500)
        #expect(!p.revealed.isEmpty)
        // …but all of it within 0.5 s, by whole lines.
        let done = try #require(run(&p, from: 10 + 1.0 / 15, until: 11))
        #expect(done - 10 <= 0.5)
        #expect(p.revealed == text)
        #expect(p.longestWait <= 0.5)
    }

    @Test func aBurstWithoutLineBreaksStillDrainsInTime() throws {
        var p = RevealPacer()
        let text = String(repeating: "这是一段很长很长没有换行的话，", count: 70)
        p.receive(text, at: 0)
        let done = try #require(run(&p, from: 0, until: 1))
        #expect(done <= 0.5)
        #expect(p.revealed == text)
    }

    @Test func aBurstRevealsWholeLines() {
        var p = RevealPacer()
        let text = String(repeating: "第一行的内容在这里，比较长一点。\n", count: 40)
        p.receive(text, at: 0)
        var t = 0.0
        var partial = 0
        while !p.isCaughtUp, t < 1 {
            if p.tick(at: t), !p.isCaughtUp, !p.revealed.hasSuffix("\n") { partial += 1 }
            t += 1.0 / 15
        }
        #expect(partial == 0)
    }

    @Test func aSteadyStreamStaysWithinHalfASecond() {
        var p = RevealPacer()
        let reply = String(repeating: "好的，这件事我已经办好了，**结果**和下一步都写在下面。你看一下 `有没有` 要改的地方。\n\n", count: 12)
        var pieces: [String] = []
        var cur = ""
        for ch in reply {
            cur.append(ch)
            if cur.count >= 3 { pieces.append(cur); cur = "" }
        }
        if !cur.isEmpty { pieces.append(cur) }
        // Three characters every 20 ms (the demo's pace), ticks every 1/15 s.
        var t = 0.0
        var nextTick = 0.0
        var shown: [Int] = []
        for piece in pieces {
            p.receive(piece, at: t)
            t += 0.02
            while nextTick <= t {
                _ = p.tick(at: nextTick)
                shown.append(p.revealed.count)
                nextTick += 1.0 / 15
            }
        }
        while !p.isCaughtUp, nextTick < t + 1 {
            _ = p.tick(at: nextTick)
            nextTick += 1.0 / 15
        }
        #expect(p.isCaughtUp)
        #expect(p.longestWait <= 0.5)
        // Smooth: every tick after the start shows something new.
        let steps = zip(shown.dropFirst(), shown).map { $0 - $1 }
        #expect(steps.dropFirst(3).filter { $0 == 0 }.count <= 2)
    }

    @Test func slowTextKeepsAMinimumPace() {
        var p = RevealPacer()
        p.receive("今天天气不错，适合出门。", at: 0)
        _ = p.tick(at: 0)
        // The first words show at once, the rest at no less than 30 a second.
        #expect(!p.revealed.isEmpty)
        #expect(p.revealed.count < 12)
        var t = 0.0
        while !p.isCaughtUp, t < 1 { t += 1.0 / 15; _ = p.tick(at: t) }
        #expect(t <= 0.45)
    }

    @Test func overdueTextShowsEvenInsideOpenMarkdown() throws {
        var p = RevealPacer()
        p.receive("结论：**这个方案在成本和速度上都比另外两个好得多", at: 0)
        let done = try #require(run(&p, from: 0, until: 1))
        #expect(done <= 0.5)
        #expect(p.longestWait <= 0.5)
    }

    @Test func flushShowsEverythingAtOnce() {
        var p = RevealPacer()
        p.receive("写到一半的**粗", at: 0)
        _ = p.tick(at: 0)
        #expect(!p.isCaughtUp)
        let flushed = p.flush(at: 0.1)
        #expect(flushed)
        #expect(p.isCaughtUp)
        #expect(p.revealed == "写到一半的**粗")
        #expect(p.backlog == 0)
        let again = p.flush(at: 0.2)
        let ticked = p.tick(at: 0.3)
        #expect(!again)
        #expect(!ticked)
    }

    @Test func aSyncThatGrewTheTextGoesOn() {
        var p = RevealPacer()
        p.receive("写到一半", at: 0)
        _ = p.flush(at: 0)
        p.replace(with: "写到一半了，接着写", at: 1)
        #expect(p.revealed == "写到一半")
        #expect(p.received == "写到一半了，接着写")
        _ = p.flush(at: 1.1)
        #expect(p.revealed == "写到一半了，接着写")
    }

    @Test func aSyncThatChangedShownTextRevealsItsLineAgain() {
        var p = RevealPacer()
        p.receive("第一段。\n第二段写到", at: 0)
        _ = p.flush(at: 0)
        p.replace(with: "第一段。\n第二段改了，继续", at: 1)
        #expect(p.revealed == "第一段。\n")
        _ = p.flush(at: 1.1)
        #expect(p.revealed == "第一段。\n第二段改了，继续")
    }

    @Test func aCodeBlockAfterAFlushIsStillKnown() {
        // The line state survives a jump: inside the block, whole lines.
        var p = RevealPacer()
        p.receive("```\nlet a = 1\n", at: 0)
        _ = p.flush(at: 0)
        p.receive("let b = **2 and more words here", at: 0.01)
        _ = p.tick(at: 0.05)
        #expect(p.revealed == "```\nlet a = 1\n")
    }
}
