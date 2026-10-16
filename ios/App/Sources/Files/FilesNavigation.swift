import PaloAllyKit
import SwiftUI

// Files on the computer (docs/files-prd.md) only appear where they're used:
// a Pal's ⋯ → 文件 (a sheet on phones; on iPads and the Mac the inspector,
// where 成果 goes), 打开文件夹… in 成果, the composer's 电脑上的文件, and
// paths in replies. No tab of their own.

/// One file in a scope, to open.
struct FileTarget: Hashable, Identifiable {
    let scope: FileScope
    /// Relative to the scope's folder.
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var id: String { "\(scope.kind.rawValue)|\(scope.id ?? "")|\(path)" }
}

extension AppModel {
    /// A Pal's ⋯ → 文件: the inspector beside its conversation on large
    /// screens, a sheet on phones.
    func openPalFiles(_ palID: String) {
        if libraryBeside {
            libraryPath = []
            filesPanel = .pal(palID)
            inspectorShown = true
        } else {
            filesSheet = .pal(palID)
        }
    }

    /// A folder opened from 成果: in place of 成果's list on large screens
    /// (back returns to it), pushed over 成果 on phones.
    func openFolder(_ id: String) {
        if libraryBeside {
            filesPanel = .folder(id)
            inspectorShown = true
        } else {
            detailPath.append(FileScope.folder(id))
        }
    }

    /// 「插入到输入框」: the words go at the end of that conversation's unsent text.
    func insertIntoDraft(_ words: String, for conversation: Conversation) {
        var draft = drafts[conversation] ?? ""
        if !draft.isEmpty, !draft.hasSuffix(" "), !draft.hasSuffix("\n") { draft += " " }
        drafts[conversation] = draft + words + " "
    }
}

/// The detail column's extra pages and what its replies may link to: a
/// folder's tree pushed over 成果 (phones), and the scope paths in replies
/// resolve against (the assistant's home, or the Pal's folder).
struct FilesInConversation: ViewModifier {
    let current: AppModel.Conversation
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: FileScope.self) { scope in
                FileTreeScreen(scope: scope)
            }
            .environment(\.fileLinks, linkContext)
    }

    private var linkContext: FileLinkContext? {
        switch current {
        case .palo: FileLinkContext(scope: .palo, resolver: .shared(for: store))
        case .pal(let id): FileLinkContext(scope: .pal(id), resolver: .shared(for: store))
        default: nil
        }
    }
}

/// Phones (and short windows): a Pal's 文件 as a sheet over its page.
struct PalFilesSheet: ViewModifier {
    let palID: String
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.filesSheet == .pal(palID) }, set: { if !$0 { model.filesSheet = nil } })) {
            NavigationStack {
                FileTreeScreen(scope: .pal(palID), close: { model.filesSheet = nil }, inserted: { model.filesSheet = nil })
            }
            .environment(model)
            .environment(store)
        }
        #if DEBUG
        // `-demoPalFiles YES`: the page opens with its 文件 (snapshots).
        .task {
            guard UserDefaults.standard.bool(forKey: "demoPalFiles") else { return }
            try? await Task.sleep(for: .seconds(1))
            model.openPalFiles(palID)
        }
        #endif
    }
}

/// Large screens: the inspector shows a tree in place of 成果 — a Pal's
/// (closed with ✕) or a folder opened from 成果 (back to 成果).
struct FilesPanel: View {
    let scope: FileScope
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            FileTreeScreen(
                scope: scope,
                back: scope.kind == .folder ? { model.filesPanel = nil } : nil,
                close: { model.inspectorShown = false })
                .modifier(InContentNavigationBar())
        }
        .environment(\.placesAsColumns, true)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // A Pal's files belong beside its conversation only.
        .onChange(of: model.selection) { _, now in
            if scope.kind == .pal, let id = scope.id, now != .pal(id) { model.inspectorShown = false }
        }
    }
}

/// 成果's 文件夹: the folders opened before, and 打开文件夹….
struct OwnerFoldersSection: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var folders: [OwnerFolder] = []
    @State private var picking = false
    @State private var failure: String?

    var body: some View {
        Section {
            ForEach(folders) { f in
                Button { model.openFolder(f.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: f.name).font(.body).lineLimit(1)
                            Text(verbatim: FilePaths.abbreviated(f.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { Task { await remove(f) } } label: {
                        Label { Text("移除", tableName: "Files") } icon: { Image(systemName: "minus.circle") }
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { Task { await remove(f) } } label: {
                        Label { Text("移除", tableName: "Files") } icon: { Image(systemName: "minus.circle") }
                    }
                }
                .accessibilityIdentifier("owner-folder-\(f.name)")
            }
            Button { picking = true } label: {
                Label { Text("打开文件夹…", tableName: "Files") } icon: { Image(systemName: "folder.badge.plus") }
            }
            .tint(.primary)
            .accessibilityIdentifier("open-folder")
        } header: {
            Text("文件夹", tableName: "Files")
        } footer: {
            if let failure { Text(verbatim: failure) }
        }
        .task { await load() }
        .sheet(isPresented: $picking) {
            NavigationStack {
                FolderPicker { folder in
                    picking = false
                    if !folders.contains(where: { $0.id == folder.id }) { folders.append(folder) }
                    model.openFolder(folder.id)
                }
            }
            .environment(store)
            .presentationSizing(.form)
        }
    }

    private func load() async {
        if let list = try? await store.ownerFolders() { folders = list }
        #if DEBUG
        // `-demoOpenFolder <path>`: that folder opened from here (snapshots).
        if let path = UserDefaults.standard.string(forKey: "demoOpenFolder"), folders.isEmpty,
           let f = try? await store.addOwnerFolder(path: path) {
            folders = [f]
            model.openFolder(f.id)
        }
        #endif
    }

    private func remove(_ f: OwnerFolder) async {
        do {
            try await store.removeOwnerFolder(id: f.id)
            folders.removeAll { $0.id == f.id }
            if model.filesPanel == .folder(f.id) { model.filesPanel = nil }
            failure = nil
        } catch {
            failure = Copy.error(error)
        }
    }
}

enum FilePaths {
    /// `/Users/someone/code/x` → `~/code/x` (the computer's home, guessed from the path).
    static func abbreviated(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[1] == "Users" else { return path }
        let rest = parts.dropFirst(3).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }

    /// `root` and a path under it, as one absolute path.
    static func join(_ root: String, _ rel: String) -> String {
        rel.isEmpty ? root : (root.hasSuffix("/") ? root + rel : root + "/" + rel)
    }
}
