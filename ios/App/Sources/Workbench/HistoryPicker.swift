import PaloAllyKit
import SwiftUI

/// 从历史记录继续… (docs/workbench-design/pane-history.html §4): one
/// searchable list, newest first, of everything that can be picked up again,
/// each row marked with its kind: sessions that just ended, those put away,
/// Claude Code sessions running in the terminal now, and older terminal
/// conversations. Picking an
/// ended, put-away or older one resumes it (`pals.resume`); picking a running
/// one adopts it (in place, with the wait for the terminal to quit), and the
/// session opens.
struct HistoryPicker: View {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    @State private var query = ""
    @State private var workingKey: String?
    @State private var failure: (key: String, why: String)?
    @State private var loadError: String?

    var body: some View {
        let earlier = store.earlierItems
        let entries = HistoryList.entries(earlier: earlier ?? [], live: store.otherSessions, query: query)
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .overlay { emptyState(shown: entries.isEmpty) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或目录")
            .navigationTitle("从历史记录继续")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                        .tint(.primary)
                }
            }
            .refreshable { await load() }
            .task(id: store.connection.isOnline) { await load() }
            .animation(.snappy, value: entries)
            .animation(.snappy, value: store.adoptions)
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .accessibilityIdentifier("history-picker")
    }

    /// The row's kind, as a small tag after its title.
    private func tag(_ kind: HistoryGroup.Kind) -> some View {
        Group {
            switch kind {
            case .ended: Text("已结束")
            case .folded: Text("收起来的")
            case .live: Text("终端里开着")
            case .older: Text("更早的")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.fill.tertiary, in: .capsule)
        .fixedSize()
    }

    @ViewBuilder private func row(_ entry: HistoryEntry) -> some View {
        switch entry.source {
        case .live(let session):
            VStack(alignment: .leading, spacing: 4) {
                tag(.live)
                OtherSessionRow(session: session, showsFolder: true, onAdopted: { isPresented = false })
            }
        case .earlier(let item):
            VStack(alignment: .leading, spacing: 6) {
                Button { Task { await resume(item) } } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.displayTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                tag(entry.kind)
                            }
                            Text(entry.path)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if workingKey == item.key {
                            ProgressView()
                        } else {
                            Text(Copy.relative(item.at))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(.rect)
                }
                .tint(.primary)
                .disabled(!store.connection.isOnline || workingKey != nil)
                .accessibilityIdentifier("history-\(item.sessionId)")
                if let failure, failure.key == item.key {
                    Text(Copy.spaced(String(localized: "没能接着聊：\(failure.why)")))
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private func emptyState(shown: Bool) -> some View {
        if shown {
            Group {
                if store.earlierItems == nil && store.otherSessions.isEmpty {
                    if let loadError {
                        line(String(localized: "没读到：\(loadError)"))
                    } else if !store.connection.isOnline {
                        line(String(localized: "连上电脑以后才能看到。"))
                    } else if store.earlierSupported == false {
                        line(String(localized: "电脑上的 PaloAlly 还不能列出这些，更新以后再来看。"))
                    } else {
                        ProgressView()
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    line(String(localized: "还没有可以继续的会话。电脑上开着的 Claude Code 也会出现在这里。"))
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
            .accessibilityIdentifier("history-empty")
    }

    private func load() async {
        guard store.connection.isOnline else { return }
        do {
            async let pals: Void = store.refreshPals()
            try await store.refreshEarlier()
            try? await pals
            loadError = nil
        } catch {
            loadError = store.earlierSupported == false ? nil : Copy.error(error)
        }
    }

    private func resume(_ item: EarlierItem) async {
        workingKey = item.key
        failure = nil
        defer { workingKey = nil }
        do {
            let pal = try await store.resume(item)
            isPresented = false
            model.openPal(pal.id)
        } catch {
            failure = (item.key, Copy.error(error))
        }
    }
}

extension View {
    /// The 从历史记录继续… sheet, shown while `store.historyPickerPresented` is set.
    func historyPicker() -> some View { modifier(HistoryPickerSheet()) }
}

private struct HistoryPickerSheet: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        content.sheet(isPresented: $store.historyPickerPresented) {
            HistoryPicker(isPresented: $store.historyPickerPresented)
                .environment(model)
                .environment(store)
        }
    }
}
