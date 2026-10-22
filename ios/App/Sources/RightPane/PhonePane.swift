import PaloAllyFilePreview
import PaloAllyKit
import SafariServices
import SwiftUI

// The phone's right pane (workbench-prd §7): no tabs. One page with a
// segmented 成果 / 文件 control; anything opened from it, or from a path or
// link in a reply, is a full-screen modal that closes back to where it came
// from. Nothing is remembered.

/// Which half of the phone's pane page shows.
@MainActor @Observable
final class PhonePaneState {
    static let shared = PhonePaneState()
    enum Segment: Hashable { case library, files }
    var segment: Segment = .library
    /// Palo's 文件: the owner's home folder, or Palo's own.
    var paloFilesRoot: FileScope = .home
}

extension EnvironmentValues {
    /// 成果 inside the phone's pane: an item opens as a full-screen modal, not pushed.
    @Entry var libraryOpensModal: Bool = false
    /// The session whose items 成果 offers first (nil: Palo's, everything).
    @Entry var libraryPalID: String? = nil
}

/// Full-screen modals over whatever is on screen.
@MainActor
enum PaneModal {
    static func file(_ target: FileTarget, model: WindowModel, store: AppStore) {
        present(model: model, store: store) { close in
            FilePage(target: target, close: close)
        }
    }

    static func artifact(_ id: String, model: WindowModel, store: AppStore) {
        present(model: model, store: store) { close in
            ArtifactDetailView(artifactID: id)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close, action: close) } }
        }
    }

    /// A page in the system's browser view. false: not a web address.
    @discardableResult
    static func web(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let top = QuickLookPresenter.topController() else { return false }
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .fullScreen
        top.present(safari, animated: true)
        return true
    }

    private static func present<Content: View>(model: WindowModel, store: AppStore,
                                               @ViewBuilder _ content: @escaping (@escaping () -> Void) -> Content) {
        guard let top = QuickLookPresenter.topController(in: model.scene) else { return }
        weak var presented: UIViewController?
        let close: () -> Void = { presented?.dismiss(animated: true) }
        let page = NavigationStack { content(close) }
            .environment(model)
            .environment(store)
        let controller = UIHostingController(rootView: page)
        controller.modalPresentationStyle = .fullScreen
        presented = controller
        top.present(controller, animated: true)
    }
}

/// What the phone's pane page holds in its glass bars for the list under
/// them (`LibraryView`, `FileTreeScreen`): the search text and, in a
/// session's 成果, 这个会话 / 全部.
@MainActor @Observable
final class PaneChrome {
    var query = ""
    var onlyThisSession = true
}

extension EnvironmentValues {
    /// Set inside the phone's pane page; nil elsewhere (the lists keep their own controls).
    @Entry var paneChrome: PaneChrome? = nil
}

/// The pane as one page on a phone (docs/workbench-design/pane-phone-glass.html):
/// the list runs to both edges under floating glass. At the top, ✕ and one
/// capsule for what is shown (这个会话 / 全部 in a session's 成果, 按时间 /
/// 按文件夹 in Palo's, the folder's name in 文件); at the bottom, a glass tab
/// bar of 成果 and 文件, and a round search button that turns the bar into
/// the search field.
struct PhonePane: View {
    let key: String
    var activeSessionID: String? = nil
    let onClose: () -> Void

    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var chrome = PaneChrome()
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @AppStorage("libraryGrouping") private var grouping: LibraryGrouping = .time
    private var state: PhonePaneState { .shared }

    var body: some View {
        let resolved = RightPaneScope.resolve(key: key, activeSessionID: activeSessionID, store: store)
        // Palo's 文件 shows the folder picked in its capsule.
        let scope = resolved.kind == .palo && state.segment == .files ? state.paloFilesRoot : resolved
        let palID = RightPaneScope.palID(of: resolved)
        Group {
            switch state.segment {
            case .library:
                LibraryTab()
                    .environment(\.libraryOpensModal, true)
                    .environment(\.libraryPalID, palID)
            case .files:
                NavigationStack {
                    FileTreeScreen(scope: scope, onOpenFile: { PaneModal.file($0, model: model, store: store) })
                        .toolbar(.hidden, for: .navigationBar)
                }
                .id(scope)
            }
        }
        .environment(\.paneChrome, chrome)
        // On the list only: on the whole page it would cover the bars' own identifiers.
        .accessibilityIdentifier("right-pane")
        .toolbar(.hidden, for: .navigationBar)
        // The lists run under the glass, their first and last rows clear of it
        // (the bars float over the lists' own navigation stacks, so margins, not insets).
        .contentMargins(.top, 56, for: .scrollContent)
        .contentMargins(.bottom, 80, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay(alignment: .top) { topBar(palID: palID, scope: scope) }
        .overlay(alignment: .bottom) { bottomBar }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // A new segment starts without a search.
        .onChange(of: state.segment) { endSearch() }
    }

    // MARK: top

    private func topBar(palID: String?, scope: FileScope) -> some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(String(localized: "关闭侧栏", table: "Files"))
            Spacer(minLength: 8)
            capsule(palID: palID, scope: scope)
            Spacer(minLength: 8)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func capsule(palID: String?, scope: FileScope) -> some View {
        switch state.segment {
        case .library where palID != nil:
            capsuleMenu(chrome.onlyThisSession ? String(localized: "这个会话", table: "Library") : String(localized: "全部", table: "Library")) {
                Picker(selection: $chrome.onlyThisSession) {
                    Text("这个会话", tableName: "Library").tag(true)
                    Text("全部", tableName: "Library").tag(false)
                } label: { EmptyView() }
            }
            .accessibilityIdentifier("library-source")
        case .library:
            capsuleMenu(grouping == .time ? String(localized: "按时间", table: "Library") : String(localized: "按文件夹", table: "Library")) {
                Picker(selection: $grouping) {
                    Text("按时间", tableName: "Library").tag(LibraryGrouping.time)
                    Text("按文件夹", tableName: "Library").tag(LibraryGrouping.folder)
                } label: { EmptyView() }
            }
            .accessibilityIdentifier("library-grouping")
        case .files where scope.kind == .pal:
            Text(folderName(scope))
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)
        case .files:
            @Bindable var state = state
            capsuleMenu(folderName(scope)) {
                Picker(selection: $state.paloFilesRoot) {
                    Text("用户目录", tableName: "Files").tag(FileScope.home)
                    Text("Palo 的文件", tableName: "Files").tag(FileScope.palo)
                } label: { EmptyView() }
            }
            .accessibilityIdentifier("files-root")
        }
    }

    private func capsuleMenu<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func folderName(_ scope: FileScope) -> String {
        switch scope.kind {
        case .pal: return scope.id.flatMap { store.pal(id: $0) }.map { ($0.cwd as NSString).lastPathComponent } ?? ""
        case .home: return String(localized: "用户目录", table: "Files")
        default: return String(localized: "Palo 的文件", table: "Files")
        }
    }

    // MARK: bottom

    @ViewBuilder private var bottomBar: some View {
        @Bindable var chrome = chrome
        HStack(spacing: 10) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(state.segment == .library ? String(localized: "搜索成果", table: "Library")
                                                        : String(localized: "搜文件名", table: "Files"),
                              text: $chrome.query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("pane-search-field")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .glassEffect(.regular, in: .capsule)
                Button(action: endSearch) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .frame(width: 52, height: 52).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(String(localized: "取消搜索", table: "Files"))
            } else {
                HStack(spacing: 0) {
                    tab(.library, title: Text("成果", tableName: "Files"), icon: "square.stack")
                    tab(.files, title: Text("文件", tableName: "Files"), icon: "folder")
                }
                .padding(5)
                .glassEffect(.regular, in: .capsule)
                Button {
                    searching = true
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium))
                        .frame(width: 62, height: 62).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(String(localized: "搜索", table: "Files"))
                .accessibilityIdentifier("pane-search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .animation(.snappy, value: searching)
    }

    private func tab(_ segment: PhonePaneState.Segment, title: Text, icon: String) -> some View {
        let on = state.segment == segment
        return Button {
            state.segment = segment
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 19))
                title.font(.caption2.weight(on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Color.primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background { if on { Capsule().fill(.fill.secondary) } }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(segment == .library ? "pane-tab-library" : "pane-tab-files")
    }

    private func endSearch() {
        chrome.query = ""
        searching = false
        searchFocused = false
    }
}
