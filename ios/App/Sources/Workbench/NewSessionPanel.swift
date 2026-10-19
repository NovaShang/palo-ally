import PaloAllyKit
import SwiftUI

/// 新建会话 (workbench-prd §9): the folders used lately, the open session's
/// folder first. Type to search; Return starts a session in the highlighted
/// folder, ⌘↩ adds it to the workspace you're in; 选择其他文件夹… walks the
/// computer's folders. The new session opens, named by its first words.
struct NewSessionPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [SessionFolder]?
    @State private var query = ""
    @State private var highlighted: String?
    @State private var starting: String?
    @State private var failure: String?
    @State private var browsing = false
    @FocusState private var searching: Bool

    /// The workspace of the page that's open: ⌘↩ puts the new session in it.
    private var workspace: Workspace? {
        store.workspaceID(of: model.selection).flatMap { store.workspace(id: $0) }
    }

    /// The open session's folder first, then the others as the host listed them.
    private var shown: [SessionFolder] {
        var list = folders ?? []
        if let cwd = store.openSessionFolder(model.selection), let i = list.firstIndex(where: { $0.path == cwd }), i > 0 {
            list.insert(list.remove(at: i), at: 0)
        } else if let cwd = store.openSessionFolder(model.selection), !list.contains(where: { $0.path == cwd }) {
            list.insert(SessionFolder(path: cwd, name: (cwd as NSString).lastPathComponent, lastUsedAt: 0), at: 0)
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("搜索文件夹", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .focused($searching)
                    .submitLabel(.go)
                    .onSubmit { startHighlighted(into: nil) }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("new-session-search")
                list
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.tint(.primary) }
            }
            .navigationDestination(isPresented: $browsing) {
                FolderPicker(chosen: { start($0, into: nil) })
                    .modifier(InContentNavigationBar())
            }
            .task(id: store.connection.isOnline) {
                guard store.connection.isOnline else { return }
                folders = (try? await store.sessionFolders()) ?? folders ?? []
                highlighted = highlighted ?? shown.first?.path
            }
            .onAppear { searching = true }
            .onChange(of: query) { _, _ in highlighted = shown.first?.path }
            // ↑ ↓ move the highlight; ⌘↩ adds to the workspace you're in.
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .background {
                if let workspace {
                    Button("加到工作区") { startHighlighted(into: workspace.id) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("new-session")
    }

    private var list: some View {
        List {
            if let failure {
                Text(Copy.spaced(failure)).foregroundStyle(.red)
            }
            ForEach(shown) { folder in
                Button { start(folder.path, into: nil) } label: { row(folder) }
                    .tint(.primary)
                    .listRowBackground(highlighted == folder.path ? Color.primary.opacity(0.08) : nil)
                    .disabled(starting != nil || !store.connection.isOnline)
                    .accessibilityIdentifier("new-session-\(folder.name)")
            }
            Section {
                Button { browsing = true } label: {
                    Label("选择其他文件夹…", systemImage: "folder.badge.plus")
                }
                .tint(.primary)
                .disabled(starting != nil || !store.connection.isOnline)
                .accessibilityIdentifier("new-session-other")
            } footer: {
                if let workspace {
                    Text("⌘↩ 加到工作区「\(workspace.title(pals: store.pals))」")
                }
            }
        }
        .overlay {
            if folders == nil {
                ProgressView()
            } else if shown.isEmpty, !query.isEmpty {
                Text("没有匹配的文件夹。").foregroundStyle(.secondary).padding(32)
            }
        }
    }

    private func row(_ folder: SessionFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).foregroundStyle(.primary).lineLimit(1)
                Text(CCSession.shortPath(folder.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if starting == folder.path { ProgressView() }
        }
        .contentShape(.rect)
    }

    private func move(_ step: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.path == highlighted } ?? (step > 0 ? -1 : list.count)
        highlighted = list[min(max(i + step, 0), list.count - 1)].path
    }

    private func startHighlighted(into workspaceID: String?) {
        guard let path = highlighted ?? shown.first?.path else { return }
        start(path, into: workspaceID)
    }

    private func start(_ path: String, into requested: String?) {
        guard starting == nil else { return }
        // 并排 → 新开 asks for a tile in its workspace.
        let workspaceID = requested ?? model.newSessionIntoWorkspace
        starting = path
        failure = nil
        Task {
            defer { starting = nil }
            do {
                let pal = try await store.createSession(cwd: path, workspaceId: workspaceID)
                dismiss()
                if let workspaceID, model.selection == .workspace(workspaceID) {
                    // A tile in the workspace that's open: it is the one to talk to.
                    model.activate(tile: pal.id, in: workspaceID)
                } else {
                    model.openPal(pal.id)
                }
            } catch {
                failure = Copy.error(error)
                browsing = false
            }
        }
    }
}

extension AppStore {
    /// The workspace a page belongs to: its own, or the session's.
    func workspaceID(of page: AppModel.Conversation?) -> String? {
        switch page {
        case .workspace(let id): id
        case .pal(let id): pal(id: id)?.workspaceId
        default: nil
        }
    }

    /// The folder of the session that's open (a workspace: nothing).
    func openSessionFolder(_ page: AppModel.Conversation?) -> String? {
        if case .pal(let id) = page { return pal(id: id)?.cwd }
        return nil
    }
}
