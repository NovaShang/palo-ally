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
///
/// In a pane's tab on the Mac and iPad, a text file up to 1 MB can be
/// edited in place (编辑 in its ⋯, ⌘E): see `FileEditSession`.
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
    /// A pane's tab: its edit's key for a path (`FileEditSessions.key`);
    /// nil where files aren't edited (a page pushed or shown over the conversation).
    var editKey: ((String) -> String)? = nil
    /// Show another file in this tab (picked from its path while editing).
    var retarget: ((String) -> Void)? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.placesAsColumns) private var asColumn
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
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
    /// The version the text shown was read at (nil: a host that can't save).
    @State private var readVersion: String?
    /// The bytes are UTF-8 as they are (anything else would be changed by saving).
    @State private var plainUTF8 = false
    /// A file picked from the path while this one had unsaved changes.
    @State private var askSwitch: String?
    /// ⌘E reaches both the editor and the page: once.
    @State private var lastToggle = Date.distantPast

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

    private var sessions: FileEditSessions { .shared }
    /// This tab's edit, while there is one.
    private var session: FileEditSession? { editKey.flatMap { sessions.session($0(target.path)) } }
    private var editing: Bool { session?.editing == true }

    /// Editing is offered: a pane's tab on the Mac or a regular-width iPad,
    /// a UTF-8 text file up to 1 MB from a host that saves, not an item of 成果.
    private var canEdit: Bool {
        guard editKey != nil, retarget != nil, readVersion != nil, plainUTF8, !isArtifact else { return false }
        #if !targetEnvironment(macCatalyst)
        guard sizeClass == .regular else { return false }
        #endif
        if case .text(let text, _, _) = phase { return text.utf8.count <= FilesWriteParams.maxBytes }
        return false
    }

    /// 成果 are the assistant's: they're read here, not edited.
    private var isArtifact: Bool {
        (target.scope.kind == .palo && target.path.hasPrefix("artifacts/")) || target.path.contains("/.paloally/home/artifacts/")
    }

    @ViewBuilder var body: some View {
        if inPane {
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { if !editing { paneMenu.padding(10) } }
                .overlay(alignment: .bottom) { reloadedCapsule }
                .background { reloadKey; editKeyCommand }
                .task(id: target) { await load() }
                .task(id: follow) { await followFile(follow) }
                .modifier(UnsavedChangesDialog(
                    asking: Binding(get: { askSwitch != nil }, set: { if !$0 { askSwitch = nil } }),
                    name: target.name,
                    save: { saveThenSwitch() },
                    discard: { if let path = askSwitch { show(path) } }))
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: .demoFileEdit)) { note in
                    let step = note.object as? String ?? ""
                    if step == "filesave", let session { Task { await session.save(store: store) } }
                    else if step.hasPrefix("fileopen:") { switchFile(String(step.dropFirst(9))) }
                    else { toggleEdit() }
                }
                #endif
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

    /// A pane's tab: the editor while editing (kept, hidden, while its
    /// unsaved text is previewed), else the file.
    @ViewBuilder private var paneContent: some View {
        if let session {
            ZStack {
                editorPage(session)
                    .opacity(session.editing ? 1 : 0)
                    .allowsHitTesting(session.editing)
                    .accessibilityHidden(!session.editing)
                if !session.editing { content }
            }
        } else {
            content
        }
    }

    private func editorPage(_ session: FileEditSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileBreadcrumb(target: target, paneScope: fallbackScope, pick: switchFile)
                saveButton(session)
                paneMenu
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 44)
            Divider()
            if session.conflict != nil {
                FileConflictBar(loadTheirs: { Task { await loadTheirs(session) } },
                                useMine: { Task { await session.save(store: store, force: true) } })
                Divider()
            } else if let error = session.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    Text(verbatim: error).font(.system(size: 12)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { session.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            FileEditorView(editor: session.editor)
                .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            session.editor.onSave = { [store] in Task { await session.save(store: store) } }
            session.editor.onToggle = { toggleEdit() }
        }
    }

    /// 保存 (⌘S): there only while something is unsaved.
    private func saveButton(_ session: FileEditSession) -> some View {
        Button { Task { await session.save(store: store) } } label: {
            ZStack {
                Text("保存", tableName: "Files").opacity(session.saving ? 0 : 1)
                if session.saving { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(!session.dirty || session.saving)
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityIdentifier("file-save")
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .progress(let p):
            ProgressView(value: p).frame(maxWidth: 240).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let kind, _):
            // Unsaved text, previewed while the editor is away.
            FileTextPreview(fileName: kind == .markdown ? FilePreviewRoute.markdownRenderName(target.name) : target.name,
                            text: session?.previewText ?? text, raw: raw, imageSource: kind == .markdown ? images : nil)
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
            if canEdit || session != nil {
                Button { toggleEdit() } label: {
                    Label {
                        Text(editing ? String(localized: "预览", table: "Files") : String(localized: "编辑", table: "Files"))
                    } icon: {
                        Image(systemName: editing ? "doc.richtext" : "pencil")
                    }
                }
                .accessibilityIdentifier("file-toggle-edit")
                Divider()
            }
            reloadButton
            if let fileURL {
                ShareLink(item: fileURL) { Label { Text("共享", tableName: "Files") } icon: { Image(systemName: "square.and.arrow.up") } }
            }
            if isMarkdown, !editing {
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

    /// ⌘E (Mac, iPad keyboard): 编辑 / 预览.
    @ViewBuilder private var editKeyCommand: some View {
        if canEdit || session != nil {
            Button("") { toggleEdit() }
                .keyboardShortcut("e", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: editing

    /// 编辑 ⇄ 预览. Back to the preview with nothing unsaved ends the edit;
    /// with something unsaved the editor stays, hidden, and the preview shows its text.
    private func toggleEdit() {
        guard Date().timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = Date()
        guard let session else { return startEditing() }
        if !session.editing {
            session.previewText = nil
            session.editing = true
            session.editor.focusText()
        } else if session.dirty {
            Task {
                session.previewText = await session.editor.snapshot()?.text
                session.editing = false
            }
        } else {
            sessions.end(session.key)
        }
    }

    private func startEditing() {
        guard canEdit, let editKey, case .text(let text, _, _) = phase, let version = readVersion else { return }
        debugLog("file edit: editing \(target.name)")
        sessions.begin(FileEditSession(key: editKey(target.path), scope: readScope ?? target.scope, path: target.path,
                                       text: text, version: version, dark: colorScheme == .dark))
    }

    /// A file picked from the path: in this tab, in the editor; unsaved changes asked about first.
    private func switchFile(_ path: String) {
        if session?.dirty == true { askSwitch = path } else { show(path) }
    }

    private func show(_ path: String) {
        guard let retarget, let editKey else { return }
        askSwitch = nil
        sessions.end(editKey(target.path))
        sessions.startEditing.insert(editKey(path))
        retarget(path)
    }

    private func saveThenSwitch() {
        guard let path = askSwitch, let session else { return }
        Task {
            // A refused save (changed on the computer) stays, its bar up.
            if await session.save(store: store) { show(path) }
        }
    }

    /// 载入电脑上的版本: what the computer has, in the editor and the preview.
    private func loadTheirs(_ session: FileEditSession) async {
        debugLog("file edit: \(target.name), the computer's version taken")
        do {
            let r = try await store.readFile(session.scope, path: session.path)
            guard !r.tooLarge, let version = r.version else { return }
            session.adopt(text: String(decoding: r.data, as: UTF8.self), version: version)
            await load(quietly: true)
        } catch {
            session.error = Copy.error(error)
        }
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
            let r: (data: Data, mime: String, size: Int64, tooLarge: Bool, version: String?)
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
            readVersion = r.version
            plainUTF8 = text != nil && String(data: r.data, encoding: .utf8) != nil
            // Being edited: the editor hears of it (in place, or the bar).
            if let text, let version = r.version { session?.diskRead(text: text, version: version) }
            // Re-read and the same: leave it be (no re-render, no flash).
            if quietly, !force, let text, case .text(let shown, let shownKind, _) = phase, shown == text, shownKind == kind { return }
            if quietly, !force, text == nil, case .quickLook(let shown) = phase, (try? Data(contentsOf: shown)) == r.data { return }
            let url = try Self.save(r.data, for: target)
            if let text {
                phase = .text(text, kind, url)
                // Opened from the path while editing: in the editor.
                if let editKey, sessions.startEditing.remove(editKey(target.path)) != nil, session == nil { startEditing() }
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
