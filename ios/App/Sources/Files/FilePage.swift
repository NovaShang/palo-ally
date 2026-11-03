import CryptoKit
import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI
import UIKit

/// One file on the computer, read-only: Markdown rendered, code and text
/// highlighted, pictures, PDFs and the rest in Quick Look (the renderer
/// ported from Bento Term), with the system share sheet. Over 5 MB the host
/// sends only the size: said so, nothing fetched.
///
/// It follows the file on the computer like an editor's preview: while on
/// screen (and the app not in the background) the host watches it
/// (`AppStore.followFile`; an older host is polled) and a change is read
/// again in place, keeping the scroll position. ⌘R, or 重新载入 in its ⋯,
/// reads it again by hand.
struct FilePage: View {
    let target: FileTarget
    /// Shown modally (a path tapped in a reply): a close button.
    var close: (() -> Void)? = nil
    /// A tab of the right pane: its chip already names the file, so no bar
    /// or strip; its actions are a floating ⋯ at the top right.
    var inPane = false
    /// A tab's absolute path read through `.root`: where to read it when the
    /// computer's PaloAlly is older and has no `.root` (the pane's own files,
    /// which take an absolute path inside them).
    var fallbackScope: FileScope? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.placesAsColumns) private var asColumn
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = Phase.loading
    /// Bumped on each re-read, so Quick Look shows the new copy.
    @State private var revision: Int64 = 0
    /// Re-reads in flight: only the newest one lands.
    @State private var readGeneration = 0
    /// The follow task has run before (back from the background: read it again first).
    @State private var followedBefore = false
    @State private var raw = false
    /// The scope the file was read from, when it was the fallback.
    @State private var readScope: FileScope?
    /// 重新载入 asked by the owner: the page is drawn again (its pictures
    /// too), and says so for a moment.
    @State private var redraws = 0
    @State private var reloadedNote = false

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

    /// Something is shown (not loading, not failed): worth following.
    private var isLoaded: Bool {
        switch phase {
        case .text, .quickLook, .tooLarge: true
        default: false
        }
    }

    /// What the follow task depends on: the file, where it was read from,
    /// and whether there is something to follow and the app is in front.
    private struct Follow: Hashable {
        let target: FileTarget
        let scope: FileScope
        let on: Bool
    }

    private var follow: Follow {
        Follow(target: target, scope: readScope ?? target.scope, on: isLoaded && scenePhase != .background)
    }

    private var isMarkdown: Bool {
        if case .text(_, .markdown, _) = phase { return true }
        return false
    }

    @ViewBuilder var body: some View {
        if inPane {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { paneMenu.padding(10) }
                .overlay(alignment: .bottom) { reloadedCapsule }
                .background { reloadKey }
                .task(id: target) { await load() }
                .task(id: follow) { await followFile(follow) }
                .accessibilityIdentifier("file-page")
        } else {
            page
        }
    }

    private var page: some View {
        content
            .overlay(alignment: .bottom) { reloadedCapsule }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .macPageTop(target.name, subtitle: subtitle, back: close == nil ? { dismiss() } : nil, trailing: AnyView(macTrailing))
            .background { reloadKey }
            .task(id: target) { await load() }
            .task(id: follow) { await followFile(follow) }
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
                .id(redraws)
                .ignoresSafeArea(edges: .bottom)
        case .quickLook(let url):
            EmbeddedPreview(url: url, revision: revision)
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
            if phase != .loading {
                MacStripMenu(label: String(localized: "更多", table: "Files")) {
                    reloadButton
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

    /// The pane's ⋯: what a page's bar would hold.
    private var paneMenu: some View {
        MacStripMenu(label: String(localized: "更多", table: "Files")) {
            reloadButton
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
            Button { UIPasteboard.general.string = target.path } label: {
                Label { Text("拷贝路径", tableName: "Files") } icon: { Image(systemName: "doc.on.doc") }
            }
            if let close {
                Divider()
                Button(action: close) {
                    Label { Text("关闭标签", tableName: "Files") } icon: { Image(systemName: "xmark") }
                }
            }
        }
    }

    @ViewBuilder private var reloadedCapsule: some View {
        if reloadedNote {
            Text("已重新载入", tableName: "Files")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }

    /// 重新载入 in a ⋯ (⌘R does the same): read and draw again whatever came
    /// back, even the same (it looked as if nothing happened, 11-03).
    private func reloadByHand() async {
        await load(quietly: isLoaded, force: true)
        redraws += 1
        withAnimation { reloadedNote = true }
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { reloadedNote = false }
    }

    /// 重新载入 in a ⋯ (⌘R does the same).
    private var reloadButton: some View {
        Button { Task { await reloadByHand() } } label: {
            Label { Text("重新载入", tableName: "Files") } icon: { Image(systemName: "arrow.clockwise") }
        }
    }

    /// ⌘R (Mac, iPad keyboard): read the file again.
    private var reloadKey: some View {
        Button("") { Task { await reloadByHand() } }
            .keyboardShortcut("r", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// A Markdown file's relative pictures, from the same folder on the computer.
    private var images: FilePreviewWebView.ImageSource {
        let store = store
        let scope = readScope ?? target.scope
        // A document kept by its absolute path: its pictures' paths come back
        // without the leading "/", put it back.
        let absolute = target.path.hasPrefix("/")
        return .init(directory: (target.path as NSString).deletingLastPathComponent) { path in
            let path = absolute && !path.hasPrefix("/") ? "/" + path : path
            guard let r = try? await store.readFile(scope, path: path), !r.tooLarge,
                  r.data.count <= FilePreviewWebView.imageMaxBytes else { return nil }
            return r.data
        }
    }

    /// Read it again in place: what is shown stays until the new content is
    /// in (same content: nothing changes), and a failed re-read keeps it.
    /// Shown nothing yet, or failed: a plain load.
    private func reload() async {
        guard isLoaded else { return await load() }
        await load(quietly: true)
    }

    /// While `follow.on`: re-read the file each time it changes on disk.
    private func followFile(_ follow: Follow) async {
        guard follow.on else { return }
        // Back in front (or shown again): it may have changed meanwhile.
        if followedBefore { await reload() }
        followedBefore = true
        await store.followFile(follow.scope, path: follow.target.path) {
            debugLog("file page: re-reading \(follow.target.name), changed on disk")
            await reload()
        }
    }

    private func load(quietly: Bool = false, force: Bool = false) async {
        readGeneration += 1
        let generation = readGeneration
        if !quietly { if case .text = phase {} else { phase = .loading } }
        do {
            let progress: (Int64, Int64) -> Void = { got, total in
                if !quietly, total > ArtifactChunk.maxChunk { phase = .progress(Double(got) / Double(max(total, 1))) }
            }
            let r: (data: Data, mime: String, size: Int64, tooLarge: Bool)
            do {
                r = try await store.readFile(target.scope, path: target.path, progress: progress)
                readScope = nil
            } catch {
                guard let fallbackScope else { throw error }
                r = try await store.readFile(fallbackScope, path: target.path, progress: progress)
                readScope = fallbackScope
            }
            guard generation == readGeneration else { return }
            if r.tooLarge {
                phase = .tooLarge(r.size)
                return
            }
            var kind = FileContentKind.forName(target.name)
            if kind == .text { kind = FileContentKind.sniff(r.data) }
            let text = kind == .quickLook ? nil : String(decoding: r.data, as: UTF8.self)
            // Re-read and the same: leave it be (no re-render, no flash).
            if quietly, !force, let text, case .text(let shown, let shownKind, _) = phase, shown == text, shownKind == kind { return }
            if quietly, !force, text == nil, case .quickLook(let shown) = phase, (try? Data(contentsOf: shown)) == r.data { return }
            let url = try Self.save(r.data, for: target)
            if let text {
                phase = .text(text, kind, url)
            } else {
                if quietly, case .quickLook = phase { revision += 1 }
                phase = .quickLook(url)
            }
            if quietly { debugLog("file page: \(target.name) re-read (\(r.data.count) bytes)") }
        } catch {
            guard generation == readGeneration else { return }
            if quietly {
                debugLog("file page: re-reading \(target.name) failed: \(error)")
            } else {
                phase = .failed(Copy.error(error))
            }
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
        // A pane's preview tab when the page has one.
        if PaneOpeners.file?(target) == true { return }
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
