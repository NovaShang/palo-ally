import Foundation
import Testing
import WebKit
@testable import PaloAllyFilePreview

/// Relative pictures in a preview: where they resolve (the document's own
/// folder, never out of it), what gets inlined (small images only, within a
/// page budget), and what the sandboxed HTML page does with `<img>`.
@Suite(.serialized) @MainActor struct PreviewImageTests {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    // MARK: paths

    @Test func pathsResolveAgainstTheDocumentsOwnFolder() {
        #expect(FilePreviewPaths.resolve("img/20-list-top.jpg", documentDirectory: "") == "img/20-list-top.jpg")
        #expect(FilePreviewPaths.resolve("img/a.jpg", documentDirectory: "docs/x") == "docs/x/img/a.jpg")
        #expect(FilePreviewPaths.resolve("../a.jpg", documentDirectory: "docs/x") == "docs/a.jpg")
        #expect(FilePreviewPaths.resolve("./a%20b.jpg", documentDirectory: "d") == "d/a b.jpg")
    }

    @Test func nothingEscapesTheFolderOrLeavesTheDevice() {
        for bad in ["../a.png", "../../etc/a.png", "img/../../a.png", "/etc/a.png", "~/a.png",
                    "https://x.test/a.png", "http://x.test/a.png", "file:///etc/a.png", "//x.test/a.png",
                    "data:image/png;base64,AAAA", "javascript:alert(1)", "..", ""] {
            #expect(FilePreviewPaths.resolve(bad, documentDirectory: "") == nil, "\(bad) resolved")
        }
        // Percent-encoded dots don't sneak past.
        #expect(FilePreviewPaths.resolve("%2e%2e/a.png", documentDirectory: "") == nil)
    }

    // MARK: the filler

    private func run(_ filler: PreviewImageFiller, _ srcs: [String]) async -> [String: String?] {
        var got: [String: String?] = [:]
        filler.deliver = { src, uri in got[src] = .some(uri) }
        filler.enqueue(srcs)
        for _ in 0..<200 where got.count < Set(srcs).count { try? await Task.sleep(nanoseconds: 10_000_000) }
        return got
    }

    @Test func aRelativeImageComesBackAsADataURI() async {
        let filler = PreviewImageFiller()
        var asked: [String] = []
        filler.source = .init(directory: "") { path in asked.append(path); return path == "img/a.png" ? self.png : nil }
        let got = await run(filler, ["img/a.png", "img/missing.png"])
        #expect(got["img/a.png"] ?? nil == "data:image/png;base64," + png.base64EncodedString())
        #expect(got["img/missing.png"] == .some(nil))
        #expect(asked == ["img/a.png", "img/missing.png"])
    }

    @Test func refusedSourcesAreNeverRead() async {
        let filler = PreviewImageFiller()
        var asked: [String] = []
        filler.source = .init(directory: "") { path in asked.append(path); return self.png }
        let bad = ["../x.png", "/etc/x.png", "https://x.test/x.png", "notes.txt", "img/readme"]
        let got = await run(filler, bad)
        #expect(asked.isEmpty, "read \(asked)")
        for b in bad { #expect(got[b] == .some(nil)) }
    }

    @Test func anImageOverTheCapIsAMiss() async {
        let filler = PreviewImageFiller()
        let big = Data(count: PreviewImageFiller.maxBytes + 1)
        filler.source = .init(directory: "") { _ in big }
        let got = await run(filler, ["big.png"])
        #expect(got["big.png"] == .some(nil))
        #expect(filler.bytesUsed == 0)
    }

    @Test func thePageBudgetStopsFillingButNeverLeavesABlank() async {
        let filler = PreviewImageFiller()
        let chunk = Data(count: PreviewImageFiller.maxBytes)
        filler.source = .init(directory: "") { _ in chunk }
        let names = (0..<6).map { "p\($0).png" }
        let got = await run(filler, names)
        let filled = names.filter { got[$0] ?? nil != nil }
        #expect(filled.count == PreviewImageFiller.byteBudget / PreviewImageFiller.maxBytes)
        #expect(got.count == names.count, "every request gets an answer")
        #expect(filler.bytesUsed <= PreviewImageFiller.byteBudget)
        // A new document starts a fresh budget.
        filler.reset()
        #expect(filler.bytesUsed == 0)
    }

    // MARK: the sandboxed HTML page

    private func htmlView(_ html: String, files: [String: Data], directory: String = "",
                          asked: @escaping (String) -> Void = { _ in }) -> WKWebView {
        let bridge = HTMLImageBridge()
        let config = WKWebViewConfiguration()
        bridge.install(in: config)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        bridge.attach(view)
        bridge.reset(source: .init(directory: directory) { path in asked(path); return files[path] })
        keep.append(bridge)
        view.loadHTMLString(html, baseURL: URL(string: "https://item.artifact.paloally.invalid/"))
        return view
    }
    private var keep: [HTMLImageBridge] { get { Self.kept } nonmutating set { Self.kept = newValue } }
    private static var kept: [HTMLImageBridge] = []

    private func eval(_ view: WKWebView, _ js: String) async -> Any? {
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let v = try? await view.evaluateJavaScript(js), !(v is NSNull),
               (v as? String)?.isEmpty != true, (v as? NSNumber)?.intValue != 0 { return v }
        }
        return nil
    }

    @Test func aRelativeImgInAnHTMLPageFillsAndStrangersStayOut() async {
        var asked: [String] = []
        let html = """
        <html><body>
        <img id="a" src="img/a.png" alt="A">
        <img id="miss" src="img/gone.png" alt="丢了">
        <img id="up" src="../secret.png" alt="up">
        <img id="net" src="https://x.test/p.png" alt="net">
        <img id="abs" src="/etc/p.png" alt="abs">
        </body></html>
        """
        let view = htmlView(html, files: ["img/a.png": png], asked: { asked.append($0) })
        let src = await eval(view, "(document.getElementById('a')||{src:''}).src") as? String
        #expect(src?.hasPrefix("data:image/png;base64,") == true)
        let stub = await eval(view, "document.querySelectorAll('[data-palo-stub]').length==2?2:0") as? NSNumber
        // The missing file and the `..` one: two quiet stubs. The absolute path
        // and the remote URL aren't ours; they stay as written (blocked in the app).
        #expect(stub?.intValue == 2)
        // The remote image was left alone (the content rule list blocks it in the app).
        let net = try? await view.evaluateJavaScript("document.getElementById('net').getAttribute('src')") as? String
        #expect(net == "https://x.test/p.png")
        let abs = try? await view.evaluateJavaScript("document.getElementById('abs').getAttribute('src')") as? String
        #expect(abs == "/etc/p.png")
        #expect(asked.sorted() == ["img/a.png", "img/gone.png"], "asked \(asked)")
    }

    @Test func theImageIsRelativeToThePagesOwnFolder() async {
        var asked: [String] = []
        let view = htmlView(#"<img id="a" src="img/a.png">"#, files: ["docs/img/a.png": png],
                            directory: "docs", asked: { asked.append($0) })
        let src = await eval(view, "(document.getElementById('a')||{src:''}).src") as? String
        #expect(src?.hasPrefix("data:image/png") == true)
        #expect(asked == ["docs/img/a.png"])
    }

    @Test func thePageCannotCallTheBridge() async throws {
        let view = htmlView("<p>x</p>", files: [:])
        _ = await eval(view, "document.querySelectorAll('p').length")
        let seen = try await view.evaluateJavaScript(
            "String(!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.paloImages)) + typeof window.paloImageSet") as? String
        #expect(seen == "falseundefined")
    }
}
