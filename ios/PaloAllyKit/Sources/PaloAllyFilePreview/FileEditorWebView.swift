#if canImport(UIKit)
import SwiftUI
import UIKit
import WebKit

/// A text file being edited: CodeMirror 6 (bundled, built from
/// `editor-src`) in a WKWebView, editing and syntax colours and search only.
/// One per file being edited, kept by its owner while the edit lives, so a
/// tab hidden and shown again keeps its text, cursor and undo.
///
/// As the preview: a local page loaded once, content in as JSON through
/// `evaluateJavaScript`, no navigation and no network. The page says back
/// on `paEditor`: whether the text differs from the saved copy, ⌘S and ⌘E.
@MainActor
public final class FileEditorWebView: WKWebView, WKNavigationDelegate {
    /// The text now differs from what the computer has (or no longer does).
    public var onDirty: ((Bool) -> Void)?
    /// ⌘S in the editor.
    public var onSave: (() -> Void)?
    /// ⌘E in the editor (back to the preview).
    public var onToggle: (() -> Void)?

    /// An input method's composition is open in the page (pinyin typed, not
    /// yet a character): the text is about to change though it isn't said
    /// to be unsaved until the composition ends.
    public private(set) var composing = false

    /// Where a failed call, and what the page notes, is told (the app's debug log).
    public static var log: ((String) -> Void)?

    private var ready = false
    /// Calls made before the page was up, run in order once it is.
    private var queued: [String] = []
    private var dark: Bool?

    public static func make() -> FileEditorWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let bridge = FileEditorBridge()
        cfg.userContentController.add(bridge, name: "paEditor")
        let v = FileEditorWebView(frame: .zero, configuration: cfg)
        bridge.owner = v
        v.navigationDelegate = v
        // The page paints its own background; until it loads, what's behind.
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        // CodeMirror scrolls inside the page; the web view itself stays put.
        v.scrollView.isScrollEnabled = false
        v.scrollView.bounces = false
        if let html = templateURL {
            v.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return v
    }

    public nonisolated static var templateURL: URL? {
        Bundle.module.url(forResource: "editor", withExtension: "html", subdirectory: "FileEditor")
    }

    /// A file, fresh: `text` is what the computer has; its language from `fileName`.
    public func load(fileName: String, text: String, dark: Bool, focus: Bool) {
        struct Payload: Encodable { let name: String; let text: String; let dark: Bool; let zh: Bool; let focus: Bool }
        self.dark = dark
        composing = false
        let zh = (Locale.preferredLanguages.first ?? "zh").hasPrefix("zh")
        call("paEditorLoad", Payload(name: fileName, text: text, dark: dark, zh: zh, focus: focus))
    }

    /// The computer's copy changed and nothing here is unsaved: in place,
    /// only where it differs (the cursor and the scroll stay).
    public func replace(with text: String) {
        call("paEditorReplace", text)
    }

    /// The text to save, and the mark that says it was saved (`saved(_:)`).
    /// Nil before the page is up.
    public func snapshot() async -> (id: Int, text: String)? {
        guard ready else { return nil }
        return await withCheckedContinuation { done in
            evaluateJavaScript("paEditorSnapshot()") { result, _ in
                guard let d = result as? [String: Any], let id = (d["id"] as? NSNumber)?.intValue,
                      let text = d["text"] as? String else { return done.resume(returning: nil) }
                done.resume(returning: (id, text))
            }
        }
    }

    /// The snapshot `id` is on the computer now (what was typed since stays unsaved).
    public func saved(_ id: Int) {
        call("paEditorSaved", id)
    }

    public func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        call("paEditorTheme", dark)
    }

    /// The keyboard to the text.
    public func focusText() {
        _ = becomeFirstResponder()
        call("paEditorFocus", true)
    }

    private func call<T: Encodable>(_ fn: String, _ arg: T) {
        guard let data = try? JSONEncoder().encode([arg]), let json = String(data: data, encoding: .utf8) else { return }
        // `[arg]` encoded, its brackets off: one JSON value, safe as a literal.
        let js = "\(fn)(\(json.dropFirst().dropLast()))"
        if ready { run(js) } else { queued.append(js) }
    }

    private func run(_ js: String) {
        evaluateJavaScript(js) { _, error in
            if let error { Self.log?("file editor: \(js.prefix(30)) failed: \(error)") }
        }
    }

    fileprivate func message(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "dirty": onDirty?(body["dirty"] as? Bool ?? false)
        case "copy":
            // A cut took the keyboard from the text with it: given back.
            if body["cut"] as? Bool == true { DispatchQueue.main.async { [weak self] in self?.focusText() } }
            putOnClipboard(body["text"] as? String ?? "")
        case "paste": pasteFromClipboard()
        case "save": onSave?()
        case "toggle": onToggle?()
        case "composing": composing = body["composing"] as? Bool ?? false
        case "log": Self.log?("file editor: \(body["text"] as? String ?? "")")
        default: break
        }
    }

    // ⌘S, ⌘E and ⌘F while typing here: the editor's, ahead of the app's
    // menu (its ⌘F searches 成果 and the conversation).
    public override var keyCommands: [UIKeyCommand]? {
        let keys: [(String, Selector)] = [("s", #selector(saveCommand)), ("e", #selector(toggleCommand)), ("f", #selector(findCommand))]
        return (super.keyCommands ?? []) + keys.map { input, action in
            let k = UIKeyCommand(input: input, modifierFlags: .command, action: action)
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
    }

    /// A space at the cursor (the Mac app types it: the system took the
    /// key before the page had it, 11-06).
    public func typeSpace() { if ready { evaluateJavaScript("paEditorInsert(' ')") } }

    /// The editor whose text has the keyboard, if any.
    public static var focused: FileEditorWebView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter(\.isKeyWindow)
        for window in windows {
            guard let first = firstResponder(in: window) else { continue }
            var v: UIView? = first
            while let view = v {
                if let editor = view as? FileEditorWebView { return editor }
                v = view.superview
            }
        }
        return nil
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews { if let f = firstResponder(in: sub) { return f } }
        return nil
    }

    @objc private func saveCommand() { onSave?() }

    /// ⌘C, ⌘X and ⌘V typed here (the Mac app catches them before WebKit,
    /// whose own never reached the system's clipboard or the page, 11-12):
    /// "c", "x" or "v".
    public func editKey(_ key: String) {
        guard ready else { return }
        if key == "v" { return pasteFromClipboard() }
        evaluateJavaScript("paEditorClip(\(key == "x"))") { [weak self] result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            self?.putOnClipboard(text)
        }
    }

    private func putOnClipboard(_ text: String) {
        #if DEBUG
        // `-copyDryRun YES` (tests): said in the log, the clipboard left as it is.
        if UserDefaults.standard.bool(forKey: "copyDryRun") {
            Self.log?("file editor: copy (dry run) \(text.count) characters")
            return
        }
        #endif
        UIPasteboard.general.string = text
    }

    /// The clipboard's text at the cursor (⌘V, or the page's own paste that had no text).
    private func pasteFromClipboard() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "copyDryRun") {
            Self.log?("file editor: paste (dry run)")
            call("paEditorPaste", "[pasted]")
            return
        }
        #endif
        if let text = UIPasteboard.general.string { call("paEditorPaste", text) }
    }
    @objc private func toggleCommand() { onToggle?() }
    @objc private func findCommand() { if ready { evaluateJavaScript("paEditorFind()") } }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !ready else { return }
        ready = true
        let calls = queued
        queued = []
        for js in calls { run(js) }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The page itself, once; nothing else, ever.
        decisionHandler(!ready && navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// The page's messages to the view (a separate object: the content
/// controller retains its handlers).
private final class FileEditorBridge: NSObject, WKScriptMessageHandler {
    weak var owner: FileEditorWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { owner?.message(body) }
    }
}

/// The editor in a SwiftUI page: the same web view each time it is shown.
public struct FileEditorView: UIViewRepresentable {
    let editor: FileEditorWebView
    @Environment(\.colorScheme) private var colorScheme

    public init(editor: FileEditorWebView) { self.editor = editor }

    public func makeUIView(context: Context) -> FileEditorWebView {
        // Shown again after its tab was away: out of where it was first.
        editor.removeFromSuperview()
        return editor
    }

    public func updateUIView(_ view: FileEditorWebView, context: Context) {
        view.setDark(colorScheme == .dark)
    }
}
#endif
