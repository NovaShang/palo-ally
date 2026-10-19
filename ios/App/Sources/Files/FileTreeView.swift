import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI

/// A folder on the computer as a tree (Bento Term's FileTreeBrowserView): a
/// Pal's project folder, or one the owner opened from 成果. Search at the
/// top; a file opens in the preview; a long press offers 插入到输入框 (a
/// Pal's: its relative path, into that Pal's composer) and 拷贝路径.
/// `.git`, `node_modules` and the like stay hidden until 显示隐藏的文件.
struct FileTreeScreen: View {
    let scope: FileScope
    /// A page pushed in the inspector: back to 成果.
    var back: (() -> Void)? = nil
    /// In a sheet or the inspector: put it away.
    var close: (() -> Void)? = nil
    /// After 插入到输入框 (the phone's sheet goes away to show the composer).
    var inserted: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.placesAsColumns) private var asColumn
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tree = LazyDirectoryTreeStore()
    @State private var root = RootBox()
    @State private var query = ""
    @State private var results: [FileMatch] = []
    @State private var searching = false
    @State private var searchFailed: String?
    @State private var opened: FileTarget?

    /// The root's absolute path, once the first listing said it.
    @Observable final class RootBox: @unchecked Sendable {
        var path: String?
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The Mac's inspector shares the window toolbar: its search field sits in the column.
    private var fieldInColumn: Bool { asColumn && UIDevice.current.userInterfaceIdiom == .mac }

    private var title: String {
        switch scope.kind {
        case .pal: store.pal(id: scope.id ?? "")?.displayName ?? String(localized: "文件", table: "Files")
        case .folder, .palo: root.path.map { ($0 as NSString).lastPathComponent } ?? String(localized: "文件", table: "Files")
        }
    }

    var body: some View {
        searchable(List {
            if trimmed.isEmpty {
                treeRows
            } else {
                searchRows
            }
        }
        .listStyle(.plain))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // Pushed (over 成果 on a phone-sized window): back is the page's own.
        .macPageTop(title, subtitle: root.path.map(FilePaths.abbreviated) ?? "",
                    back: back ?? (close == nil ? { dismiss() } : nil), trailing: AnyView(macTrailing))
        .navigationDestination(item: $opened) { FilePage(target: $0) }
        .refreshable { tree.reload() }
        .task(id: scope) {
            start()
            #if DEBUG
            // `-demoFilePath <path>`: that file opened from the tree (snapshots).
            if let path = UserDefaults.standard.string(forKey: "demoFilePath") {
                try? await Task.sleep(for: .seconds(1))
                opened = FileTarget(scope: scope, path: path)
            }
            #endif
        }
        .task(id: trimmed) { await search() }
        .accessibilityIdentifier("file-tree")
    }

    // MARK: tree

    @ViewBuilder private var treeRows: some View {
        let top = tree.state(of: "")
        if let error = tree.rootError, top.entries == nil {
            ContentUnavailableView {
                Label { Text("打不开这个文件夹", tableName: "Files") } icon: { Image(systemName: "folder.badge.questionmark") }
            } description: {
                Text(verbatim: error)
            } actions: {
                Button { tree.retry("") } label: { Text("再试一次", tableName: "Files") }
                    .buttonStyle(.glass)
                    .tint(.primary)
            }
            .listRowSeparator(.hidden)
        } else if top.entries == nil {
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowSeparator(.hidden)
                .padding(.top, 40)
        } else if top.entries?.isEmpty == true {
            ContentUnavailableView {
                Label { Text("这个文件夹是空的", tableName: "Files") } icon: { Image(systemName: "folder") }
            }
            .listRowSeparator(.hidden)
        } else {
            ForEach(top.entries ?? [], id: \.name) { entry in
                FileTreeRow(entry: entry, parent: "", tree: tree, actions: rowActions)
            }
            if top.truncated { tooManyRow }
        }
    }

    private var tooManyRow: some View {
        Text("这里东西太多，只列出了一部分，用上面的搜索找", tableName: "Files")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var rowActions: FileTreeRow.Actions {
        let insertion: ((String) -> Void)? = scope.kind == .pal ? { insert($0) } : nil
        return FileTreeRow.Actions(
            open: { opened = FileTarget(scope: scope, path: $0) },
            insert: insertion,
            copy: { rel in Clipboard.copy(root.path.map { FilePaths.join($0, rel) } ?? rel) })
    }

    // MARK: search

    @ViewBuilder private var searchRows: some View {
        if let searchFailed {
            Text(verbatim: searchFailed).foregroundStyle(.secondary)
        } else if results.isEmpty {
            if searching {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else {
                ContentUnavailableView.search(text: trimmed).listRowSeparator(.hidden)
            }
        } else {
            ForEach(results) { m in
                Button {
                    if m.kind == .dir { reveal(m.path) } else { opened = FileTarget(scope: scope, path: m.path) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: m.kind == .dir ? "folder" : FileTreeRow.symbol(m.name))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: m.name).lineLimit(1)
                            let parent = (m.path as NSString).deletingLastPathComponent
                            if !parent.isEmpty {
                                Text(verbatim: parent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu { FileTreeRow.menu(path: m.path, actions: rowActions) }
            }
        }
    }

    @ViewBuilder private func searchable(_ list: some View) -> some View {
        if fieldInColumn {
            list.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(String(localized: "搜文件名", table: "Files"), text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(Text("清除", tableName: "Files"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        } else {
            list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text("搜文件名", tableName: "Files"))
        }
    }

    // MARK: chrome

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let back {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: back) { Image(systemName: "chevron.backward") }
                    .tint(.primary)
                    .accessibilityLabel(Text("成果", tableName: "Files"))
            }
        }
        if let close {
            // A sheet closes at the leading edge; the inspector at the trailing, like 成果.
            ToolbarItem(placement: asColumn ? .topBarTrailing : .topBarLeading) {
                Button(role: .close, action: close)
                    .tint(.primary)
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
                    .accessibilityIdentifier("files-close")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { moreMenu } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
                .accessibilityLabel(Text("更多", tableName: "Files"))
        }
    }

    @ViewBuilder private var moreMenu: some View {
        Toggle(isOn: Binding(get: { tree.showHidden }, set: { tree.setShowHidden($0) })) {
            Label { Text("显示隐藏的文件", tableName: "Files") } icon: { Image(systemName: "eye") }
        }
        Button { tree.reload() } label: {
            Label { Text("刷新", tableName: "Files") } icon: { Image(systemName: "arrow.clockwise") }
        }
    }

    /// The Mac's strip: the menu, and ✕ where there's something to close.
    private var macTrailing: some View {
        HStack(spacing: 8) {
            MacStripMenu(label: String(localized: "更多", table: "Files")) { moreMenu }
            if let close {
                MacStripButton(action: close) { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
            }
        }
    }

    // MARK: actions

    private func start() {
        let store = store
        let scope = scope
        let box = root
        tree.reset { rel, hidden in
            let r = try await store.listFiles(scope, path: rel, showHidden: hidden)
            await MainActor.run { box.path = r.root }
            return DirectoryListResult(entries: r.entries.map { DirectoryEntry(name: $0.name, isDir: $0.isDir, size: $0.size) },
                                       truncated: r.truncated)
        }
    }

    private func search() async {
        searchFailed = nil
        guard !trimmed.isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await store.searchFiles(scope, query: trimmed).matches
        } catch {
            results = []
            searchFailed = Copy.error(error)
        }
    }

    /// A folder found by search: the tree, opened down to it.
    private func reveal(_ path: String) {
        query = ""
        var so = ""
        for part in path.split(separator: "/") {
            so = so.isEmpty ? String(part) : so + "/" + part
            if !tree.state(of: so).expanded { tree.toggle(so) }
        }
    }

    private func insert(_ rel: String) {
        guard case .pal = scope.kind, let id = scope.id else { return }
        model.insertIntoDraft(rel, for: .pal(id))
        inserted?()
    }
}

/// One entry of the tree; a folder holds its children (recursion lives in a
/// named type so `some View` inference terminates, as in Bento Term).
struct FileTreeRow: View {
    let entry: DirectoryEntry
    /// The parent's path relative to the root ("" for the root).
    let parent: String
    @ObservedObject var tree: LazyDirectoryTreeStore
    let actions: Actions

    struct Actions {
        let open: (String) -> Void
        let insert: ((String) -> Void)?
        let copy: (String) -> Void
    }

    private var path: String { parent.isEmpty ? entry.name : parent + "/" + entry.name }

    var body: some View {
        if entry.isDir {
            DisclosureGroup(isExpanded: Binding(get: { tree.state(of: path).expanded }, set: { _ in tree.toggle(path) })) {
                children
            } label: {
                Button { tree.toggle(path) } label: { label.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .contextMenu { Self.menu(path: path, actions: actions) }
                    // On the label: on the group it would name every row inside too.
                    .accessibilityIdentifier("file-row-\(path)")
            }
        } else {
            Button { actions.open(path) } label: { label.contentShape(.rect) }
                .buttonStyle(.plain)
                .contextMenu { Self.menu(path: path, actions: actions) }
                .accessibilityIdentifier("file-row-\(path)")
        }
    }

    @ViewBuilder private var children: some View {
        let st = tree.state(of: path)
        if st.loading && st.entries == nil {
            ProgressView().controlSize(.small)
        } else if let error = st.error, st.entries == nil {
            HStack {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button { tree.retry(path) } label: { Text("再试一次", tableName: "Files") }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
        } else if st.entries?.isEmpty == true {
            Text("空的", tableName: "Files").font(.footnote).foregroundStyle(.tertiary)
        } else {
            ForEach(st.entries ?? [], id: \.name) { kid in
                FileTreeRow(entry: kid, parent: path, tree: tree, actions: actions)
            }
            if st.truncated {
                Text("这里东西太多，只列出了一部分，用上面的搜索找", tableName: "Files")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDir ? "folder" : Self.symbol(entry.name))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(verbatim: entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !entry.isDir, entry.size > 0 {
                Text(verbatim: Copy.byteSize(entry.size))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 30)
    }

    /// The long-press menu of a file or folder.
    @ViewBuilder static func menu(path: String, actions: Actions) -> some View {
        if let insert = actions.insert {
            Button { insert(path) } label: {
                Label { Text("插入到输入框", tableName: "Files") } icon: { Image(systemName: "text.insert") }
            }
        }
        Button { actions.copy(path) } label: {
            Label { Text("拷贝路径", tableName: "Files") } icon: { Image(systemName: "doc.on.doc") }
        }
    }

    /// A glyph for a file, by kind.
    static func symbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch FileContentKind.forName(name) {
        case .markdown: return "doc.richtext"
        case .quickLook:
            if FilePreviewImageMIME.table[ext] != nil { return "photo" }
            if ["mov", "mp4", "m4v"].contains(ext) { return "film" }
            if ext == "pdf" { return "doc.text.image" }
            return "doc"
        case .text: return ext.isEmpty ? "doc.plaintext" : "chevron.left.forwardslash.chevron.right"
        }
    }
}
