import PaloAllyKit
import SwiftUI

struct MemorySection: View {
    @Environment(AppStore.self) private var store
    @State private var files: [MemoryFile] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        let core = files.filter { $0.scope == .core }
        let auto = files.filter { $0.scope != .core }
        Group {
            if loading && files.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let error, files.isEmpty {
                Section { Text(error).foregroundStyle(.secondary) }
            } else if files.isEmpty {
                Section {
                    ContentUnavailableView("还没记下什么", systemImage: "brain",
                                           description: Text("聊得越多，它越了解你。"))
                }
            }
            if !core.isEmpty {
                Section {
                    ForEach(core) { MemoryRow(file: $0, onSaved: reload) }
                } header: {
                    Text("关于你，它一直记着")
                } footer: {
                    Text("这些每次都会带上，越短越好。")
                }
            }
            if !auto.isEmpty {
                Section("它随手记下的") {
                    ForEach(auto) { MemoryRow(file: $0, onSaved: reload) }
                }
            }
        }
        .task { await load() }
    }

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await store.memoryFiles()
            error = nil
        } catch {
            self.error = Copy.error(error)
        }
    }
}

private struct MemoryRow: View {
    let file: MemoryFile
    let onSaved: () -> Void

    var body: some View {
        NavigationLink {
            MemoryEditorView(file: file, onSaved: onSaved)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.scope == .core ? "heart.text.square" : "note.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.displayName(file.path))
                    Text("\(Copy.byteSize(file.size)) · \(Copy.relative(file.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func displayName(_ path: String) -> String {
        switch (path as NSString).lastPathComponent {
        case "user.md": "关于你"
        case "soul.md": "它的性格"
        case "MEMORY.md": "记忆目录"
        default: ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }
}

struct MemoryEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let file: MemoryFile
    var onSaved: () -> Void = {}
    @State private var text = ""
    @State private var original = ""
    /// The host's `updatedAt` for what we loaded; sent back on save so a
    /// change the assistant made meanwhile isn't overwritten.
    @State private var baseUpdatedAt: Int64?
    @State private var loading = true
    @State private var loadError: String?
    @State private var conflict = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if let loadError {
                // Never show an empty, editable editor: saving it would wipe the file.
                ContentUnavailableView {
                    Label("读不出来", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("再试一次") { Task { await load() } }
                        .buttonStyle(.glass)
                        .tint(.primary)
                }
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
            }
        }
        .navigationTitle(MemoryRowName.name(file.path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "正在存…" : "保存") { save() }
                    .disabled(text == original || saving || loading || loadError != nil || conflict)
            }
        }
        .alert("这个文件刚被助理改过", isPresented: $conflict) {
            Button("重新打开") { Task { await load() } }
            Button("先留着我的", role: .cancel) {}
        } message: {
            Text("为了不覆盖它的改动，这次没存。重新打开会看到最新内容（你的修改会丢掉，可以先复制一下）。")
        }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 8)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        loadError = nil
        message = nil
        do {
            let r = try await store.readMemory(path: file.path)
            text = r.content
            original = r.content
            baseUpdatedAt = r.updatedAt
        } catch {
            loadError = Copy.error(error)
        }
        loading = false
    }

    static let conflictMessage = "这个文件刚被助理改过，请重新打开再改"

    private func save() {
        saving = true
        message = nil
        Task {
            do {
                // The returned stamp is the base for the next save, so it
                // isn't refused as a conflict with ourselves.
                baseUpdatedAt = try await store.writeMemory(path: file.path, content: text, baseUpdatedAt: baseUpdatedAt)
                original = text
                message = "存好了"
                onSaved()
            } catch RPCError.remote(let m) where m.contains("刚被助理改过") {
                conflict = true
            } catch {
                message = "没存上：\(Copy.error(error))"
            }
            saving = false
        }
    }
}

private enum MemoryRowName {
    static func name(_ path: String) -> String {
        switch (path as NSString).lastPathComponent {
        case "user.md": "关于你"
        case "soul.md": "它的性格"
        case "MEMORY.md": "记忆目录"
        default: (path as NSString).lastPathComponent
        }
    }
}
