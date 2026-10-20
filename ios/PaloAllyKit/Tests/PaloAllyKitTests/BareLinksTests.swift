import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Bare links")
struct BareLinksTests {
    private func mark(_ s: String) -> String { BareLinks.marking(in: s) }

    /// The links Foundation's Markdown makes of the marked text.
    private func links(_ s: String) throws -> [String] {
        let parsed = try AttributedString(markdown: BareLinks.marking(in: s),
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return parsed.runs.compactMap(\.link).map(\.absoluteString)
    }

    @Test func endsAtFullWidthPunctuation() throws {
        #expect(mark("可以装：https://example.ts.net/ota/，然后打开") == "可以装：<https://example.ts.net/ota/>，然后打开")
        #expect(mark("见 https://a.b/c。好") == "见 <https://a.b/c>。好")
        #expect(mark("地址：https://a.b/c：端口") == "地址：<https://a.b/c>：端口")
        #expect(mark("（见https://a.b/c）") == "（见<https://a.b/c>）")
        #expect(mark("「https://a.b/c」") == "「<https://a.b/c>」")
        #expect(try links("可以装：https://example.ts.net/ota/，然后打开") == ["https://example.ts.net/ota/"])
    }

    @Test func endsAtChineseLetters() throws {
        #expect(mark("打开https://a.b/c然后") == "打开<https://a.b/c>然后")
        #expect(try links("打开https://a.b/c然后") == ["https://a.b/c"])
    }

    @Test func inFullWidthParentheses() throws {
        #expect(mark("下载（https://a.b/c）") == "下载（<https://a.b/c>）")
        #expect(try links("下载（https://a.b/c）") == ["https://a.b/c"])
    }

    @Test func asciiPunctuationAtTheEnd() throws {
        #expect(mark("Go to https://a.b/c.") == "Go to <https://a.b/c>.")
        #expect(mark("https://a.b/c, then") == "<https://a.b/c>, then")
        #expect(mark("(see https://a.b/c)") == "(see <https://a.b/c>)")
        #expect(mark("https://en.wikipedia.org/wiki/Foo_(bar)") == "<https://en.wikipedia.org/wiki/Foo_(bar)>")
        #expect(mark("**https://a.b/c**") == "**<https://a.b/c>**")
    }

    @Test func queryFragmentAndEncodings() throws {
        let url = "https://a.b/p?q=1&r=%E4%B8%AD#frag"
        #expect(mark("看 \(url)，好") == "看 <\(url)>，好")
        #expect(try links("看 \(url)，好") == [url])
        #expect(mark("https://xn--fiqs8s.cn/a。") == "<https://xn--fiqs8s.cn/a>。")
    }

    @Test func twoLinksOnALine() throws {
        #expect(mark("先 https://a.b/1，再 https://c.d/2。") == "先 <https://a.b/1>，再 <https://c.d/2>。")
        #expect(try links("先 https://a.b/1，再 https://c.d/2。") == ["https://a.b/1", "https://c.d/2"])
    }

    @Test func wwwGetsAScheme() throws {
        #expect(try links("去 www.example.com/a，看看") == ["http://www.example.com/a"])
    }

    @Test func linksAndCodeLeftAlone() {
        for s in [
            "[链接](https://a.b/c)，然后", "[https://a.b/c](https://a.b/c)", "![图](https://a.b/i.png)",
            "<https://a.b/c>，然后", "`https://a.b/c，x`", "代码 `x https://a.b/c` 里",
            "``a ` https://a.b/c``", "```\nhttps://a.b/c，x\n```", "~~~sh\ncurl https://a.b/c\n~~~",
            "\\https://a.b/c", "没有链接", "a.www.b", "xhttps://a.b", "https://", "<a href=\"https://a.b\">x</a>",
        ] {
            #expect(mark(s) == s, "\(s)")
        }
    }

    @Test func afterACodeBlock() {
        #expect(mark("```\nhttps://a.b\n```\n见 https://c.d，好") == "```\nhttps://a.b\n```\n见 <https://c.d>，好")
        #expect(mark("`x` https://a.b，`y`") == "`x` <https://a.b>，`y`")
    }
}
