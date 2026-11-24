import PaloAllyKit
import SwiftUI

/// What it remembers, to read and edit: the assistant's (关于你, 它的性格, what
/// it noted down), or with `agent` that agent's (its folder's CLAUDE.md, and
/// what its harness noted down for the folder).
struct MemorySection: View {
    /// A Pal's id; nil: the assistant.
    var agent: String? = nil
    @Environment(AppStore.self) private var store
    @Environment(WindowModel.self) private var model
    @State private var files: [MemoryFile] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        let core = files.filter { $0.scope == .core }
        let auto = files.filter { $0.scope != .core }
        Group {
            if loading && files.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            } else if let error, files.isEmpty {
                Section { Text(error).foregroundStyle(.secondary).detailRow() }
            } else if files.isEmpty {
                Section {
                    ContentUnavailableView("还没记下什么", systemImage: "brain").listRowBackground(Color.clear)
                }
            }
            if !core.isEmpty {
                Section {
                    ForEach(Array(core.enumerated()), id: \.element.id) { i, f in
                        MemoryRow(file: f, agent: agent, onSaved: reload).detailRow(i, of: core.count)
                    }
                } header: {
                    agent == nil ? Text("关于你，它一直记着") : Text("文件夹里的说明")
                }
            }
            if !auto.isEmpty {
                Section("它随手记下的") {
                    ForEach(Array(auto.enumerated()), id: \.element.id) { i, f in
                        MemoryRow(file: f, agent: agent, onSaved: reload).detailRow(i, of: auto.count)
                    }
                }
            }
        }
        .task(id: model.memoryRevision) { await load() }
    }

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await store.memoryFiles(agent: agent)
            error = nil
        } catch {
            self.error = Copy.error(error)
        }
    }
}

private struct MemoryRow: View {
    let file: MemoryFile
    var agent: String?
    let onSaved: () -> Void

    var body: some View {
        NavigationLink {
            MemoryEditorView(file: file, agent: agent, onSaved: onSaved)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.scope == .core ? (agent == nil ? "heart.text.square" : "doc.text") : "note.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MemoryRowName.name(file.path, agent: agent, short: true))
                    Group {
                        if file.missing {
                            Text("还没有，点一下写")
                        } else {
                            Text("\(Copy.byteSize(file.size)) · \(Copy.relative(file.updatedAt))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MemoryEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let file: MemoryFile
    /// A Pal's id: one of that agent's files.
    var agent: String? = nil
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
        .navigationTitle(MemoryRowName.name(file.path, agent: agent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? String(localized: "正在存…") : String(localized: "保存")) { save() }
                    .disabled(text == original || saving || loading || loadError != nil || conflict)
            }
        }
        .alert(agent == nil ? Text("这个文件刚被助理改过") : Text("这个文件刚被改过"), isPresented: $conflict) {
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
            let r = try await store.readMemory(path: file.path, agent: agent)
            text = r.content
            original = r.content
            baseUpdatedAt = r.updatedAt
        } catch {
            loadError = Copy.error(error)
        }
        loading = false
    }

    private func save() {
        saving = true
        message = nil
        Task {
            do {
                // The returned stamp is the base for the next save, so it
                // isn't refused as a conflict with ourselves.
                baseUpdatedAt = try await store.writeMemory(path: file.path, content: text, baseUpdatedAt: baseUpdatedAt, agent: agent)
                original = text
                message = String(localized: "存好了")
                onSaved()
            } catch RPCError.remote(let m) where (m.contains("刚被") && m.contains("改过")) || m.contains("just changed") {  // i18n-ok: the host's own words (the assistant's or an agent's), in either language
                conflict = true
            } catch {
                message = String(localized: "没存上：\(Copy.error(error))")
            }
            saving = false
        }
    }
}

private enum MemoryRowName {
    /// The assistant's core files by what they are; an agent's folder files as
    /// they're called (CLAUDE.md, .claude/CLAUDE.md); a note by its name
    /// (`short`: without .md, in the list).
    static func name(_ path: String, agent: String?, short: Bool = false) -> String {
        let file = (path as NSString).lastPathComponent
        switch file {
        case "user.md" where agent == nil: return String(localized: "关于你")
        case "soul.md" where agent == nil: return String(localized: "它的性格")
        case "MEMORY.md": return String(localized: "记忆目录")
        default:
            if !path.hasPrefix("memory/") { return path }
            return short ? (file as NSString).deletingPathExtension : file
        }
    }
}
