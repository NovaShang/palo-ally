import PaloAllyKit
import SwiftUI

struct LibraryView: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// One box for both what it made and what was said. `-libraryQuery` prefills it.
    @State private var query = UserDefaults.standard.string(forKey: "libraryQuery") ?? ""
    @State private var hits: [ChatSearchHit] = []
    @State private var searching = false
    @State private var searchActive = false
    @FocusState private var fieldFocused: Bool
    /// 按时间 or 按文件夹; the last one used is kept (docs/files-prd.md).
    @AppStorage("libraryGrouping") private var grouping: LibraryGrouping = .time
    /// Folders folded shut in 按文件夹 (open by default).
    @State private var folded: Set<String> = []
    @Environment(\.placesAsColumns) private var asColumn
    /// In an agent's or a workspace's pane: whose items show first, and the
    /// 这个 agent (这个工作区) / 全部 choice.
    @Environment(\.libraryScope) private var scope
    @Environment(\.libraryOpensModal) private var opensModal
    @Environment(\.libraryOpensTab) private var opensTab
    @State private var onlyThisSession = true
    /// The phone's pane page: its glass bars hold the search, 这个 agent / 全部
    /// and 按时间 / 按文件夹, so the list shows none of its own.
    @Environment(\.paneChrome) private var chrome

    private var onlyThis: Bool { chrome?.onlyThisSession ?? onlyThisSession }
    /// The agents the list is narrowed to, if any.
    private var narrowedTo: Set<String>? { onlyThis ? scope.sources : nil }
    private var pinned: [Artifact] { store.pinnedArtifacts.made(byAnyOf: narrowedTo) }
    private var recent: [Artifact] { store.recentArtifacts.made(byAnyOf: narrowedTo) }

    private var trimmed: String { (chrome?.query ?? query).trimmingCharacters(in: .whitespacesAndNewlines) }

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
        // The phone's pane page has its own glass bars.
        .toolbar(chrome != nil ? .hidden : .automatic, for: .navigationBar)
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
        if chrome != nil {
            list
        } else if fieldInColumn {
            list.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索成果和对话", text: $query)
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
                            placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索成果和对话")
        }
    }

    // MARK: list

    @ViewBuilder private var artifactList: some View {
        if chrome == nil && (scope != .all || showsGrouping) { controls }
        if store.artifacts.isEmpty {
            ContentUnavailableView("这里还空着",
                                   systemImage: "books.vertical",
                                   description: Text("助理整理出来的东西——晨报、比价、表格、文档——都会放在这里。"))
                .listRowBackground(Color.clear)
        } else if pinned.isEmpty && recent.isEmpty && narrowedTo != nil {
            // This agent hasn't made any: one tap to everything.
            Section {
                Text(verbatim: scope.emptyLine).foregroundStyle(.secondary)
                Button { if let chrome { chrome.onlyThisSession = false } else { onlyThisSession = false } } label: {
                    HStack {
                        Text("看全部成果", tableName: "Library").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .tint(.primary)
                .accessibilityIdentifier("library-show-all")
            }
        }
        if !pinned.isEmpty {
            Section("置顶") {
                ForEach(pinned) { row($0) }
            }
        }
        switch grouping {
        case .time: timeline
        case .folder: folderGroups
        }
    }

    /// 按时间 / 按文件夹: when there is a list to arrange (not when this
    /// agent's is empty and only 看全部成果 shows).
    private var showsGrouping: Bool {
        !store.artifacts.isEmpty && !(pinned.isEmpty && recent.isEmpty && narrowedTo != nil)
    }

    /// The page's own first row, scrolling away with the list: in an agent's
    /// or a workspace's pane 这个 agent (这个工作区) / 全部 as a small menu,
    /// then 按时间 / 按文件夹 segmented, on one line.
    private var controls: some View {
        Section {
            HStack(spacing: 10) {
                if scope != .all {
                    Picker(selection: $onlyThisSession) {
                        Text(verbatim: scope.narrowedTitle).tag(true)
                        Text("全部", tableName: "Library").tag(false)
                    } label: {
                        Text("范围", tableName: "Library")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .tint(.primary)
                    .accessibilityIdentifier("library-source")
                }
                if showsGrouping {
                    Picker(selection: $grouping) {
                        Text("按时间", tableName: "Library").tag(LibraryGrouping.time)
                        Text("按文件夹", tableName: "Library").tag(LibraryGrouping.folder)
                    } label: {
                        Text("整理方式", tableName: "Library")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("library-grouping")
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        // A headerless first section still gets a section's gap above it: none, so the row sits first.
        .listSectionMargins(.top, 0)
    }

    // MARK: 按时间

    @ViewBuilder private var timeline: some View {
        ForEach(ArtifactGroups.days(recent)) { day in
            Section {
                ForEach(day.items) { row($0, detail: .time) }
            } header: {
                Text(verbatim: dayTitle(day.start))
            }
        }
    }

    /// 今天, 昨天, the weekday within the last week, else the date.
    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "今天", table: "Library") }
        if cal.isDateInYesterday(day) { return String(localized: "昨天", table: "Library") }
        let days = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: .now)).day ?? 0
        if days < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(day, equalTo: .now, toGranularity: .year) { return day.formatted(.dateTime.month().day()) }
        return day.formatted(.dateTime.year().month().day())
    }

    // MARK: 按文件夹

    @ViewBuilder private var folderGroups: some View {
        ForEach(ArtifactGroups.folders(recent)) { group in
            let name = group.isUngrouped ? String(localized: "其他", table: "Library") : group.name
            let open = !folded.contains(group.id)
            Section {
                if open {
                    ForEach(group.items) { row($0, detail: .updated) }
                }
            } header: {
                Button {
                    withAnimation(.snappy) {
                        if open { folded.insert(group.id) } else { folded.remove(group.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 14)
                        Text(verbatim: name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Text(verbatim: "\(group.items.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .textCase(nil)
                .accessibilityLabel(Text(verbatim: "\(name), \(group.items.count)"))
                .accessibilityValue(open ? String(localized: "已展开", table: "Library") : String(localized: "已折叠", table: "Library"))
                .accessibilityIdentifier("library-folder-\(group.id.isEmpty ? "none" : group.id)")
            }
        }
    }

    // MARK: search

    private var matchingArtifacts: [Artifact] {
        let q = trimmed.lowercased()
        return (pinned + recent).filter { a in
            a.title.lowercased().contains(q) || a.mainFile.lowercased().contains(q) || a.folder.lowercased().contains(q)
                || a.files.contains { $0.path.lowercased().contains(q) }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let artifacts = matchingArtifacts
        if !artifacts.isEmpty {
            Section("成果") {
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
        case .user: return hit.channel == .wechat ? String(localized: "我 · 微信") : String(localized: "我")
        case .assistant:
            let name = store.settings?.assistantName.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? String(localized: "助理") : name
        default: return String(localized: "提示")
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

    /// What a row says under its title: when it changed, or the time of day
    /// (and its folder) in the timeline.
    private enum Detail { case updated, time }

    private func detailText(_ a: Artifact, _ detail: Detail) -> String {
        switch detail {
        case .updated: return String(localized: "\(Copy.relative(a.updatedAt))更新")
        case .time:
            let time = a.updatedAt.msDate.formatted(.dateTime.hour().minute())
            return a.folder.isEmpty ? time : "\(time) · \(a.folder)"
        }
    }

    @ViewBuilder private func link<Label: View>(_ a: Artifact, @ViewBuilder label: () -> Label) -> some View {
        if opensModal {
            Button { PaneModal.artifact(a.id, model: model, store: store) } label: { label().contentShape(.rect) }
                .buttonStyle(.plain)
        } else if let opensTab {
            Button { opensTab(a.id) } label: { label().contentShape(.rect) }
                .buttonStyle(.borderless)
                .tint(.primary)
        } else {
            NavigationLink(value: a.id, label: label)
        }
    }

    private func row(_ a: Artifact, detail: Detail = .updated) -> some View {
        link(a) {
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
                    Text(verbatim: detailText(a, detail))
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
                Label(a.pinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: a.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                Task { try? await store.setPinned(a, !a.pinned) }
            } label: {
                Label(a.pinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: a.pinned ? "pin.slash" : "pin")
            }
        }
    }
}

/// How 成果 lays out what the assistant made.
enum LibraryGrouping: String {
    case time, folder
}

#Preview {
    let model = WindowModel.demo()
    NavigationStack { LibraryView() }
        .environment(model)
        .environment(model.store!)
}
