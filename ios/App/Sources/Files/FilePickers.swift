import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI

/// The location bar both pickers share (Bento Term's DirectoryPickerView):
/// up, and the trail of folders above, each a tap away; the folder you're
/// in stays visible at the end.
private struct PickerLocationBar: View {
    let nav: DirectoryPickerPath
    /// The name shown for "/" (a scope's folder), or nil for the disk's root.
    let rootLabel: String?
    let go: ((inout DirectoryPickerPath) -> Void) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { go { $0.up() } } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!nav.canGoUp)
            .foregroundStyle(nav.canGoUp ? .primary : .tertiary)
            .accessibilityLabel(Text("上一层", tableName: "Files"))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(nav.breadcrumb) { crumb in
                            if crumb.path != "/" {
                                Image(systemName: "chevron.forward")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Button { go { $0.jump(to: crumb.path) } } label: {
                                Text(verbatim: crumb.path == "/" ? (rootLabel ?? "/") : crumb.label)
                                    .font(.subheadline)
                                    .fontWeight(crumb.path == nav.current ? .semibold : .regular)
                                    .foregroundStyle(crumb.path == nav.current ? .primary : .secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 6)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .id(crumb.path)
                        }
                    }
                }
                .onChange(of: nav.current) { _, path in
                    guard let path else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path, anchor: .trailing) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// The composer's + → 电脑上的文件: walk the Pal's folder (the assistant's
/// home for the assistant) a level at a time and pick a file; its path goes
/// into the message as a `[文件] <path>` line. Nothing is uploaded.
struct ComputerFilePicker: View {
    let scope: FileScope
    let pick: (String) -> Void
    let close: () -> Void

    @Environment(AppStore.self) private var store
    @StateObject private var level = DirectoryLevelStore()
    /// "/" is the scope's folder.
    @State private var nav = DirectoryPickerPath("/")
    @State private var root = FileTreeScreen.RootBox()

    private var rel: String { nav.current.map { $0 == "/" ? "" : String($0.dropFirst()) } ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            PickerLocationBar(nav: nav, rootLabel: root.path.map { ($0 as NSString).lastPathComponent }, go: go)
            Divider()
            list
        }
        .navigationTitle(Text("电脑上的文件", tableName: "Files"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .close, action: close).tint(.primary)
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: Binding(get: { level.showHidden }, set: { level.setShowHidden($0) })) {
                    Label { Text("显示隐藏的文件", tableName: "Files") } icon: { Image(systemName: "eye") }
                }
                .toggleStyle(.button)
                .tint(.primary)
            }
        }
        .task(id: scope) {
            let store = store
            let scope = scope
            let box = root
            level.bind { rel, hidden in
                let r = try await store.listFiles(scope, path: rel, showHidden: hidden)
                await MainActor.run { box.path = r.root }
                return DirectoryListResult(entries: r.entries.map { DirectoryEntry(name: $0.name, isDir: $0.isDir, size: $0.size) },
                                           truncated: r.truncated)
            }
            level.load("")
        }
        .accessibilityIdentifier("computer-file-picker")
    }

    @ViewBuilder private var list: some View {
        if let error = level.error, level.entries.isEmpty {
            ContentUnavailableView {
                Label { Text("打不开这个文件夹", tableName: "Files") } icon: { Image(systemName: "folder.badge.questionmark") }
            } description: { Text(verbatim: error) }
        } else if level.loading, level.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if level.entries.isEmpty {
                    Text("这个文件夹是空的", tableName: "Files").foregroundStyle(.secondary)
                }
                ForEach(level.entries, id: \.name) { e in
                    Button {
                        if e.isDir {
                            go { $0.enter(e.name) }
                        } else if let r = root.path {
                            pick(FilePaths.join(r, rel.isEmpty ? e.name : rel + "/" + e.name))
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: e.isDir ? "folder" : FileTreeRow.symbol(e.name))
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(verbatim: e.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            if e.isDir {
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            } else {
                                Text(verbatim: Copy.byteSize(e.size)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(minHeight: 30)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pick-row-\(e.name)")
                }
                if level.truncated {
                    Text("这里东西太多，只列出了一部分", tableName: "Files").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }

    private func go(_ move: (inout DirectoryPickerPath) -> Void) {
        var next = nav
        move(&next)
        guard next.current != nav.current, next.current != nil else { return }
        nav = next
        level.load(rel)
    }
}

/// 成果 → 打开文件夹…: walk the computer's folders from the home folder and
/// open the one you're in. It's remembered, and its tree opens in place.
struct FolderPicker: View {
    let opened: (OwnerFolder) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var level = DirectoryLevelStore()
    @State private var nav = DirectoryPickerPath()
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            PickerLocationBar(nav: nav, rootLabel: nil, go: go)
            Divider()
            list
            confirmBar
        }
        .navigationTitle(Text("打开文件夹", tableName: "Files"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .close) { dismiss() }.tint(.primary)
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: Binding(get: { level.showHidden }, set: { level.setShowHidden($0) })) {
                    Label { Text("显示隐藏的文件", tableName: "Files") } icon: { Image(systemName: "eye") }
                }
                .toggleStyle(.button)
                .tint(.primary)
            }
        }
        .task { await start() }
        .accessibilityIdentifier("folder-picker")
    }

    @ViewBuilder private var list: some View {
        if let error = level.error, level.entries.isEmpty {
            ContentUnavailableView {
                Label { Text("打不开这个文件夹", tableName: "Files") } icon: { Image(systemName: "folder.badge.questionmark") }
            } description: { Text(verbatim: error) }
        } else if level.loading, level.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if level.entries.isEmpty {
                    Text("里面没有文件夹", tableName: "Files").foregroundStyle(.secondary)
                }
                ForEach(level.entries, id: \.name) { e in
                    Button { go { $0.enter(e.name) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 22)
                            Text(verbatim: e.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 30)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("folder-row-\(e.name)")
                }
            }
            .listStyle(.plain)
        }
    }

    /// The folder you're in, and the one action: open it.
    private var confirmBar: some View {
        VStack(spacing: 8) {
            if let failure {
                Text(verbatim: failure).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                Task { await open() }
            } label: {
                Text(nav.displayName.map { String(localized: "打开「\($0)」", table: "Files") } ?? String(localized: "打开", table: "Files"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!nav.canConfirm || working)
            .accessibilityIdentifier("open-this-folder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func start() async {
        let store = store
        level.bind { path, hidden in
            let r = try await store.browseFolders(path: path, showHidden: hidden)
            return DirectoryListResult(entries: r.entries.map { DirectoryEntry(name: $0.name, isDir: true) }, truncated: r.truncated)
        }
        do {
            // Where the host's home folder is: it says, the first time.
            let home = try await store.browseFolders()
            nav.reset(home.path)
            level.load(home.path)
        } catch {
            level.fail(Copy.error(error))
        }
    }

    private func go(_ move: (inout DirectoryPickerPath) -> Void) {
        var next = nav
        move(&next)
        guard next.current != nav.current, let path = next.current else { return }
        nav = next
        failure = nil
        level.load(path)
    }

    private func open() async {
        guard let path = nav.selectedPath else { return }
        working = true
        defer { working = false }
        do {
            opened(try await store.addOwnerFolder(path: path))
        } catch {
            failure = Copy.error(error)
        }
    }
}

/// The composer's sheet for 电脑上的文件: the picked file's path goes into
/// the text as a `[文件] <path>` line (the marker the assistant and Pals read).
struct ComputerFileSheet: ViewModifier {
    @Binding var shown: Bool
    @Binding var draft: String
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(isPresented: $shown) {
            NavigationStack {
                ComputerFilePicker(scope: store.palID.map(FileScope.pal) ?? .palo, pick: { path in
                    shown = false
                    let line = "[文件] \(path)" // i18n-ok: the marker the model reads, as the host writes it
                    if draft.isEmpty || draft.hasSuffix("\n") { draft += line } else { draft += "\n" + line }
                }, close: { shown = false })
            }
            .environment(store)
            .presentationSizing(.form)
        }
    }
}
