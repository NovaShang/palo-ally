import PaloAllyKit
import SwiftUI

/// 以前的 (workbench-prd §2): the sessions that ended, those put away for
/// lack of use, and the Claude Code conversations that ended on the computer
/// lately, by folder (the one used most lately first), each with its title and
/// when it was last used. Tapping one asks 接着聊 in its row (`-demoRecentPick
/// <session id>` opens it asked, for snapshots); it is a session again,
/// where it left off. The system search field narrows the list by title or
/// folder.
struct EarlierPage: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    /// The conversation being asked about, and how far along.
    struct Asking: Equatable {
        enum Step: Equatable {
            /// 接着聊, asked first.
            case confirm
            /// It didn't work (open in a terminal, too many sessions…): why.
            case failed(String)
        }
        var item: EarlierItem
        var step: Step
    }
    @State private var asking: Asking?
    @State private var working = false
    @State private var query = ""
    @State private var loadError: String?

    var body: some View {
        let folders = EarlierGroup.group(store.earlierItems ?? [], matching: query)
        ScrollViewReader { proxy in
            List {
                ForEach(folders) { folder in
                    Section {
                        ForEach(folder.items) { row($0) }
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
            .onChange(of: asking?.item.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id) }
            }
        }
        .overlay { emptyState(shown: folders.isEmpty) }
        .modifier(EarlierSearch(shown: !(store.earlierItems ?? []).isEmpty, query: $query))
        .navigationTitle("以前的")
        .refreshable { await load() }
        // On opening, and again once the computer is reachable.
        .task(id: store.connection.isOnline) {
            await load()
            #if DEBUG
            // `-demoRecentPick <session id>`: the page opens asking 接着聊 for it (snapshots).
            if asking == nil, let sid = UserDefaults.standard.string(forKey: "demoRecentPick"),
               let s = store.earlierItems?.first(where: { $0.sessionId == sid }) {
                asking = Asking(item: s, step: .confirm)
            }
            #endif
        }
        .animation(.snappy, value: asking)
        .animation(.snappy, value: store.earlierItems)
    }

    // MARK: rows

    @ViewBuilder private func row(_ s: EarlierItem) -> some View {
        if let asking, asking.item.id == s.id {
            ask(asking)
                .padding(.vertical, 6)
                .id(s.id)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("earlier-asking-\(s.sessionId)")
        } else {
            Button {
                pick(s)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(s.displayTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Copy.relative(s.at))
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
            .accessibilityIdentifier("earlier-\(s.sessionId)")
        }
    }

    /// The row, asking: 接着聊「标题」？ with 算了 / 接着聊 (the theme color),
    /// or how it went when it didn't.
    @ViewBuilder private func ask(_ a: Asking) -> some View {
        switch a.step {
        case .confirm:
            ConfirmPanel(title: Copy.spaced(String(localized: "接着聊「\(a.item.displayTitle)」？")),
                         text: String(localized: "它会回到会话里，接着上次的地方聊。"),
                         action: String(localized: "接着聊"), working: working, destructive: false, glass: false,
                         cancel: { asking = nil }, confirm: { Task { await resume(a.item) } })
        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                Text(a.item.displayTitle).font(.headline)
                NoticePanel(text: Copy.spaced(String(localized: "没能接着聊：\(why)")), action: String(localized: "好"), glass: false) { asking = nil }
            }
        }
    }

    // MARK: empty, loading, old host

    @ViewBuilder private func emptyState(shown: Bool) -> some View {
        if shown {
            Group {
                if store.earlierSupported == false {
                    line(String(localized: "电脑上的 PaloAlly 还不能列出这些，更新以后再来看。"))
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
                        line(String(localized: "连上电脑以后才能看到。"))
                    } else {
                        ProgressView()
                    }
                } else if store.earlierItems?.isEmpty == true {
                    line(String(localized: "还没有以前的会话。"))
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
            .accessibilityIdentifier("earlier-empty")
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

    /// Asks 接着聊 in the row.
    private func pick(_ s: EarlierItem) {
        asking = Asking(item: s, step: .confirm)
    }

    private func resume(_ s: EarlierItem) async {
        working = true
        defer { working = false }
        do {
            let pal = try await store.resume(s)
            asking = nil
            model.openPal(pal.id)
        } catch {
            asking = Asking(item: s, step: .failed(Copy.error(error)))
        }
    }
}

/// A folder's section: its name, and the whole path lighter under it.
private struct FolderHeader: View {
    let folder: EarlierGroup

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
private struct EarlierSearch: ViewModifier {
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
