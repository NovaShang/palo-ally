import Foundation
import JavaScriptCore
import Testing
@testable import PaloAllyFilePreview

/// The renderer is only as good as its bundled assets — these load the
/// vendored highlight.js / markdown-it plus preview.js into a bare JSContext
/// (no WebView) and run the pipeline offline. Ported from Bento Term.
@Suite struct FilePreviewWebAssetsTests {
    private func resourceURL(_ name: String) -> URL? {
        FilePreviewWebView.templateURL?.deletingLastPathComponent().appendingPathComponent(name)
    }

    @Test func bundledAssetsPresent() {
        for name in ["preview.html", "preview.css", "preview.js",
                     "highlight.min.js", "markdown-it.min.js", "purify.min.js",
                     "hljs-github.min.css", "hljs-github-dark.min.css", "LICENSES.txt"] {
            let url = resourceURL(name)
            #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true, "missing \(name)")
        }
    }

    @Test func pageLoadsNothingFromTheNetwork() throws {
        let html = try String(contentsOf: try #require(resourceURL("preview.html")), encoding: .utf8)
        #expect(!html.contains("http:"))
        #expect(!html.contains("https:"))
        #expect(!html.contains("//cdn"))
    }

    private func pipelineContext() throws -> JSContext {
        let ctx = try #require(JSContext())
        var jsError: String?
        ctx.exceptionHandler = { _, exc in jsError = exc?.toString() }
        ctx.evaluateScript("var window = this;")
        for file in ["highlight.min.js", "markdown-it.min.js", "preview.js"] {
            let url = try #require(resourceURL(file))
            ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            #expect(jsError == nil, "\(file): \(jsError ?? "")")
        }
        return ctx
    }

    private func render(_ ctx: JSContext, _ markdown: String) -> String {
        ctx.setObject(markdown, forKeyedSubscript: "src" as NSString)
        return ctx.evaluateScript("md.render(src)")?.toString() ?? ""
    }

    @Test func markdownRenders() throws {
        let ctx = try pipelineContext()
        let html = render(ctx, "# Title\n\n## 小节\n\n- item\n- **bold** and *it*\n\n1. one\n\n```swift\nlet a = 1\n```\n![alt](http://x/y.png)")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<h2>小节</h2>"))
        #expect(html.contains("<li>item</li>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>it</em>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("hljs-keyword"))          // fenced code highlighted
        #expect(html.contains("img-stub"))              // images stubbed, not loaded
        #expect(!html.contains("<img"))
    }

    @Test func tablesAndLinksRender() throws {
        let ctx = try pipelineContext()
        let html = render(ctx, "| a | b |\n|---|---|\n| 1 | 2 |\n\n[site](https://example.com) and https://bare.example.com")
        #expect(html.contains("<table>"))
        #expect(html.contains("<td>1</td>"))
        #expect(html.contains("<a href=\"https://example.com\">site</a>"))
        #expect(html.contains("href=\"https://bare.example.com\""))      // linkify
    }

    @Test func relativeImagesBecomeFillPlaceholders() throws {
        let ctx = try pipelineContext()
        let html = render(ctx, "![shot](images/screenshot.png)\n\n![remote](https://x/y.png)")
        #expect(html.contains("data-bento-src=\"images/screenshot.png\""))
        #expect(html.contains("img-stub"))          // the https one
        #expect(!html.contains("src=\"https:"))     // never a live remote src
    }

    @Test func markdownSourceHighlightsAsMarkdown() throws {
        let ctx = try pipelineContext()
        ctx.setObject("# Title\n\n- <b>item</b>", forKeyedSubscript: "src" as NSString)
        let html = ctx.evaluateScript("highlightedCode('design.md', src)")?.toString() ?? ""
        #expect(html.contains("hljs-section"))      // the heading, as source
        #expect(html.contains("&lt;"))              // embedded HTML stays text
        #expect(!html.contains("<b>"))
        #expect(!html.contains("<h1>"))
    }

    @Test func sanitizePassesThroughWhenNoDOM() throws {
        let ctx = try pipelineContext()
        let out = ctx.evaluateScript("bentoSanitize('<b>x</b>')")?.toString() ?? ""
        #expect(out == "<b>x</b>")
    }
}

#if canImport(WebKit) && os(macOS)
import WebKit

/// End-to-end through a real `FilePreviewWebView`, the path every preview
/// takes: render before the template has loaded, then read the DOM back.
@Suite(.serialized) @MainActor struct FilePreviewWebViewTests {

    private func waitFor(_ view: FilePreviewWebView, _ js: String) async -> Any? {
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let v = try? await view.evaluateJavaScript(js), !(v is NSNull),
               (v as? String)?.isEmpty != true, (v as? NSNumber)?.intValue != 0 {
                return v
            }
        }
        return nil
    }

    @Test func rendersMarkdownWithTablesThatScroll() async throws {
        let view = FilePreviewWebView.makePreview()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        // Chinese can break between any two characters: without a floor on
        // cell width this table would squeeze instead of scrolling.
        let wide = "| " + (1...8).map { "列\($0)" }.joined(separator: " | ") + " |\n|" +
            String(repeating: "---|", count: 8) + "\n| " + (1...8).map { _ in "很长的内容很长的内容" }.joined(separator: " | ") + " |"
        view.render(fileName: "design.md", text: "# 设计\n\n- 一\n- **二**\n\n" + wide, raw: false, dark: true)

        let h1 = await waitFor(view, "(document.querySelector('.markdown h1')||{}).textContent||''") as? String
        #expect(h1 == "设计")
        let items = await waitFor(view, "document.querySelectorAll('.markdown li').length") as? NSNumber
        #expect(items?.intValue == 2)
        // The wide table scrolls inside itself; the page never gets wider than the view.
        let overflow = await waitFor(view, "getComputedStyle(document.querySelector('.markdown table')).overflowX") as? String
        #expect(overflow == "auto")
        let tableScrolls = await waitFor(view, "(function(){var t=document.querySelector('.markdown table');return t.scrollWidth>t.clientWidth?1:0})()") as? NSNumber
        #expect(tableScrolls?.intValue == 1)
        let pageWidth = await waitFor(view, "document.documentElement.scrollWidth") as? NSNumber
        #expect((pageWidth?.intValue ?? .max) <= 390)
        let theme = await waitFor(view, "document.documentElement.dataset.theme") as? String
        #expect(theme == "dark")
    }

    @Test func rawShowsTheSource() async throws {
        let view = FilePreviewWebView.makePreview()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.render(fileName: "design.md", text: "# 设计\n\n- 一", raw: true, dark: false)
        let text = await waitFor(view, "(document.querySelector('pre.source')||{}).textContent||''") as? String
        #expect(text == "# 设计\n\n- 一")
        let headings = try await view.evaluateJavaScript("document.querySelectorAll('h1').length") as? NSNumber
        #expect(headings?.intValue == 0)
    }

    @Test func relativeImageFillsFromTheSource() async throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let view = FilePreviewWebView.makePreview()
        view.render(fileName: "doc.md", text: "![图1](figures/shot.png)\n\n![缺](missing.png)", raw: false, dark: false,
                    imageSource: .init(directory: "report") { path in
                        path == "report/figures/shot.png" ? png : nil
                    })
        let src = await waitFor(view, "(function(){var e=document.querySelector('img.md-img');return (e&&e.getAttribute('src'))||''})()") as? String
        #expect(src?.hasPrefix("data:image/png;base64,") == true)
        let stubs = await waitFor(view, "document.querySelectorAll('.img-stub').length") as? NSNumber
        #expect(stubs?.intValue == 1)
    }
}
#endif
