import PaloAllyKit
import SwiftUI

/// 最近的对话 (pals-prd §10): the Claude Code conversations that ended on the
/// computer in the last 30 days, by folder (the one used most lately first),
/// each with its title and when it was last used. Tapping one opens its
/// conversation, read only, with 接管 at the bottom (§14; `-demoRecentPick`
/// asks 接管 in its row instead, for snapshots). The system search field
/// narrows the list by title or folder.
struct RecentConversationsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    /// The conversation being asked about, and how far along.
    struct Asking: Equatable {
        enum Step: Equatable {
            /// 接管, asked first.
            case confirm
            /// Still open in a terminal after all: quit it there first.
            case waiting
            /// It didn't work: why.
            case failed(String)
        }
        var session: RecentSession
        var step: Step
    }
    @State private var asking: Asking?
    @State private var working = false
    @State private var query = ""
    @State private var loadError: String?

    var body: some View {
        let folders = store.recentFolders(matching: query)
        ScrollViewReader { proxy in
            List {
                ForEach(folders) { folder in
                    Section {
                        ForEach(folder.sessions) { row($0) }
                    } header: {
                        FolderHeader(folder: folder)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The same background empty, loading and full (an empty list draws none).
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            // The question in full view once it's open.
            .onChange(of: asking?.session.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id) }
            }
        }
        .overlay { emptyState(shown: folders.isEmpty) }
        .modifier(RecentSearch(shown: !(store.recentSessions ?? []).isEmpty, query: $query))
        .navigationTitle("最近的对话")
        .refreshable { await load() }
        // On opening, and again once the computer is reachable.
        .task(id: store.connection.isOnline) {
            await load()
            #if DEBUG
            // `-demoRecentPick <session id>`: the page opens asking 接管 for it (snapshots).
            if asking == nil, let sid = UserDefaults.standard.string(forKey: "demoRecentPick"),
               let s = store.recentSessions?.first(where: { $0.sessionId == sid }) {
                asking = Asking(session: s, step: .confirm)
            }
            #endif
        }
        .animation(.snappy, value: asking)
        .animation(.snappy, value: store.recentSessions)
    }

    // MARK: rows

    @ViewBuilder private func row(_ s: RecentSession) -> some View {
        if let asking, asking.session.id == s.id {
            ask(asking)
                .padding(.vertical, 6)
                .id(s.id)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("recent-asking-\(s.sessionId)")
        } else {
            Button {
                pick(s)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(s.displayTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Copy.relative(s.lastModified))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            .disabled(!store.connection.isOnline)
            .allowsHitTesting(!working)
            .id(s.id)
            .accessibilityIdentifier("recent-\(s.sessionId)")
        }
    }

    /// The row, asking: 接管「标题」？ with 算了 / 接管 (the theme color), or
    /// how it went when it didn't.
    @ViewBuilder private func ask(_ a: Asking) -> some View {
        switch a.step {
        case .confirm:
            ConfirmPanel(title: Copy.spaced(String(localized: "接管「\(a.session.displayTitle)」？")),
                         text: String(localized: "它会出现在 Pals 里，接着上次的地方聊。"),
                         action: String(localized: "接管"), working: working, destructive: false, glass: false,
                         cancel: { asking = nil }, confirm: { Task { await adopt(a.session) } })
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                Text(a.session.displayTitle).font(.headline)
                NoticePanel(text: String(localized: "它还在终端里开着。请在终端里输入 /exit 退出它，退出后自动接管。"), action: String(localized: "取消"), glass: false) {
                    asking = nil
                    Task { await store.cancelAdoption(sessionId: a.session.sessionId) }
                }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                Text(a.session.displayTitle).font(.headline)
                NoticePanel(text: Copy.spaced(String(localized: "没接管成：\(why)")), action: String(localized: "好"), glass: false) { asking = nil }
            }
        }
    }

    // MARK: empty, loading, old host

    @ViewBuilder private func emptyState(shown: Bool) -> some View {
        if shown {
            Group {
                if store.recentSupported == false {
                    line(String(localized: "电脑上的 PaloAlly 还不能列出这些，更新以后再来看。"))
                } else if store.recentSessions == nil {
                    if let loadError {
                        VStack(spacing: 12) {
                            line(String(localized: "没读到：\(loadError)"))
                            Button("再试一次") { Task { await load() } }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(.primary)
                        }
                    } else if !store.connection.isOnline {
                        line(String(localized: "连上电脑以后才能看到。"))
                    } else {
                        ProgressView()
                    }
                } else if store.recentSessions?.isEmpty == true {
                    line(String(localized: "最近 30 天里没有可以接管的对话。"))
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
            .accessibilityIdentifier("recent-empty")
    }

    // MARK: actions

    private func load() async {
        guard store.connection.isOnline else { return }
        do {
            try await store.refreshRecent()
            loadError = nil
        } catch {
            loadError = store.recentSupported == false ? nil : Copy.error(error)
        }
    }

    /// Opens its conversation, read only, with 接管 at the bottom (§14).
    private func pick(_ s: RecentSession) {
        model.openSession(s.sessionId)
    }

    private func adopt(_ s: RecentSession) async {
        working = true
        defer { working = false }
        do {
            switch try await store.adopt(sessionId: s.sessionId) {
            case .adopted(let pal):
                asking = nil
                model.openPal(pal.id)
            case .waitingForExit:
                // The Pal's page opens by itself once it's been quit (onAdopted).
                asking = Asking(session: s, step: .waiting)
            }
        } catch {
            store.clearAdoption(sessionId: s.sessionId)
            asking = Asking(session: s, step: .failed(Copy.error(error)))
        }
    }
}

/// A folder's section: its name, and the whole path lighter under it.
private struct FolderHeader: View {
    let folder: RecentFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(folder.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if folder.path != folder.name {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// The system search field, once there's something to search.
private struct RecentSearch: ViewModifier {
    let shown: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if shown {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索标题或目录")
        } else {
            content
        }
    }
}
