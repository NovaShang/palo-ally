import CryptoKit
import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI
import UIKit

/// One file on the computer, read-only: Markdown rendered, code and text
/// highlighted, pictures, PDFs and the rest in Quick Look (the renderer
/// ported from Bento Term), with the system share sheet. Over 5 MB the host
/// sends only the size: said so, nothing fetched.
struct FilePage: View {
    let target: FileTarget
    /// Shown modally (a path tapped in a reply): a close button.
    var close: (() -> Void)? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.placesAsColumns) private var asColumn
    @State private var phase = Phase.loading
    @State private var raw = false

    enum Phase: Equatable {
        case loading
        case progress(Double)
        case text(String, FileContentKind, URL)
        case quickLook(URL)
        case tooLarge(Int64)
        case failed(String)
    }

    private var fileURL: URL? {
        switch phase {
        case .text(_, _, let url), .quickLook(let url): url
        default: nil
        }
    }

    private var isMarkdown: Bool {
        if case .text(_, .markdown, _) = phase { return true }
        return false
    }

    var body: some View {
        content
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .macPageTop(target.name, subtitle: subtitle, back: close == nil ? { dismiss() } : nil, trailing: AnyView(macTrailing))
            .task(id: target) { await load() }
            .accessibilityIdentifier("file-page")
    }

    /// The folder it's in, quietly under the name (the Mac's strip).
    private var subtitle: String {
        let dir = (target.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .progress(let p):
            ProgressView(value: p).frame(maxWidth: 240).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let kind, _):
            FileTextPreview(fileName: kind == .markdown ? FilePreviewRoute.markdownRenderName(target.name) : target.name,
                            text: text, raw: raw, imageSource: kind == .markdown ? images : nil)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("file-preview-text")
        case .quickLook(let url):
            QuickLookView(url: url, revision: 0)
                .ignoresSafeArea(edges: .bottom)
        case .tooLarge(let size):
            ContentUnavailableView {
                Label { Text("文件太大", tableName: "Files") } icon: { Image(systemName: "doc") }
            } description: {
                Text("这个文件有 \(Copy.byteSize(size))，超过 5 MB 的文件不在这里打开。可以在电脑上看。", tableName: "Files")
            }
        case .failed(let why):
            ContentUnavailableView {
                Label { Text("打不开", tableName: "Files") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: why)
            } actions: {
                Button { Task { await load() } } label: { Text("再试一次", tableName: "Files") }
                    .buttonStyle(.glass)
                    .tint(.primary)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let close {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .close, action: close)
                    .tint(.primary)
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
            }
        }
        if isMarkdown {
            ToolbarItem(placement: .topBarTrailing) { MarkdownSourceToggle(raw: $raw) }
        }
        if let fileURL {
            ToolbarItem(placement: .topBarTrailing) {
                // The file itself, under its own name.
                ShareLink(item: fileURL).tint(.primary)
            }
        }
    }

    private var macTrailing: some View {
        HStack(spacing: 8) {
            if isMarkdown || fileURL != nil {
                MacStripMenu(label: String(localized: "更多", table: "Files")) {
                    if let fileURL {
                        ShareLink(item: fileURL) { Label { Text("共享", tableName: "Files") } icon: { Image(systemName: "square.and.arrow.up") } }
                    }
                    if isMarkdown {
                        Button { raw.toggle() } label: {
                            Label {
                                Text(raw ? String(localized: "看排版", table: "Files") : String(localized: "看源文本", table: "Files"))
                            } icon: {
                                Image(systemName: raw ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                            }
                        }
                    }
                }
            }
            if let close {
                MacStripButton(action: close) { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
            }
        }
    }

    /// A Markdown file's relative pictures, from the same folder on the computer.
    private var images: FilePreviewWebView.ImageSource {
        let store = store
        let scope = target.scope
        return .init(directory: (target.path as NSString).deletingLastPathComponent) { path in
            guard let r = try? await store.readFile(scope, path: path), !r.tooLarge,
                  r.data.count <= FilePreviewWebView.imageMaxBytes else { return nil }
            return r.data
        }
    }

    private func load() async {
        if case .text = phase {} else { phase = .loading }
        do {
            let r = try await store.readFile(target.scope, path: target.path) { got, total in
                if total > ArtifactChunk.maxChunk { phase = .progress(Double(got) / Double(max(total, 1))) }
            }
            if r.tooLarge {
                phase = .tooLarge(r.size)
                return
            }
            let url = try Self.save(r.data, for: target)
            var kind = FileContentKind.forName(target.name)
            if kind == .text { kind = FileContentKind.sniff(r.data) }
            phase = kind == .quickLook ? .quickLook(url) : .text(String(decoding: r.data, as: UTF8.self), kind, url)
        } catch {
            phase = .failed(Copy.error(error))
        }
    }

    /// A local copy under the file's own name (Quick Look and sharing take a
    /// URL), in a folder per file, written fresh each time it's opened.
    static func save(_ data: Data, for target: FileTarget) throws -> URL {
        let key = SHA256.hash(data: Data(target.id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-files", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = target.name.isEmpty || target.name == "." || target.name == ".." ? "file" : target.name
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// A path tapped in a reply: the file over the conversation, closed with
/// 关闭 (Esc / ⌘W on the Mac), like a file sent in the conversation.
@MainActor
enum FilePagePresenter {
    static func present(_ target: FileTarget, store: AppStore) {
        guard let top = QuickLookPresenter.topController() else { return }
        weak var presented: UIViewController?
        let page = NavigationStack {
            FilePage(target: target, close: { presented?.dismiss(animated: true) })
        }
        .environment(store)
        let controller = FileSheetController(rootView: AnyView(page))
        #if targetEnvironment(macCatalyst)
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 960, height: 720)
        #else
        controller.modalPresentationStyle = .pageSheet
        #endif
        presented = controller
        top.present(controller, animated: true)
    }
}

private final class FileSheetController: UIHostingController<AnyView> {
    #if targetEnvironment(macCatalyst)
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputEscape, "w", "["].map { input in
            let k = UIKeyCommand(input: input, modifierFlags: input == UIKeyCommand.inputEscape ? [] : .command,
                                 action: #selector(closeCommand))
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
    }

    @objc private func closeCommand() { dismiss(animated: true) }
    #endif
}
