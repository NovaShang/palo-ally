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
                } else if let error {
                    ContentUnavailableView("打不开", systemImage: "exclamationmark.triangle", description: Text(error))
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
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { try? await store.setPinned(artifact, !artifact.pinned) }
                    } label: {
                        Image(systemName: artifact.pinned ? "pin.fill" : "pin")
                    }
                    .accessibilityLabel(artifact.pinned ? "取消置顶" : "置顶")
                }
                if let content {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: content.fileURL)
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

    @ViewBuilder
    private func preview(_ a: Artifact, _ c: Loaded) -> some View {
        let ext = (c.path as NSString).pathExtension.lowercased()
        if ["md", "markdown", "txt"].contains(ext) || (c.path == a.mainFile && a.previewStyle == .markdown) {
            ScrollView {
                MarkdownText(source: String(decoding: c.data, as: UTF8.self))
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        } else if ["html", "htm"].contains(ext) || (c.path == a.mainFile && a.previewStyle == .html) {
            SandboxedHTMLView(html: String(decoding: c.data, as: UTF8.self))
                .ignoresSafeArea(edges: .bottom)
        } else {
            QuickLookView(url: c.fileURL, revision: c.revision)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func load() async {
        guard let a = artifact else { return }
        let path = currentPath(a)
        error = nil
        do {
            let r = try await store.readArtifact(id: a.id, path: path)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent(a.id, isDirectory: true)
            let url = dir.appendingPathComponent((path as NSString).lastPathComponent.isEmpty ? "file" : (path as NSString).lastPathComponent)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try r.data.write(to: url, options: .atomic)
            content = Loaded(path: path, data: r.data, fileURL: url, revision: a.updatedAt)
        } catch {
            if content == nil { self.error = error.localizedDescription }
        }
    }
}

// MARK: - HTML (sandboxed, offline)

/// WKWebView with all network loads blocked by a content rule list and a
/// non-persistent data store. Links don't navigate.
struct SandboxedHTMLView: UIViewRepresentable {
    let html: String

    static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^(about|data|blob):"},"action":{"type":"ignore-previous-rules"}}]
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        context.coordinator.webView = view
        context.coordinator.load(html)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded: String?
        private var ruleList: WKContentRuleList?

        func load(_ html: String) {
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
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the initial document load (about:blank) and in-page anchors.
            if action.navigationType == .other || action.request.url?.scheme == "about" { return .allow }
            return .cancel
        }
    }
}

// MARK: - QuickLook (everything else)

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    let revision: Int64

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        context.coordinator.url = url
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url || context.coordinator.revision != revision {
            context.coordinator.url = url
            context.coordinator.revision = revision
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL?
        var revision: Int64 = 0

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
        }
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { ArtifactDetailView(artifactID: "ar1") }
        .environment(model)
        .environment(model.store!)
}
