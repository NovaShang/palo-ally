import PaloAllyKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// One box for both what it made and what was said. `-libraryQuery` prefills it.
    @State private var query = UserDefaults.standard.string(forKey: "libraryQuery") ?? ""
    @State private var hits: [ChatSearchHit] = []
    @State private var searching = false
    @State private var searchActive = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.placesAsColumns) private var asColumn

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The Mac's window toolbar is shared by the conversation and the
    /// inspector, and the system search drawer stretches across both — so in
    /// the inspector there the field sits at the top of the column instead.
    private var fieldInColumn: Bool { asColumn && UIDevice.current.userInterfaceIdiom == .mac }

    var body: some View {
        searchable(List {
            if trimmed.isEmpty {
                artifactList
            } else {
                searchResults
            }
        })
        .navigationTitle("成果")
        // ⌘F
        .onChange(of: model.librarySearchRequested, initial: true) { _, requested in
            guard requested else { return }
            model.librarySearchRequested = false
            if fieldInColumn { fieldFocused = true } else { searchActive = true }
        }
        // Debounced: the conversation is searched on the computer.
        .task(id: trimmed) {
            guard !trimmed.isEmpty else { hits = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            if let found = try? await store.searchConversation(trimmed) { hits = found }
        }
        .refreshable { try? await store.refreshArtifacts() }
        .navigationDestination(for: String.self) { id in
            ArtifactDetailView(artifactID: id)
        }
    }

    @ViewBuilder private func searchable(_ list: some View) -> some View {
        if fieldInColumn {
            list.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索产出物和对话", text: $query)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("清除")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
            }
        } else {
            list.searchable(text: $query, isPresented: $searchActive,
                            placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索产出物和对话")
        }
    }

    // MARK: list

    @ViewBuilder private var artifactList: some View {
            if store.artifacts.isEmpty {
                ContentUnavailableView("这里还空着",
                                       systemImage: "books.vertical",
                                       description: Text("助理整理出来的东西——晨报、比价、表格、文档——都会放在这里。"))
                    .listRowBackground(Color.clear)
            }
            if !store.pinnedArtifacts.isEmpty {
                Section("置顶") {
                    ForEach(store.pinnedArtifacts) { row($0) }
                }
            }
            if !store.recentArtifacts.isEmpty {
                Section("最近更新") {
                    ForEach(store.recentArtifacts) { row($0) }
                }
            }
    }

    // MARK: search

    private var matchingArtifacts: [Artifact] {
        let q = trimmed.lowercased()
        return (store.pinnedArtifacts + store.recentArtifacts).filter { a in
            a.title.lowercased().contains(q) || a.mainFile.lowercased().contains(q)
                || a.files.contains { $0.path.lowercased().contains(q) }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let artifacts = matchingArtifacts
        if !artifacts.isEmpty {
            Section("产出物") {
                ForEach(artifacts) { row($0) }
            }
        }
        if !hits.isEmpty {
            Section("对话") {
                ForEach(hits) { hit in
                    Button { model.jumpToMessage(seq: hit.seq) } label: { hitRow(hit) }
                        .buttonStyle(.plain)
                }
            }
        }
        if artifacts.isEmpty && hits.isEmpty {
            if searching {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            } else {
                ContentUnavailableView.search(text: trimmed).listRowBackground(Color.clear)
            }
        }
    }

    private func hitRow(_ hit: ChatSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(speaker(hit)).font(.caption.weight(.medium))
                Text("· \(Copy.relative(hit.ts))").font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            Text(highlighted(hit.snippet))
                .font(.callout)
                .lineLimit(3)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("回到对话里的这一条")
    }

    private func speaker(_ hit: ChatSearchHit) -> String {
        switch hit.role {
        case .user: return hit.channel == .wechat ? "我 · 微信" : "我"
        case .assistant:
            let name = store.settings?.assistantName.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "助理" : name
        default: return "提示"
        }
    }

    /// The snippet with every occurrence of the query in bold, primary color;
    /// the rest secondary.
    private func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString(snippet)
        out.foregroundColor = .secondary
        let q = trimmed
        guard !q.isEmpty else { return out }
        var search = out.startIndex..<out.endIndex
        while let r = out[search].range(of: q, options: .caseInsensitive) {
            out[r].foregroundColor = .primary
            out[r].inlinePresentationIntent = .stronglyEmphasized
            search = r.upperBound..<out.endIndex
        }
        return out
    }

    private func row(_ a: Artifact) -> some View {
        NavigationLink(value: a.id) {
            HStack(spacing: 12) {
                Image(systemName: a.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title.isEmpty ? a.mainFile : a.title)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(Copy.relative(a.updatedAt))更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if a.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { try? await store.setPinned(a, !a.pinned) }
            } label: {
                Label(a.pinned ? "取消置顶" : "置顶", systemImage: a.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                Task { try? await store.setPinned(a, !a.pinned) }
            } label: {
                Label(a.pinned ? "取消置顶" : "置顶", systemImage: a.pinned ? "pin.slash" : "pin")
            }
        }
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { LibraryView() }
        .environment(model)
        .environment(model.store!)
}
