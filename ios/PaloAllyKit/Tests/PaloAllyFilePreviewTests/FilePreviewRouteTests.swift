import Foundation
import Testing
@testable import PaloAllyFilePreview

/// Markdown goes to our renderer, everything else to Quick Look. Easy to widen
/// by accident, so it is pinned here.
struct FilePreviewRouteTests {

    @Test("Markdown names route to the web renderer, whatever the case or folder")
    func markdownNames() {
        for name in ["design.md", "artifacts/allies/design.md", "README.MD", "notes.markdown",
                     "a.mdown", "b.mkd", "docs/paloally-prd-v2.md", "报告.md"] {
            #expect(FilePreviewRoute.forFile(name: name) == .markdown, "\(name)")
        }
    }

    @Test("Every other type keeps Quick Look")
    func everythingElse() {
        for name in ["report.pdf", "photo.jpg", "notes.txt", "index.html", "data.csv",
                     "deck.key", "budget.xlsx", "main.swift", "clip.mov", "design.md.zip",
                     "md", ".md"] {
            #expect(FilePreviewRoute.forFile(name: name) == .quickLook, "\(name)")
        }
    }

    @Test("The media type only speaks for a name without an extension")
    func mediaTypeFallback() {
        #expect(FilePreviewRoute.forFile(name: "file", mediaType: "text/markdown") == .markdown)
        #expect(FilePreviewRoute.forFile(name: "README", mediaType: "text/x-markdown; charset=utf-8") == .markdown)
        #expect(FilePreviewRoute.forFile(name: "file", mediaType: "text/plain") == .quickLook)
        #expect(FilePreviewRoute.forFile(name: "file", mediaType: nil) == .quickLook)
        // A real extension wins over a stray media type.
        #expect(FilePreviewRoute.forFile(name: "notes.pdf", mediaType: "text/markdown") == .quickLook)
        #expect(FilePreviewRoute.forFile(name: "notes.md", mediaType: "application/octet-stream") == .markdown)
    }

    @Test("The page always gets a name it renders as Markdown")
    func renderName() {
        #expect(FilePreviewRoute.markdownRenderName("artifacts/allies/design.md") == "design.md")
        #expect(FilePreviewRoute.markdownRenderName("README") == "README.md")
        #expect(FilePreviewRoute.markdownRenderName("notes.txt") == "notes.txt.md")
        #expect(FilePreviewRoute.markdownRenderName("") == "file.md")
        #expect(FilePreviewRoute.markdownRenderName("X.MARKDOWN") == "X.MARKDOWN")
    }

    @Test("Relative images resolve against the document's folder and never climb out")
    func imagePaths() {
        #expect(FilePreviewPaths.resolve("fig.png", documentDirectory: "") == "fig.png")
        #expect(FilePreviewPaths.resolve("./img/fig.png", documentDirectory: "report") == "report/img/fig.png")
        #expect(FilePreviewPaths.resolve("../shared/a.png", documentDirectory: "report/2026") == "report/shared/a.png")
        #expect(FilePreviewPaths.resolve("img%20one.png", documentDirectory: "") == "img one.png")
        #expect(FilePreviewPaths.resolve("a.png?raw=1#top", documentDirectory: "x") == "x/a.png")
        #expect(FilePreviewPaths.resolve("../a.png", documentDirectory: "") == nil)
        #expect(FilePreviewPaths.resolve("/etc/a.png", documentDirectory: "x") == nil)
        #expect(FilePreviewPaths.resolve("~/a.png", documentDirectory: "x") == nil)
        #expect(FilePreviewPaths.resolve("https://x/y.png", documentDirectory: "x") == nil)
        #expect(FilePreviewPaths.resolve("", documentDirectory: "x") == nil)
    }

    @Test("Only http(s) and mail leave the page")
    func externalLinks() throws {
        for s in ["https://example.com", "http://a.b/c", "mailto:a@b.c", "HTTPS://X.Y"] {
            #expect(FilePreviewWebView.opensOutside(try #require(URL(string: s))), "\(s)")
        }
        for s in ["file:///etc/passwd", "javascript:alert(1)", "other.md", "paloally://pair"] {
            #expect(!FilePreviewWebView.opensOutside(try #require(URL(string: s))), "\(s)")
        }
    }
}
