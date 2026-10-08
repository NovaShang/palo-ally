import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Markdown renderer, ported from Bento Term's `BentoFilePreviewKit`:
/// GitHub-flavored Markdown (markdown-it) with highlighted code blocks
/// (highlight.js), or the file's source text when `raw` is set.
///
/// Isolation: the page is a local template loaded once via `loadFileURL`;
/// content goes in as a JSON payload through `evaluateJavaScript`, never as
/// interpolated HTML. The navigation delegate cancels everything except the
/// initial template load — a tapped http(s) link opens outside the app, and
/// the page has no way to reach the network (remote images render as stubs,
/// embedded HTML is scrubbed by DOMPurify).
@MainActor
public final class FilePreviewWebView: WKWebView, WKNavigationDelegate {

    private struct Payload: Encodable {
        let name: String
        let text: String
        let raw: Bool
        let dark: Bool
    }

    /// Where a Markdown file's relative images come from. `directory` is the
    /// document's own folder under that root ("" for the root itself); `load`
    /// answers a root-relative path (see `FilePreviewPaths`) with the file's
    /// bytes, or nil — and should refuse anything over `imageMaxBytes` before
    /// fetching it.
    public struct ImageSource {
        public let directory: String
        public let load: @MainActor (_ path: String) async -> Data?
        public init(directory: String, load: @escaping @MainActor (_ path: String) async -> Data?) {
            self.directory = directory
            self.load = load
        }
    }

    private var templateReady = false
    private var pending: Payload?
    private var imageSource: ImageSource?
    private var imageFillSeq = 0
    private var imageQueue: [String] = []
    private var imageFilling = false
    private var imageBytesUsed = 0

    /// A single image we're willing to inline. Bigger than this is a photo the
    /// preview has no business holding in the DOM.
    public static let imageMaxBytes = 8 * 1024 * 1024
    /// Total across one document. Every fill stays resident as a base64 data:
    /// URI (~4/3 of the file), so this — not a count of images — is what keeps
    /// a photo-heavy document from evicting the app on iOS.
    private static let imageByteBudget = 24 * 1024 * 1024

    public static func makePreview() -> FilePreviewWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The page asks for images as they come into view; this is that channel.
        let bridge = FilePreviewImageBridge()
        cfg.userContentController.add(bridge, name: "bentoImages")
        let v = FilePreviewWebView(frame: .zero, configuration: cfg)
        bridge.owner = v
        v.navigationDelegate = v
        #if canImport(UIKit)
        // The page paints its own background; until it loads, show what's
        // behind (no white flash in dark mode).
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        #endif
        if let html = templateURL {
            v.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return v
    }

    /// The bundled page; its folder holds every script and style it loads.
    public nonisolated static var templateURL: URL? {
        Bundle.module.url(forResource: "preview", withExtension: "html", subdirectory: "FilePreview")
    }

    /// Render `text` as `fileName`'s content — rendered Markdown, or its
    /// source when `raw`. Safe to call before the template finished loading:
    /// the last payload wins once it's up.
    public func render(fileName: String, text: String, raw: Bool, dark: Bool,
                       imageSource: ImageSource? = nil) {
        self.imageSource = imageSource
        let payload = Payload(name: fileName, text: text, raw: raw, dark: dark)
        guard templateReady else { pending = payload; return }
        send(payload)
    }

    /// Ship a payload to the page. Separate from `render` on purpose: the
    /// deferred flush in `didFinish` must NOT touch `imageSource` — the first
    /// render of a fresh view always lands there.
    private func send(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        // The JSON-encoded payload embeds directly as a JS object literal.
        evaluateJavaScript("bentoRender(\(json))") { [weak self] _, _ in
            MainActor.assumeIsolated { self?.startImageFill(raw: payload.raw) }
        }
    }

    /// Follow an appearance change without re-rendering.
    public func setDark(_ dark: Bool) {
        guard templateReady else {
            if let p = pending {
                pending = Payload(name: p.name, text: p.text, raw: p.raw, dark: dark)
            }
            return
        }
        evaluateJavaScript("bentoSetTheme(\(dark))")
    }

    // MARK: - Markdown image fill

    /// Hand the freshly rendered document a new fill sequence. The page then
    /// requests images as they approach the viewport (`bentoObserveImages`),
    /// and each request comes back through `enqueueImages`.
    private func startImageFill(raw: Bool) {
        imageFillSeq += 1
        imageQueue.removeAll()
        imageBytesUsed = 0
        guard !raw else { return }
        guard imageSource != nil else {
            // Nothing can ever fill: say so instead of leaving blank boxes.
            evaluateJavaScript("bentoStubUnfilled()")
            return
        }
        evaluateJavaScript("bentoObserveImages(\(imageFillSeq))")
    }

    fileprivate func enqueueImages(_ srcs: [String], seq: Int) {
        guard seq == imageFillSeq, imageSource != nil else { return }
        imageQueue.append(contentsOf: srcs)
        pumpImageQueue()
    }

    /// One at a time: each image is its own round trip to the host.
    private func pumpImageQueue() {
        guard !imageFilling, !imageQueue.isEmpty, let source = imageSource else { return }
        imageFilling = true
        let seq = imageFillSeq
        Task { @MainActor [weak self] in
            while true {
                guard let self, self.imageFillSeq == seq, !self.imageQueue.isEmpty else { break }
                await self.fillOne(src: self.imageQueue.removeFirst(), source: source)
            }
            guard let self else { return }
            self.imageFilling = false
            // A render that landed mid-drain abandoned this queue; keep going
            // with whatever the new document asked for since.
            self.pumpImageQueue()
        }
    }

    private func fillOne(src: String, source: ImageSource) async {
        guard let path = FilePreviewPaths.resolve(src, documentDirectory: source.directory),
              let mime = FilePreviewImageMIME.forPath(path),
              let bytes = await source.load(path),
              bytes.count <= Self.imageMaxBytes,
              imageBytesUsed + bytes.count <= Self.imageByteBudget
        else {
            callJS("bentoFailImage", src)
            return
        }
        imageBytesUsed += bytes.count
        callJS("bentoSetImage", src, "data:\(mime);base64,\(bytes.base64EncodedString())")
    }

    /// Evaluate `fn(args…)` with each argument JSON-encoded (safe embedding).
    private func callJS(_ fn: String, _ args: String...) {
        let encoded = args.map { arg -> String in
            let data = (try? JSONEncoder().encode([arg])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(data.dropFirst().dropLast())
        }
        evaluateJavaScript("\(fn)(\(encoded.joined(separator: ",")))")
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        templateReady = true
        if let p = pending {
            pending = nil
            send(p)
        }
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Initial template load (and only that) is a local file navigation.
        if navigationAction.navigationType == .other,
           navigationAction.request.url?.isFileURL == true, !templateReady {
            decisionHandler(.allow)
            return
        }
        // A tapped link leaves this view; nothing else navigates, ever.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           Self.opensOutside(url) {
            Self.openOutside(url)
        }
        decisionHandler(.cancel)
    }

    /// Links that leave for the browser (or mail). Anything else — a relative
    /// link to another file, `javascript:` — goes nowhere.
    public nonisolated static func opensOutside(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func openOutside(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// Carries the page's "these images are coming into view" messages to the
/// view. A separate object because `WKUserContentController` retains its
/// handlers — registering the view itself would be a retain cycle.
private final class FilePreviewImageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: FilePreviewWebView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let seq = body["seq"] as? Int,
              let srcs = body["srcs"] as? [String]
        else { return }
        MainActor.assumeIsolated { owner?.enqueueImages(srcs, seq: seq) }
    }
}
