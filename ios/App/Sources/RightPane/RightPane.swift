import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI

/// The pane at the right of a session, a workspace or Palo (workbench-prd §7):
/// a row of tabs on glass, and the tab's page under it. The first tab is
/// pinned (成果 beside Palo, 文件 elsewhere); 文件, files, and web pages open
/// as tabs after it. Which tabs are open, which shows, and whether the pane is
/// open is kept on the computer per `key` (`PaneTabsKey`), so every device
/// shows the same one.
///
/// Wide screens set it beside the content (A4b hooks that); on a phone use
/// `.rightPaneCover(...)` to show the same view full screen.
struct RightPane: View {
    /// `PaneTabsKey.palo`, `.session(id)` or `.workspace(id)`.
    let key: String
    /// A workspace's files are its active tile's session's.
    var activeSessionID: String? = nil
    /// Phone: the pane is a cover and closes by being dismissed.
    var onClose: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var pages = WebTabPages()
    @State private var pageByTab: [Int: WebTabPage] = [:]

    private var hub: PaneTabsHub { PaneTabsHub.shared(for: store) }
    private var state: TabsState { hub.state(for: key) }

    /// Where the files tab and previews read from.
    private var scope: FileScope {
        if key == PaneTabsKey.palo { return .palo }
        if key.hasPrefix("pal:") { return .pal(String(key.dropFirst(4))) }
        if key.hasPrefix("ws:") {
            let wsID = String(key.dropFirst(3))
            let members = store.workspace(id: wsID)?.memberIds ?? []
            if let id = activeSessionID ?? members.first { return .pal(id) }
        }
        return .palo
    }

    var body: some View {
        VStack(spacing: 0) {
            RightPaneTabBar(
                tabs: state.tabs, active: state.active, key: key, pages: pageByTab,
                select: { hub.activate(key, at: $0) },
                close: { hub.close(key, at: $0) },
                addFiles: { hub.openFiles(key) },
                addLibrary: { hub.openLibrary(key) },
                addWeb: { hub.openWeb(key, url: "") },
                closePane: { if let onClose { onClose() } else { hub.setOpen(key, false) } })
            content
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .environment(\.placesAsColumns, true)
        .task(id: store.connection.isOnline) { if store.connection.isOnline { await hub.load() } }
        .onChange(of: state.tabs, initial: true) { _, tabs in pageByTab = pages.reconcile(tabs) }
        .accessibilityIdentifier("right-pane")
    }

    // The web pages stay in the tree, hidden, so they keep their place;
    // anything else is made when its tab is shown.
    private var content: some View {
        let active = state.activeTab
        let activePage = pageByTab[state.active]
        return VStack(spacing: 0) {
            if let activePage, active?.kind == PaneTab.web {
                WebAddressBar(page: activePage) { text in
                    if let url = activePage.go(text) {
                        activePage.startURL = url
                        hub.retargetWeb(key, at: state.active, url: url)
                    }
                }
            }
            ZStack {
                ForEach(pages.pages, id: \.startURLIdentity) { page in
                    let shown = page === activePage && active?.kind == PaneTab.web
                    WebTabHost(page: page)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                }
                if let active, active.kind != PaneTab.web { other(active) }
            }
        }
    }

    @ViewBuilder private func other(_ tab: PaneTab) -> some View {
        switch tab.kind {
        case PaneTab.library:
            LibraryTab()
        case PaneTab.files:
            NavigationStack {
                FileTreeScreen(scope: scope, close: { if let onClose { onClose() } else { hub.setOpen(key, false) } },
                               onOpenFile: { hub.openPreview(key, path: $0.path) })
                    .modifier(InContentNavigationBar())
            }
            .id(scope)
        case PaneTab.preview:
            let index = state.active
            NavigationStack {
                FilePage(target: FileTarget(scope: scope, path: tab.path ?? ""), close: { hub.close(key, at: index) })
                    .modifier(InContentNavigationBar())
            }
            .id(tab)
        default:
            ContentUnavailableView(String(localized: "这个标签打不开", table: "Files"), systemImage: "questionmark.square.dashed")
        }
    }
}

/// 成果: the list with its items pushed over it, or a folder's tree in its place.
private struct LibraryTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let scope = model.filesPanel {
            FilesPanel(scope: scope)
        } else {
            NavigationStack(path: $model.libraryPath) {
                LibraryView()
                    .modifier(InContentNavigationBar())
                    .macPageTop(String(localized: "成果"))
            }
        }
    }
}

private extension WebTabPage {
    var startURLIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}

// MARK: - the tab row

private struct RightPaneTabBar: View {
    let tabs: [PaneTab]
    let active: Int
    let key: String
    let pages: [Int: WebTabPage]
    let select: (Int) -> Void
    let close: (Int) -> Void
    let addFiles: () -> Void
    let addLibrary: () -> Void
    let addWeb: () -> Void
    let closePane: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                            tabButton(i, tab)
                        }
                    }
                    .padding(4)
                }
                .glassEffect(.regular, in: .capsule)
                Menu {
                    if !tabs.contains(where: { $0.kind == PaneTab.files }) {
                        Button(action: addFiles) { Label(String(localized: "文件", table: "Files"), systemImage: "folder") }
                    }
                    if !tabs.contains(where: { $0.kind == PaneTab.library }) {
                        Button(action: addLibrary) { Label(String(localized: "成果"), systemImage: "square.grid.2x2") }
                    }
                    Button(action: addWeb) { Label(String(localized: "网页", table: "Files"), systemImage: "globe") }
                } label: {
                    Image(systemName: "plus").frame(width: 32, height: 32).contentShape(.circle)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(String(localized: "新标签", table: "Files"))
                Button(action: closePane) {
                    Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(String(localized: "关闭侧栏", table: "Files"))
            }
            .font(.system(size: 13, weight: .semibold))
            .tint(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(_ i: Int, _ tab: PaneTab) -> some View {
        let isActive = i == active
        // Select and close are sibling buttons: a tap over a nested close button would swallow it.
        return HStack(spacing: 0) {
            Button { select(i) } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon(tab)).font(.system(size: 11)).foregroundStyle(.secondary)
                    TabTitle(tab: tab, page: pages[i])
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, i == 0 ? 10 : 4)
                .frame(height: 28)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            if i > 0 {
                Button { close(i) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "关闭标签", table: "Files"))
            }
        }
        .frame(maxWidth: 180)
        .background(isActive ? AnyShapeStyle(.primary.opacity(0.12)) : AnyShapeStyle(.clear), in: .capsule)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func icon(_ tab: PaneTab) -> String {
        switch tab.kind {
        case PaneTab.library: "square.grid.2x2"
        case PaneTab.files: "folder"
        case PaneTab.preview: "doc.text"
        case PaneTab.web: "globe"
        default: "questionmark.square"
        }
    }
}

private struct TabTitle: View {
    let tab: PaneTab
    let page: WebTabPage?

    var body: some View {
        switch tab.kind {
        case PaneTab.library: Text(String(localized: "成果"))
        case PaneTab.files: Text(String(localized: "文件", table: "Files"))
        case PaneTab.preview: Text(verbatim: ((tab.path ?? "") as NSString).lastPathComponent)
        case PaneTab.web:
            if let page { LiveTitle(page: page, fallback: tab.url ?? "") } else { Text(verbatim: WebAddress.label(for: tab.url ?? "")) }
        default: Text(verbatim: tab.kind)
        }
    }

    private struct LiveTitle: View {
        @ObservedObject var page: WebTabPage
        let fallback: String
        var body: some View {
            if !page.title.isEmpty { Text(verbatim: page.title) }
            else if !fallback.isEmpty { Text(verbatim: WebAddress.label(for: fallback)) }
            else { Text(String(localized: "新网页", table: "Files")) }
        }
    }
}

// MARK: - the address field

private struct WebAddressBar: View {
    @ObservedObject var page: WebTabPage
    let submit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { page.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!page.canGoBack)
                .accessibilityLabel(String(localized: "后退", table: "Files"))
            Button { page.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!page.canGoForward)
                .accessibilityLabel(String(localized: "前进", table: "Files"))
            TextField(String(localized: "输入网址或搜索", table: "Files"), text: $text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit { submit(text); focused = false }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .glassEffect(.regular, in: .capsule)
            Button { page.reloadOrStop() } label: { Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise") }
                .accessibilityLabel(String(localized: "刷新", table: "Files"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear { text = page.address.isEmpty ? page.startURL : page.address; if page.startURL.isEmpty && page.address.isEmpty { focused = true } }
        .onChange(of: page.address) { _, a in if !focused, !a.isEmpty { text = a } }
    }
}

// MARK: - the phone's cover

extension View {
    /// Phone: the pane full screen over this view, shown while `isPresented`.
    func rightPaneCover(isPresented: Binding<Bool>, key: String, activeSessionID: String? = nil) -> some View {
        modifier(RightPaneCover(isPresented: isPresented, key: key, activeSessionID: activeSessionID))
    }
}

private struct RightPaneCover: ViewModifier {
    @Binding var isPresented: Bool
    let key: String
    let activeSessionID: String?
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            RightPane(key: key, activeSessionID: activeSessionID, onClose: { isPresented = false })
                .environment(model)
                .environment(store)
        }
    }
}

#if DEBUG
#Preview("Right pane, session") {
    let model = AppModel.demo()
    RightPane(key: PaneTabsKey.session("pal-site"))
        .environment(model)
        .environment(model.store!)
        .task {
            let hub = PaneTabsHub.shared(for: model.store!)
            hub.openPreview(PaneTabsKey.session("pal-site"), path: "README.md")
            hub.openWeb(PaneTabsKey.session("pal-site"), url: "https://example.com")
        }
}

#Preview("Right pane, Palo") {
    let model = AppModel.demo()
    RightPane(key: PaneTabsKey.palo)
        .environment(model)
        .environment(model.store!)
}
#endif
