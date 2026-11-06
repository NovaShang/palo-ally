import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI

// Editing a text file from its tab (Mac and iPad): CodeMirror in a web view,
// saved back to the computer with ⌘S or 保存 (`files.write`), never on its
// own, and only over the version it was read at.

/// One file being edited in a pane's tab. It outlives the tab's page (a tab
/// shown again finds its text, cursor and undo as they were) and ends when
/// the edit does: back to the preview with nothing unsaved, or the tab closed.
@MainActor @Observable
final class FileEditSession {
    let key: String
    /// Where it is read and written (the tab's scope, or its fallback).
    let scope: FileScope
    let path: String
    /// The editor shown (false: the preview, with what is unsaved in it).
    var editing = true
    /// The text differs from the computer's copy.
    private(set) var dirty = false
    private(set) var saving = false
    /// The computer's copy changed while something here was unsaved, or a
    /// save found it changed: the version there now (saved over with 用我的覆盖).
    private(set) var conflict: String?
    /// A save that failed for another reason.
    var error: String?
    /// The unsaved text the preview shows while the editor is away.
    var previewText: String?
    /// The version on the computer the text was read or saved at.
    private(set) var baseVersion: String
    /// What the computer has, as last read or saved.
    private(set) var diskText: String
    @ObservationIgnored let editor: FileEditorWebView

    init(key: String, scope: FileScope, path: String, text: String, version: String, dark: Bool) {
        self.key = key
        self.scope = scope
        self.path = path
        baseVersion = version
        diskText = text
        FileEditorWebView.log = { debugLog($0) }
        editor = FileEditorWebView.make()
        editor.onDirty = { [weak self] in self?.dirty = $0 }
        editor.load(fileName: (path as NSString).lastPathComponent, text: text, dark: dark, focus: true)
    }

    /// Write the text back over the version it was read at (`force`: over
    /// the computer's changed copy, 用我的覆盖). False when it wasn't saved.
    @discardableResult
    func save(store: AppStore, force: Bool = false) async -> Bool {
        guard !saving else { return false }
        guard dirty || force else { return true }
        // Set before the snapshot: ⌘S can come from the page and the menu at once.
        saving = true
        defer { saving = false }
        guard let snap = await editor.snapshot() else { return false }
        let base = force ? (conflict ?? baseVersion) : baseVersion
        do {
            let version = try await store.writeFile(scope, path: path, text: snap.text, baseVersion: base)
            baseVersion = version
            diskText = snap.text
            conflict = nil
            error = nil
            editor.saved(snap.id)
            debugLog("file edit: saved \((path as NSString).lastPathComponent) (\(snap.text.utf8.count) bytes)")
            return true
        } catch let c as FileWriteConflict {
            debugLog("file edit: \((path as NSString).lastPathComponent) changed on the computer, not saved")
            conflict = c.version
            return false
        } catch {
            debugLog("file edit: saving \((path as NSString).lastPathComponent) failed: \(error)")
            self.error = Copy.error(error)
            return false
        }
    }

    /// The file read again (it changed on disk, or by hand). Nothing unsaved:
    /// the editor takes it in place. Something unsaved: the bar asks.
    func diskRead(text: String, version: String) {
        // A save in flight: its own change coming back; the save says the version.
        guard !saving, version != baseVersion else { return }
        if text == diskText {
            baseVersion = version
            return
        }
        if dirty {
            conflict = version
        } else {
            editor.replace(with: text)
            diskText = text
            baseVersion = version
            conflict = nil
        }
    }

    /// 载入电脑上的版本: the computer's copy in the editor, what was unsaved dropped.
    func adopt(text: String, version: String) {
        editor.replace(with: text)
        diskText = text
        baseVersion = version
        conflict = nil
        error = nil
        previewText = nil
    }
}

/// The files being edited, by tab (`FileEditSessions.key`); a tab's chip
/// reads its dot here, closing it asks here.
@MainActor @Observable
final class FileEditSessions {
    static let shared = FileEditSessions()
    private(set) var sessions: [String: FileEditSession] = [:]
    /// Tabs to open in the editor when they show (a file picked from the path while editing).
    @ObservationIgnored var startEditing: Set<String> = []

    /// A pane's tab's file, on its computer.
    static func key(store: AppStore, pane: String, path: String) -> String {
        "\(ObjectIdentifier(store).hashValue)|\(pane)|\(path)"
    }

    func session(_ key: String) -> FileEditSession? { sessions[key] }
    func isDirty(_ key: String) -> Bool { sessions[key]?.dirty == true }
    func begin(_ s: FileEditSession) { sessions[s.key] = s }
    func end(_ key: String) { sessions.removeValue(forKey: key) }
}

/// Saving's question, before a file with unsaved changes goes (its tab
/// closed, another file picked in it): 保存 / 不保存 / 取消.
struct UnsavedChangesDialog: ViewModifier {
    @Binding var asking: Bool
    let name: String
    let save: () -> Void
    let discard: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text("「\(name)」还没保存", tableName: "Files"), isPresented: $asking, titleVisibility: .visible
        ) {
            Button { save() } label: { Text("保存", tableName: "Files") }
            Button(role: .destructive) { discard() } label: { Text("不保存", tableName: "Files") }
            Button(role: .cancel) {} label: { Text("取消", tableName: "Files") }
        } message: {
            Text("不保存的话，改动会丢掉。", tableName: "Files")
        }
    }
}

// MARK: - the path at the top of the editor

/// The file's path as a row of folders (项目 › docs › 设计 › 列表页.md): a
/// folder lists what's in it, the file lists the files beside it; picking a
/// file shows it in this tab.
struct FileBreadcrumb: View {
    let target: FileTarget
    /// The pane's own files: an absolute path inside them starts at their folder.
    let paneScope: FileScope?
    let pick: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var base: Base?
    @State private var shown: Int?

    /// Where the row starts: a folder in the target's scope ("" its root,
    /// or an absolute one) and the name it shows by.
    struct Base: Equatable {
        let dir: String
        let label: String
    }

    private struct Crumb: Identifiable {
        let id: Int
        let label: String
        /// The folder its list shows.
        let dir: String
        let isFile: Bool
    }

    var body: some View {
        // Its end (the file) in sight; drawn once its start is known (no flash of the whole disk path).
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
                .defaultScrollAnchor(.trailing)
                .defaultScrollAnchor(.trailing, for: .sizeChanges)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(base == nil ? 0 : 1)
        .task(id: target) { base = await findBase() }
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(crumbs) { c in
                if c.id > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                crumb(c)
            }
        }
        .padding(.horizontal, 6)
    }

    private func crumb(_ c: Crumb) -> some View {
        Button { shown = c.id } label: {
            Text(verbatim: c.label)
                .font(.system(size: 12, weight: c.isFile ? .semibold : .regular))
                .foregroundStyle(c.isFile ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(shown == c.id ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .popover(isPresented: Binding(get: { shown == c.id }, set: { if !$0, shown == c.id { shown = nil } })) {
            FolderList(scope: target.scope, dir: c.dir, current: target.path) { path in
                shown = nil
                pick(path)
            }
            .environment(store)
        }
        .accessibilityIdentifier(c.isFile ? "breadcrumb-file" : "breadcrumb-\(c.id)")
    }

    private var crumbs: [Crumb] {
        let path = target.path
        let base = base ?? Base(dir: target.path.hasPrefix("/") ? "/" : "", label: target.path.hasPrefix("/") ? "/" : "")
        var rest = path
        if base.dir == "/" {
            rest = String(path.drop { $0 == "/" })
        } else if !base.dir.isEmpty, path.hasPrefix(base.dir + "/") {
            rest = String(path.dropFirst(base.dir.count + 1))
        }
        let parts = rest.split(separator: "/").map(String.init)
        var out: [Crumb] = []
        if !base.label.isEmpty { out.append(Crumb(id: 0, label: base.label, dir: base.dir, isFile: false)) }
        var dir = base.dir
        for (i, part) in parts.enumerated() {
            let isFile = i == parts.count - 1
            let inside = Self.join(dir, part)
            // The file lists its own folder (the files beside it).
            out.append(Crumb(id: out.count, label: part, dir: isFile ? dir : inside, isFile: isFile))
            dir = inside
        }
        return out
    }

    static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// An absolute path: from the pane's folder when it is in it, else from
    /// the home folder (as ~), else from /. A path in a scope: from its folder.
    private func findBase() async -> Base {
        let path = target.path
        if !path.hasPrefix("/") {
            let root = (try? await store.listFiles(target.scope, path: ""))?.root ?? ""
            return Base(dir: "", label: root.isEmpty ? "" : (root as NSString).lastPathComponent)
        }
        if let paneScope, let root = (try? await store.listFiles(paneScope, path: ""))?.root, !root.isEmpty, root != "/",
           path.hasPrefix(root + "/") {
            return Base(dir: root, label: (root as NSString).lastPathComponent)
        }
        let parts = path.split(separator: "/")
        if parts.count > 2, parts[0] == "Users" {
            return Base(dir: "/Users/\(parts[1])", label: "~")
        }
        return Base(dir: "/", label: "/")
    }
}

/// A folder's list in a popover: its folders open further in (a back row
/// returns), a file is picked.
private struct FolderList: View {
    let scope: FileScope
    let dir: String
    let current: String
    let pick: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var stack: [String] = []
    @State private var entries: [FileEntry]?
    @State private var failed: String?

    private var at: String { stack.last ?? dir }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if stack.count > 1 {
                Button { stack.removeLast() } label: {
                    Label { Text(verbatim: (stack[stack.count - 2] as NSString).lastPathComponent.isEmpty ? "/" : (stack[stack.count - 2] as NSString).lastPathComponent) }
                        icon: { Image(systemName: "chevron.left") }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let entries {
                        if entries.isEmpty {
                            Text("空文件夹", tableName: "Files").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(entries) { e in row(e) }
                    } else if let failed {
                        Text(verbatim: failed).font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 280)
        .frame(minHeight: 60, maxHeight: 420)
        .onAppear { if stack.isEmpty { stack = [dir] } }
        .task(id: at) { await list() }
    }

    private func row(_ e: FileEntry) -> some View {
        let path = FileBreadcrumb.join(at, e.name)
        let isCurrent = path == current
        return Button {
            if e.isDir { stack.append(path) } else if !isCurrent { pick(path) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: e.isDir ? "folder" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: e.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if e.isDir {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                } else if isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(FolderRowStyle())
    }

    private func list() async {
        entries = nil
        failed = nil
        do {
            entries = try await store.listFiles(scope, path: at).entries
        } catch {
            failed = Copy.error(error)
        }
    }
}

private struct FolderRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear))
            .onHover { hovering = $0 }
    }
}

// MARK: - the bar when the computer's copy changed

/// 「文件在电脑上被改了」: take the computer's copy, or save over it.
struct FileConflictBar: View {
    let loadTheirs: () -> Void
    let useMine: () -> Void

    var body: some View {
        // A narrow pane: the buttons under the words.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                HStack(spacing: 8) { buttons }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .tint(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .accessibilityIdentifier("file-conflict-bar")
    }

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("文件在电脑上被改了", tableName: "Files")
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(action: loadTheirs) { Text("载入电脑上的版本", tableName: "Files").fixedSize() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("conflict-load")
        Button(action: useMine) { Text("用我的覆盖", tableName: "Files").fixedSize() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("conflict-overwrite")
    }
}
