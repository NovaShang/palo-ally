import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI

/// The pane at the right of a session, a workspace or Palo (workbench-prd §7):
/// a row of tabs on glass, and the tab's page under it. The first two tabs
/// are pinned, 成果 and 文件; files and web pages open as tabs after them. Which tabs are open, which shows, and whether the pane is
/// open is kept on the computer per `key` (`PaneTabsKey`), so every device
/// shows the same one; whether it is open is each window's own once it has
/// opened or closed it (`WindowModel.editPane`).
///
/// Wide screens set it beside the content; on a phone `.rightPaneCover(...)`
/// shows `PhonePane` instead (no tabs, modal previews).
struct RightPane: View {
    /// `PaneTabsKey.palo`, `.session(id)` or `.workspace(id)`.
    let key: String
    /// A workspace's files are its active tile's session's.
    var activeSessionID: String? = nil
    /// Phone: the pane is a cover and closes by being dismissed.
    var onClose: (() -> Void)? = nil

    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var pages = WebTabPages()
    @State private var pageByTab: [Int: WebTabPage] = [:]

    private var hub: PaneTabsHub { PaneTabsHub.shared(for: store) }
    private var state: TabsState { hub.state(for: key) }

    /// Where the files tab and previews read from.
    private var scope: FileScope { RightPaneScope.resolve(key: key, activeSessionID: activeSessionID, store: store) }

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("RightPane")
        #endif
        VStack(spacing: 0) {
            RightPaneTabBar(
                tabs: state.tabs, active: state.active, key: key, pages: pageByTab,
                select: { hub.activate(key, at: $0) },
                close: { hub.close(key, at: $0) },
                addWeb: { model.editPane(key) { $0.openWeb(key, url: "") } },
                closePane: { if let onClose { onClose() } else { model.editPane(key) { $0.setOpen(key, false) } } })
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
        // The web tab's address is its chip in the row above (no row of its own).
        return ZStack {
            ForEach(pages.pages, id: \.startURLIdentity) { page in
                let shown = page === activePage && active?.kind == PaneTab.web
                WebTabHost(page: page)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
            if let active, active.kind != PaneTab.web { other(active) }
        }
        // A page's own controls float in it, at the bottom (a file's ⋯ is at its top).
        .overlay(alignment: .bottom) {
            if let activePage, active?.kind == PaneTab.web {
                let index = state.active
                WebPageControls(page: activePage) { text in
                    guard let url = activePage.go(text) else { return }
                    activePage.startURL = url
                    hub.retargetWeb(key, at: index, url: url)
                }
                .id(ObjectIdentifier(activePage))
            }
        }
    }

    @ViewBuilder private func other(_ tab: PaneTab) -> some View {
        switch tab.kind {
        case PaneTab.library:
            LibraryTab().environment(\.libraryPalID, RightPaneScope.palID(of: scope))
        case PaneTab.files:
            NavigationStack {
                FileTreeScreen(scope: scope, close: { if let onClose { onClose() } else { model.editPane(key) { $0.setOpen(key, false) } } },
                               onOpenFile: { file in model.editPane(key) { $0.openPreview(key, path: file.absolute ?? file.path) } })
                    .modifier(InContentNavigationBar())
            }
            .id(scope)
        case PaneTab.preview:
            // An absolute path reads from anywhere on the computer, so a
            // workspace's preview stays on its file whichever pane is active;
            // a tab kept before (relative) reads from the pane's files.
            // The tab's chip names the file: no bar of its own, its actions in a ⋯.
            let index = state.active
            let path = tab.path ?? ""
            FilePage(target: FileTarget(scope: tab.isAbsolutePreview ? .root : scope, path: path),
                     close: { hub.close(key, at: index) }, inPane: true,
                     fallbackScope: tab.isAbsolutePreview ? scope : nil)
                .id(tab)
        default:
            ContentUnavailableView(String(localized: "这个标签打不开", table: "Files"), systemImage: "questionmark.square.dashed")
        }
    }
}

/// Where a pane's files are: Palo's computer files, a session's folder, or
/// (a workspace) the active tile's session's.
enum RightPaneScope {
    @MainActor
    static func resolve(key: String, activeSessionID: String?, store: AppStore) -> FileScope {
        if key == PaneTabsKey.palo { return .palo }
        if key.hasPrefix("pal:") { return .pal(String(key.dropFirst(4))) }
        if key.hasPrefix("ws:") {
            let wsID = String(key.dropFirst(3))
            let members = store.workspace(id: wsID)?.memberIds ?? []
            // Palo's pane in use: Palo's files.
            if activeSessionID == LayoutTree.paloPane { return .palo }
            if let id = activeSessionID ?? members.first { return .pal(id) }
        }
        return .palo
    }

    /// The session whose 成果 lead; nil for Palo.
    static func palID(of scope: FileScope) -> String? { scope.kind == .pal ? scope.id : nil }
}

/// 成果: the list with its items pushed over it, or a folder's tree in its place.
struct LibraryTab: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let scope = model.filesPanel {
            FilesPanel(scope: scope)
        } else {
            NavigationStack(path: $model.libraryPath) {
                LibraryView()
                    .modifier(InContentNavigationBar())
                    // The Mac: the pane's tabs already say 成果 (no second title).
                    .macBarHidden()
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
    let addWeb: () -> Void
    let closePane: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                tabStrip
                Button(action: addWeb) {
                    Image(systemName: "plus").frame(width: 32, height: 32).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(String(localized: "新网页", table: "Files"))
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

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                        tabButton(i, tab).id(i)
                    }
                }
                .padding(4)
            }
            // The shown tab stays in sight in a narrow pane.
            .onChange(of: active, initial: true) { _, i in withAnimation(.snappy) { proxy.scrollTo(i) } }
        }
        .glassEffect(.regular, in: .capsule)
    }

    private func tabButton(_ i: Int, _ tab: PaneTab) -> some View {
        let isActive = i == active
        let page = pages[i]
        let isWeb = tab.kind == PaneTab.web
        // Select and close are sibling buttons: a tap over a nested close button would swallow it.
        return HStack(spacing: 0) {
            Button { select(i) } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon(tab)).font(.system(size: 11)).foregroundStyle(.secondary)
                    TabTitle(tab: tab, page: page)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, i < PaneTabsKey.pinnedCount ? 10 : 4)
                .frame(height: 28)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(isWeb ? (page?.address ?? tab.url ?? "") : (tab.path ?? ""))
            if i >= PaneTabsKey.pinnedCount {
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
        .contentShape(.capsule)
        .contextMenu { if i >= PaneTabsKey.pinnedCount { menu(i, tab, page: page) } }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// A file's or a page's actions, on its chip.
    @ViewBuilder private func menu(_ i: Int, _ tab: PaneTab, page: WebTabPage?) -> some View {
        if tab.kind == PaneTab.web {
            let address = page.map { $0.address.isEmpty ? $0.startURL : $0.address } ?? tab.url ?? ""
            if let url = URL(string: address), !address.isEmpty {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label { Text("在浏览器中打开", tableName: "Files") } icon: { Image(systemName: "safari") }
                }
                Button {
                    UIPasteboard.general.string = address
                } label: {
                    Label { Text("拷贝网址", tableName: "Files") } icon: { Image(systemName: "link") }
                }
            }
            if let page {
                Button { page.reloadOrStop() } label: {
                    Label { Text("刷新", tableName: "Files") } icon: { Image(systemName: "arrow.clockwise") }
                }
            }
        } else if tab.kind == PaneTab.preview, let path = tab.path {
            Button {
                UIPasteboard.general.string = path
            } label: {
                Label { Text("拷贝路径", tableName: "Files") } icon: { Image(systemName: "doc.on.doc") }
            }
        }
        Divider()
        Button { close(i) } label: {
            Label { Text("关闭标签", tableName: "Files") } icon: { Image(systemName: "xmark") }
        }
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

/// A web tab's address being typed, in its controls: all of it selected;
/// Return loads it, Esc (or a click elsewhere) puts the site back.
private struct WebAddressField: View {
    @ObservedObject var page: WebTabPage
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(String(localized: "输入网址或搜索", table: "Files"), text: $text, selection: $selection)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit { submit(text) }
                .onKeyPress(.escape) { cancel(); return .handled }
                .accessibilityIdentifier("web-address")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxWidth: 420, minHeight: 32, maxHeight: 32)
        .onAppear {
            text = page.address.isEmpty ? page.startURL : page.address
            Task { @MainActor in
                focused = true
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            }
        }
        .onChange(of: focused) { was, now in if was, !now { cancel() } }
    }
}

/// A web tab's controls, a glass capsule floating at the page's bottom:
/// back, forward, reload, the site (a click types an address in its place:
/// Return loads, Esc or a click elsewhere puts it back) and ⋯. It slips away
/// while the page scrolls down and comes back on scrolling up or with the
/// pointer near the bottom.
private struct WebPageControls: View {
    @ObservedObject var page: WebTabPage
    let go: (String) -> Void
    @State private var editing = false

    private var address: String { page.address.isEmpty ? page.startURL : page.address }
    private var hidden: Bool { page.controlsHidden && !editing }

    var body: some View {
        ZStack(alignment: .bottom) {
            if hidden {
                // Where the capsule was: the pointer coming near brings it back.
                Color.clear
                    .frame(maxWidth: 320).frame(height: 44)
                    .contentShape(.rect)
                    .onHover { if $0 { page.controlsHidden = false } }
            }
            capsule
                .offset(y: hidden ? 64 : 0)
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .animation(.snappy(duration: 0.25), value: hidden)
        .animation(.snappy(duration: 0.25), value: editing)
        .onAppear {
            // A new tab has no address yet: it opens typing.
            if page.startURL.isEmpty && page.address.isEmpty { editing = true }
            #if DEBUG
            // `-demoPaneTabs address`: the address being typed.
            if UserDefaults.standard.string(forKey: "demoPaneTabs") == "address" { editing = true }
            #endif
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            if editing {
                WebAddressField(page: page, submit: { go($0); editing = false }, cancel: { editing = false })
            } else {
                button("chevron.backward", String(localized: "后退", table: "Files")) { page.webView.goBack() }
                    .disabled(!page.canGoBack)
                button("chevron.forward", String(localized: "前进", table: "Files")) { page.webView.goForward() }
                    .disabled(!page.canGoForward)
                button(page.isLoading ? "xmark" : "arrow.clockwise", String(localized: "刷新", table: "Files")) { page.reloadOrStop() }
                Button { editing = true } label: {
                    Group {
                        if address.isEmpty {
                            Text("输入网址或搜索", tableName: "Files").foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: WebAddress.label(for: address))
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 60, maxWidth: 220, minHeight: 32)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(address)
                .accessibilityIdentifier("web-site")
                menu
            }
        }
        // Compact: as wide as what it shows (a long site name stops at 220).
        .fixedSize(horizontal: !editing, vertical: false)
        .font(.system(size: 13, weight: .semibold))
        .tint(.primary)
        .padding(.horizontal, 4)
        .frame(height: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var menu: some View {
        Menu {
            if let url = URL(string: address), !address.isEmpty {
                Button { UIApplication.shared.open(url) } label: {
                    Label { Text("在浏览器中打开", tableName: "Files") } icon: { Image(systemName: "safari") }
                }
                Button { UIPasteboard.general.string = address } label: {
                    Label { Text("拷贝网址", tableName: "Files") } icon: { Image(systemName: "link") }
                }
                ShareLink(item: url) {
                    Label { Text("共享", tableName: "Files") } icon: { Image(systemName: "square.and.arrow.up") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .macMenuHitArea()
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .accessibilityLabel(String(localized: "更多", table: "Files"))
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    /// How far the page has been dragged back to the right by its left edge.
    @State private var drag: CGFloat = 0

    func body(content: Content) -> some View {
        // Slides in from the right like a pushed page (the owner's ask), not
        // up from the bottom; a swipe from its left edge takes it back.
        content.overlay {
            GeometryReader { proxy in
                if isPresented {
                    PhonePane(key: key, activeSessionID: activeSessionID, onClose: close)
                        .environment(model)
                        .environment(store)
                        .background(Color(.systemBackground).ignoresSafeArea())
                        .overlay(alignment: .leading) { edgeSwipe(width: proxy.size.width) }
                        .offset(x: drag)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.snappy(duration: 0.32), value: isPresented)
    }

    private func close() { isPresented = false }

    /// The page's left edge: dragged right, the page follows; let go past a
    /// third of the width (or flicked), it goes, else it springs back.
    private func edgeSwipe(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 20)
            .contentShape(.rect)
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { drag = max(0, $0.translation.width) }
                    .onEnded { v in
                        let gone = v.translation.width > width / 3 || v.predictedEndTranslation.width > width / 2
                        if gone {
                            withAnimation(.snappy(duration: 0.25)) { drag = width } completion: {
                                var t = Transaction(); t.disablesAnimations = true
                                withTransaction(t) { isPresented = false; drag = 0 }
                            }
                        } else {
                            withAnimation(.snappy) { drag = 0 }
                        }
                    })
    }
}

#if DEBUG
#Preview("Right pane, session") {
    let model = WindowModel.demo()
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
    let model = WindowModel.demo()
    RightPane(key: PaneTabsKey.palo)
        .environment(model)
        .environment(model.store!)
}
#endif
