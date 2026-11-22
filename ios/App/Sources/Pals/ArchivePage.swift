import PaloAllyKit
import SwiftUI

/// 已归档 (docs/workbench-design/structure-wireframe.html §5): the one place
/// for agents put away, newest first. Those archived by the owner, those put
/// away after a while unused (the same rule as before), and the Claude Code
/// conversations that ended on the computer (the last 30 days; the search
/// finds any of them, older ones too). Each row says why it's here; 拿回来
/// brings it back as an agent, where it left off, and opens it.
struct ArchivePage: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    @State private var query = ""
    /// What the host found for the query beyond the list (any conversation on the computer).
    @State private var found: [EarlierItem] = []
    @State private var searching = false
    @State private var workingKey: String?
    @State private var failure: (key: String, why: String)?
    @State private var loadError: String?

    var body: some View {
        let entries = HistoryList.entries(earlier: shownItems, live: [], query: query)
        List {
            ForEach(entries) { row($0) }
        }
        .listStyle(.insetGrouped)
        // The same background empty, loading and full (an empty list draws none).
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .overlay { emptyState(shown: entries.isEmpty) }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名字或文件夹")
        .navigationTitle("已归档")
        .refreshable { await load() }
        // On opening, and again once the computer is reachable.
        .task(id: store.connection.isOnline) { await load() }
        // The host looks through every conversation for the words, a moment after typing stops.
        .task(id: query) { await search() }
        .animation(.snappy, value: entries)
        .accessibilityIdentifier("archive-page")
    }

    /// The list, with what the search found beyond it.
    private var shownItems: [EarlierItem] {
        let listed = store.earlierItems ?? []
        let keys = Set(listed.map(\.key))
        return listed + found.filter { !keys.contains($0.key) }
    }

    /// Why it's here, in a few words.
    private func reason(_ item: EarlierItem) -> String {
        switch item.kind {
        case .ended: String(localized: "你归档的")
        case .folded: String(localized: "一阵子没用")
        default: String(localized: "终端里开过")
        }
    }

    @ViewBuilder private func row(_ entry: HistoryEntry) -> some View {
        if case .earlier(let item) = entry.source {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(verbatim: "\(entry.path) · \(reason(item)) · \(Copy.relative(item.at))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if workingKey == item.key {
                        ProgressView()
                    } else {
                        Button("拿回来") { Task { await bringBack(item) } }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(.primary)
                            .disabled(!store.connection.isOnline || workingKey != nil)
                            .accessibilityIdentifier("archive-back-\(item.sessionId)")
                    }
                }
                if let failure, failure.key == item.key {
                    Text(Copy.spaced(String(localized: "没能拿回来：\(failure.why)")))
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("archive-\(item.sessionId)")
        }
    }

    // MARK: empty, loading, old host

    @ViewBuilder private func emptyState(shown: Bool) -> some View {
        if shown {
            Group {
                if store.earlierSupported == false {
                    line(String(localized: "主机上的 Palo 还不能列出这些，更新以后再来看。"))
                } else if store.earlierItems == nil {
                    if let loadError {
                        VStack(spacing: 12) {
                            line(String(localized: "没读到：\(loadError)"))
                            Button("再试一次") { Task { await load() } }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(.primary)
                        }
                    } else if !store.connection.isOnline {
                        line(String(localized: "连上主机以后才能看到。"))
                    } else {
                        ProgressView()
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    line(String(localized: "还没有归档的 agent。归档的、一阵子没用的，和主机上的 Claude Code 对话都会在这里。"))
                } else if searching {
                    ProgressView()
                } else {
                    line(String(localized: "没有找到「\(query.trimmingCharacters(in: .whitespacesAndNewlines))」"))
                }
            }
            .padding(32)
        }
    }

    private func line(_ text: String) -> some View {
        Text(Copy.spaced(text))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("archive-empty")
    }

    // MARK: actions

    private func load() async {
        guard store.connection.isOnline else { return }
        do {
            try await store.refreshEarlier()
            loadError = nil
        } catch {
            loadError = store.earlierSupported == false ? nil : Copy.error(error)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            found = []
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, store.connection.isOnline, store.earlierSupported != false else { return }
        searching = true
        defer { searching = false }
        if let items = try? await store.searchArchive(q), !Task.isCancelled { found = items }
    }

    private func bringBack(_ item: EarlierItem) async {
        workingKey = item.key
        failure = nil
        defer { workingKey = nil }
        do {
            let pal = try await store.resume(item)
            found.removeAll { $0.sessionId == item.sessionId }
            model.openPal(pal.id)
        } catch {
            failure = (item.key, Copy.error(error))
        }
    }
}
