import PaloAllyKit
import SwiftUI

// Files on the computer (docs/files-prd.md) only appear where they're used:
// a session's 文件 and paths in replies (tabs of the right pane, see
// PaneRouting), 打开文件夹… in 成果, and the composer's 电脑上的文件.

/// One file in a scope, to open.
struct FileTarget: Hashable, Identifiable {
    let scope: FileScope
    /// Relative to the scope's folder.
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var id: String { "\(scope.kind.rawValue)|\(scope.id ?? "")|\(path)" }
}

extension AppModel {
    /// A folder opened from 成果: in place of 成果's list, in the pane (back returns to it).
    func openFolder(_ id: String) {
        filesPanel = .folder(id)
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

/// A folder's tree in the pane in place of 成果's list (back to 成果).
struct FilesPanel: View {
    let scope: FileScope
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            FileTreeScreen(
                scope: scope,
                back: { model.filesPanel = nil },
                close: { model.setPane(open: false) })
                .modifier(InContentNavigationBar())
        }
        .environment(\.placesAsColumns, true)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
                    Text("打开文件夹…", tableName: "Files")
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-folder")
            // On the row: a Section in a List doesn't present.
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
        } header: {
            Text("文件夹", tableName: "Files")
        } footer: {
            if let failure { Text(verbatim: failure) }
        }
        .task { await load() }
    }

    private func load() async {
        if let list = try? await store.ownerFolders() { folders = list }
        #if DEBUG
        // `-demoOpenFolder <path>`: that folder opened from here; `-demoAddFolder
        // <path>`: only remembered (snapshots).
        for (key, open) in [("demoAddFolder", false), ("demoOpenFolder", true)] {
            guard let path = UserDefaults.standard.string(forKey: key), !folders.contains(where: { $0.path == path }),
                  let f = try? await store.addOwnerFolder(path: path) else { continue }
            folders.append(f)
            if open { model.openFolder(f.id) }
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
