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
                    ForEach(core) { MemoryRow(file: $0) }
                } header: {
                    Text("关于你，它一直记着")
                } footer: {
                    Text("这些每次都会带上，越短越好。")
                }
            }
            if !auto.isEmpty {
                Section("它随手记下的") {
                    ForEach(auto) { MemoryRow(file: $0) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await store.memoryFiles()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MemoryRow: View {
    let file: MemoryFile

    var body: some View {
        NavigationLink {
            MemoryEditorView(file: file)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.scope == .core ? "heart.text.square" : "note.text")
                    .foregroundStyle(.tint)
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
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Group {
            if loading {
                ProgressView()
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
                    .disabled(text == original || saving || loading)
            }
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
        .task {
            do {
                let c = try await store.readMemory(path: file.path)
                text = c
                original = c
            } catch {
                message = "读不出来：\(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await store.writeMemory(path: file.path, content: text)
                original = text
                message = "存好了"
            } catch {
                message = "没存上：\(error.localizedDescription)"
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
