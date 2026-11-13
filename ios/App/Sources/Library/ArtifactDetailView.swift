import PaloAllyFilePreview
import PaloAllyKit
import QuickLook
import SwiftUI
import WebKit

struct ArtifactDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let artifactID: String
    /// A tab of the right pane: its chip already names the item, so no bar
    /// or strip; its actions are a floating ⋯ at the top right.
    var inPane = false
    /// Closes that tab.
    var close: (() -> Void)? = nil
    @State private var selectedPath: String?
    /// The file on screen, on the device (in the downloaded files' cache).
    @State private var content: Loaded?
    /// Markdown shown as its source text instead of rendered.
    @State private var showSource = false
    /// The download-then-share sheet, for 分享/导出 before the file is here.
    @State private var shareTarget: FileShareTarget?

    struct Loaded: Equatable {
        let path: String
        let fileURL: URL
    }

    private var artifact: Artifact? { store.artifact(id: artifactID) }

    @ViewBuilder var body: some View {
        if inPane {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .documentCardContent()
                .overlay(alignment: .topTrailing) { if let artifact { paneMenu(artifact).documentMenuPlacement() } }
                .fileShareSheet(item: $shareTarget)
                .accessibilityIdentifier("artifact-tab")
        } else {
            page
        }
    }

    /// Any size opens here: downloaded to the device with progress (the
    /// same downloader as the file page and the conversation's files), kept
    /// by the item's version, so a second open, or a live item that didn't
    /// change, needs nothing from the computer; a new version comes while the
    /// old one stays on screen.
    private var main: some View {
        Group {
            if let artifact {
                let path = currentPath(artifact)
                let info = store.artifactFileInfo(id: artifact.id, path: path)
                RemoteFileView(source: .artifact(id: artifact.id, path: path), name: fileName(path),
                               size: info.flatMap { $0.size > 0 ? $0.size : nil }, version: info?.version) { url in
                    preview(artifact, path: path, url: url)
                        .onAppear { content = Loaded(path: path, fileURL: url) }
                        .onChange(of: url) { content = Loaded(path: path, fileURL: url) }
                }
                .id(path)
            } else {
                ContentUnavailableView("找不到了", systemImage: "questionmark.folder")
            }
        }
    }

    private func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent.isEmpty ? "file" : (path as NSString).lastPathComponent
    }

    /// The current file's size.
    private func currentSize(_ a: Artifact) -> Int64 {
        a.files.first { $0.path == currentPath(a) }?.size ?? 0
    }

    /// The download-then-share target for the current file.
    private func makeShareTarget(_ a: Artifact) -> FileShareTarget {
        let path = currentPath(a)
        return FileShareTarget(name: fileName(path), size: currentSize(a), source: .remote(.artifact(id: a.id, path: path)))
    }

    /// What is on screen is the current file (not the one before a switch).
    private func shownURL(_ a: Artifact) -> URL? {
        content.flatMap { $0.path == currentPath(a) ? $0.fileURL : nil }
    }

    private var page: some View {
        main
        .navigationTitle(artifact?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let artifact {
                if artifact.files.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("文件", selection: Binding(get: { currentPath(artifact) }, set: { selectedPath = $0 })) {
                                ForEach(artifact.files, id: \.path) { f in
                                    Text("\(f.path)  \(Copy.byteSize(f.size))").tag(f.path)
                                }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .tint(.primary)
                        .accessibilityLabel("换一个文件看")
                    }
                }
                // The less frequent actions share one menu, so the title keeps
                // its room (an iPad panel was down to 「每日…」); share and close
                // stay on the bar.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { try? await store.setPinned(artifact, !artifact.pinned) }
                        } label: {
                            Label(artifact.pinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: artifact.pinned ? "pin.slash" : "pin")
                        }
                        if hasSource(artifact) {
                            Button {
                                showSource.toggle()
                            } label: {
                                Label(showSource ? String(localized: "查看排版") : String(localized: "查看源码"),
                                      systemImage: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(.primary)
                    .accessibilityLabel("更多")
                }
                if let url = shownURL(artifact) {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url)
                            .tint(.primary)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { shareTarget = makeShareTarget(artifact) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(.primary)
                        .accessibilityLabel(Text("分享 / 导出"))
                    }
                }
            }
        }
        // The Mac (in 成果 beside the conversation): to the column's top, back,
        // its title and one menu floating (MacPageStrip).
        .macPageTop(artifact?.title ?? "", back: { dismiss() }, trailing: artifact.map { AnyView(macMenu($0)) })
        .fileShareSheet(item: $shareTarget)
    }

    /// The tab's ⋯: the strip's menu, and closing the tab.
    private func paneMenu(_ artifact: Artifact) -> some View {
        MacStripMenu(label: String(localized: "更多")) {
            menuItems(artifact)
            DocumentMenuItems()
            if let close {
                Divider()
                Button(action: close) {
                    Label { Text("关闭标签", tableName: "Files") } icon: { Image(systemName: "xmark") }
                }
            }
        }
    }

    /// The Mac's strip: the bar's actions in one menu.
    private func macMenu(_ artifact: Artifact) -> some View {
        MacStripMenu(label: String(localized: "更多")) { menuItems(artifact) }
    }

    @ViewBuilder private func menuItems(_ artifact: Artifact) -> some View {
        if let url = shownURL(artifact) {
            ShareLink(item: url) { Label("共享", systemImage: "square.and.arrow.up") }
        } else {
            Button { shareTarget = makeShareTarget(artifact) } label: {
                Label("共享", systemImage: "square.and.arrow.up")
            }
        }
        Button {
            Task { try? await store.setPinned(artifact, !artifact.pinned) }
        } label: {
            Label(artifact.pinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: artifact.pinned ? "pin.slash" : "pin")
        }
        if hasSource(artifact) {
            Button {
                showSource.toggle()
            } label: {
                Label(showSource ? String(localized: "查看排版") : String(localized: "查看源码"),
                      systemImage: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
            }
        }
        if artifact.files.count > 1 {
            Picker("文件", selection: Binding(get: { currentPath(artifact) }, set: { selectedPath = $0 })) {
                ForEach(artifact.files, id: \.path) { f in
                    Text("\(f.path)  \(Copy.byteSize(f.size))").tag(f.path)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func currentPath(_ a: Artifact) -> String {
        selectedPath ?? (a.mainFile.isEmpty ? (a.files.first?.path ?? "") : a.mainFile)
    }

    /// How the file opens: the one classifier the file page uses too, the
    /// item's declared type a hint for its main file.
    private func kind(_ a: Artifact, _ path: String) -> PreviewKind {
        let hint: PreviewKind.Hint? = path == a.mainFile ? (a.previewStyle == .markdown ? .markdown : a.previewStyle == .html ? .html : nil) : nil
        return PreviewKind.classify(name: path, hint: hint)
    }

    /// Markdown and web pages can be read as their source.
    private func hasSource(_ a: Artifact) -> Bool {
        let k = kind(a, currentPath(a))
        return k == .markdown || k == .html
    }

    private func preview(_ a: Artifact, path: String, url: URL) -> some View {
        LocalFilePreview(url: url, kind: kind(a, path), name: path, revision: a.updatedAt, raw: showSource,
                         imageSource: store.markdownImages(artifactID: a.id, documentPath: path), sandbox: a.id)
    }
}

// MARK: - HTML (sandboxed, offline)

/// WKWebView with all network loads blocked by a content rule list. Links
/// don't navigate. Each library item is its own origin (a host under the
/// reserved .invalid domain, so nothing could ever be fetched from it) in a
/// persistent store of its own, so a page's localStorage (a checklist's
/// ticks) survives closing it, and pages can't read each other's.
struct SandboxedHTMLView: UIViewRepresentable {
    let html: String
    let artifactID: String
    /// The pictures published beside the page, read from the item itself
    /// (relative paths inside it only). Without one they show as stubs.
    var images: FilePreviewWebView.ImageSource?
    /// A page too big to hold as a string (over 5 MB): loaded from its file
    /// instead (its folder readable, still nothing from the network; its
    /// pictures inside it, its storage not kept per item).
    var fileURL: URL? = nil

    init(html: String, artifactID: String, images: FilePreviewWebView.ImageSource? = nil, fileURL: URL? = nil) {
        self.html = html
        self.artifactID = artifactID
        self.images = images
        self.fileURL = fileURL
    }

    /// Content rule lists don't support regex disjunctions: one rule per
    /// scheme, or the whole list fails to compile (and the page never loads).
    static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^https://[^/]*\\\\.artifact\\\\.paloally\\\\.invalid/"},"action":{"type":"ignore-previous-rules"}}]
    """

    /// The same, letting the page's own file (and its folder) load.
    static let fileRules = rules.replacingOccurrences(of: #"{"trigger":{"url-filter":"^about:"}"#,
                                                      with: #"{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^about:"}"#)

    /// Library pages only; never shared with anything else that browses.
    @MainActor static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1C2E1A-6A3B-4C55-9C7E-2D0B5B0A7A11")!)

    /// https://<id>.artifact.paloally.invalid/: the item's own origin.
    static func origin(for artifactID: String) -> URL? {
        let host = String(artifactID.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return URL(string: "https://\(host.isEmpty ? "page" : host).artifact.paloally.invalid/")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        context.coordinator.imageBridge.install(in: config)
        config.websiteDataStore = Self.dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        context.coordinator.webView = view
        context.coordinator.imageBridge.attach(view)
        context.coordinator.load(html, baseURL: Self.origin(for: artifactID), images: images, fileURL: fileURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, baseURL: Self.origin(for: artifactID), images: images, fileURL: fileURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded: String?
        private var ruleList: WKContentRuleList?
        let imageBridge = HTMLImageBridge()

        func load(_ html: String, baseURL: URL?, images: FilePreviewWebView.ImageSource?, fileURL: URL? = nil) {
            let marker = fileURL.map { "file:" + $0.path } ?? html
            guard marker != loaded, let webView else { return }
            loaded = marker
            imageBridge.reset(source: images)
            Task {
                // Never render without the network block in place.
                if let fileURL {
                    guard let list = try? await WKContentRuleListStore.default()
                        .compileContentRuleList(forIdentifier: "paloally.offline.file", encodedContentRuleList: SandboxedHTMLView.fileRules)
                    else { return }
                    webView.configuration.userContentController.removeAllContentRuleLists()
                    webView.configuration.userContentController.add(list)
                    webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
                    return
                }
                if ruleList == nil {
                    ruleList = try? await WKContentRuleListStore.default()
                        .compileContentRuleList(forIdentifier: "paloally.offline", encodedContentRuleList: SandboxedHTMLView.rules)
                }
                guard let ruleList else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(ruleList)
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the initial document load and in-page anchors.
            if action.navigationType == .other || action.request.url?.scheme == "about" { return .allow }
            // A page loaded from its file: that file only.
            if action.request.url?.isFileURL == true, action.navigationType != .linkActivated { return .allow }
            return .cancel
        }
    }
}

#Preview {
    let model = WindowModel.demo()
    NavigationStack { ArtifactDetailView(artifactID: "ar1") }
        .environment(model)
        .environment(model.store!)
}
