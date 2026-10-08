import PaloAllyFilePreview
import PaloAllyKit
import QuickLook
import SwiftUI
import WebKit

struct ArtifactDetailView: View {
    @Environment(AppStore.self) private var store
    let artifactID: String
    @State private var selectedPath: String?
    @State private var content: Loaded?
    @State private var error: String?
    /// A refresh of the file already on screen failed (shown as a small note).
    @State private var refreshError: String?
    /// Download progress (0…1) for files bigger than one chunk.
    @State private var progress: Double?
    /// Markdown shown as its source text instead of rendered.
    @State private var showSource = false

    struct Loaded: Equatable {
        let path: String
        let data: Data
        let fileURL: URL
        let revision: Int64
    }

    private var artifact: Artifact? { store.artifact(id: artifactID) }

    var body: some View {
        Group {
            if let artifact {
                if let content {
                    preview(artifact, content)
                        .overlay(alignment: .bottom) {
                            if let refreshError {
                                Text(refreshError)
                                    .font(.footnote)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .glassEffect(.regular, in: .capsule)
                                    .padding(.bottom, 12)
                            }
                        }
                } else if let error {
                    ContentUnavailableView {
                        Label("打不开", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("再试一次") { Task { await load() } }
                            .buttonStyle(.glass)
                            .tint(.primary)
                    }
                } else if let progress {
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                            .frame(maxWidth: 240)
                        Text("正在取… \(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    ProgressView("正在取…")
                }
            } else {
                ContentUnavailableView("找不到了", systemImage: "questionmark.folder")
            }
        }
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
                            Label(artifact.pinned ? "取消置顶" : "置顶", systemImage: artifact.pinned ? "pin.slash" : "pin")
                        }
                        if let content, isMarkdown(artifact, content.path) {
                            Button {
                                showSource.toggle()
                            } label: {
                                Label(showSource ? "查看排版" : "查看源码",
                                      systemImage: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(.primary)
                    .accessibilityLabel("更多")
                }
                if let content {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: content.fileURL)
                            .tint(.primary)
                    }
                }
            }
        }
        // Reload whenever the host rewrites the artifact ("live" artifacts).
        .task(id: "\(artifact?.updatedAt ?? 0)|\(selectedPath ?? "")") {
            await load()
        }
    }

    private func currentPath(_ a: Artifact) -> String {
        selectedPath ?? (a.mainFile.isEmpty ? (a.files.first?.path ?? "") : a.mainFile)
    }

    /// Markdown renders in the web view ported from Bento Term.
    private func isMarkdown(_ a: Artifact, _ path: String) -> Bool {
        FilePreviewRoute.forFile(name: path) == .markdown || (path == a.mainFile && a.previewStyle == .markdown)
    }

    @ViewBuilder
    private func preview(_ a: Artifact, _ c: Loaded) -> some View {
        let ext = (c.path as NSString).pathExtension.lowercased()
        if isMarkdown(a, c.path) {
            MarkdownPreview(fileName: c.path, text: String(decoding: c.data, as: UTF8.self), raw: showSource,
                            imageSource: store.markdownImages(artifactID: a.id, documentPath: c.path))
                .ignoresSafeArea(edges: .bottom)
        } else if ext == "txt" {
            ScrollView {
                MarkdownText(source: String(decoding: c.data, as: UTF8.self), compact: false)
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        } else if ["html", "htm"].contains(ext) || (c.path == a.mainFile && a.previewStyle == .html) {
            SandboxedHTMLView(html: String(decoding: c.data, as: UTF8.self), artifactID: a.id)
                .ignoresSafeArea(edges: .bottom)
        } else {
            QuickLookView(url: c.fileURL, revision: c.revision)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func load() async {
        guard let a = artifact else { return }
        let path = currentPath(a)
        let switching = content?.path != path
        error = nil
        refreshError = nil
        if switching {
            // Don't keep showing the previous file under the new name.
            content = nil
            progress = nil
        }
        let expected = a.files.first { $0.path == path }?.size ?? 0
        do {
            let r = try await store.readArtifact(id: a.id, path: path) { received, total in
                let size = max(total, expected)
                guard size > ArtifactChunk.maxChunk, content == nil || switching else { return }
                progress = min(1, Double(received) / Double(size))
            }
            // A fresh file name per load: QuickLook caches by URL, so reusing
            // one would keep showing the old revision of a live artifact.
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent(a.id, isDirectory: true)
            let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let name = (path as NSString).lastPathComponent.isEmpty ? "file" : (path as NSString).lastPathComponent
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try r.data.write(to: url, options: .atomic)
            let old = content?.fileURL.deletingLastPathComponent()
            content = Loaded(path: path, data: r.data, fileURL: url, revision: a.updatedAt)
            progress = nil
            if let old, old != dir, old.deletingLastPathComponent() == base { try? FileManager.default.removeItem(at: old) }
        } catch is CancellationError {
            return
        } catch {
            progress = nil
            let msg = Copy.error(error)
            if content == nil {
                self.error = msg
            } else {
                refreshError = "没刷新成功：\(msg)"
            }
        }
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

    /// Content rule lists don't support regex disjunctions: one rule per
    /// scheme, or the whole list fails to compile (and the page never loads).
    static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^https://[^/]*\\\\.artifact\\\\.paloally\\\\.invalid/"},"action":{"type":"ignore-previous-rules"}}]
    """

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
        config.websiteDataStore = Self.dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        context.coordinator.webView = view
        context.coordinator.load(html, baseURL: Self.origin(for: artifactID))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, baseURL: Self.origin(for: artifactID))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded: String?
        private var ruleList: WKContentRuleList?

        func load(_ html: String, baseURL: URL?) {
            guard html != loaded, let webView else { return }
            loaded = html
            Task {
                if ruleList == nil {
                    ruleList = try? await WKContentRuleListStore.default()
                        .compileContentRuleList(forIdentifier: "paloally.offline", encodedContentRuleList: SandboxedHTMLView.rules)
                }
                // Never render without the network block in place.
                guard let ruleList else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(ruleList)
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the initial document load and in-page anchors.
            if action.navigationType == .other || action.request.url?.scheme == "about" { return .allow }
            return .cancel
        }
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { ArtifactDetailView(artifactID: "ar1") }
        .environment(model)
        .environment(model.store!)
}
