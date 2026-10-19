import PaloAllyKit
import SwiftUI
import WebKit

/// One web tab's live page. It is kept for as long as the tab is open: the
/// pane hides and shows it instead of making it again, so switching tabs
/// never reloads a page (the logic of Bento's preview dock, in SwiftUI).
@MainActor
final class WebTabPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// The address the tab was stored with; what the pane matches the tab by.
    var startURL: String
    let webView: WKWebView
    @Published private(set) var title = ""
    @Published private(set) var address = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    private var observers: [NSKeyValueObservation] = []

    init(url: String) {
        startURL = url
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        observers = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.title = v.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.address = v.url?.absoluteString ?? "" }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.canGoBack = v.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.canGoForward = v.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.isLoading = v.isLoading }
            },
        ]
        if let u = WebAddress.url(from: url) { webView.load(URLRequest(url: u)) }
    }

    /// What the owner typed in the address field: loads it, and tells the
    /// caller the address to keep in the tab.
    @discardableResult
    func go(_ text: String) -> String? {
        guard let u = WebAddress.url(from: text) else { return nil }
        webView.load(URLRequest(url: u))
        return u.absoluteString
    }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    /// A link that wants a window of its own opens here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
}

/// The page in a view; one page is in one host at a time.
struct WebTabHost: UIViewRepresentable {
    let page: WebTabPage
    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// The pages of the pane's web tabs, matched to the stored tabs by address.
@MainActor
final class WebTabPages {
    private(set) var pages: [WebTabPage] = []

    /// One page per web tab, in the tabs' order; an address already open keeps
    /// its page, a new one makes a page, one no tab asks for any more goes.
    /// Returns the page of each tab index.
    func reconcile(_ tabs: [PaneTab]) -> [Int: WebTabPage] {
        var free = pages
        var out: [Int: WebTabPage] = [:]
        var kept: [WebTabPage] = []
        for (i, t) in tabs.enumerated() where t.kind == PaneTab.web {
            let url = t.url ?? ""
            let page: WebTabPage
            if let j = free.firstIndex(where: { $0.startURL == url }) {
                page = free.remove(at: j)
            } else {
                page = WebTabPage(url: url)
            }
            out[i] = page
            kept.append(page)
        }
        pages = kept
        return out
    }
}
