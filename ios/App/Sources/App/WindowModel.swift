import Foundation
import Observation
import PaloAllyKit
import SwiftUI
import UIKit

/// One window's state: the computer it shows, the conversation, what's
/// pushed over it, its sheets, its sidebar and its right pane. iPads and the
/// Mac can have several windows, each with its own (one on the company Mac,
/// another on the home one); phones have one. What every window shares (the
/// computers, their connections, unsent words) is the `AppModel` it reads
/// through.
@MainActor
@Observable
final class WindowModel {
    let app: AppModel
    /// Where the Palo orb rests in this window (each window has its own coordinates).
    let orbHome = PaloOrbHome()
    /// An iPad in landscape with the sidebar away: the capsule is up, so the
    /// detail's own system sidebar button goes.
    var capsuleOnPad = false
    /// This window's scene (set once its view is in a window).
    @ObservationIgnored weak var scene: UIWindowScene?
    /// The Mac: which saved window this is (WindowMemory).
    @ObservationIgnored var windowID = ""
    /// The sidebar as this window last had it (nil: as the last one used left it).
    @ObservationIgnored var prefersSidebarCollapsed: Bool?

    init(app: AppModel, hostID: String? = nil) {
        self.app = app
        self.hostID = hostID
    }

    // MARK: the computer this window shows

    /// The computer this window shows (its assistant, conversations, color).
    /// Set when the window comes up (the one it was opened from, or the one
    /// used last) and by the switcher; nil only while nothing is paired.
    var hostID: String?

    /// `hostID` while it's still paired, else the one used last.
    var activeHostID: String? {
        if let id = hostID, app.stores[id] != nil { return id }
        return app.lastHostID
    }
    /// This window's assistant's store (nil when nothing is paired).
    var store: AppStore? { activeHostID.flatMap { app.stores[$0] } }
    var pairedHost: PairedHost? { activeHostID.flatMap { app.hosts[$0] } }
    /// The window takes its assistant's color.
    var currentTheme: AppTheme { activeHostID.map(app.theme(for:)) ?? .default }

    /// Replies and notices on another assistant (this window's own: none, it's on screen).
    func unreadCount(_ id: String) -> Int { id == activeHostID ? 0 : app.unreadCount(id) }

    /// Something is waiting on another assistant than this window's (the dot on the title).
    var othersNeedAttention: Bool {
        app.hostIDs.contains { $0 != activeHostID && (unreadCount($0) > 0 || pendingCount($0) > 0) }
    }

    /// Everything on this window's assistant counts as seen.
    func markSeen() {
        if let id = activeHostID { app.markSeen(id) }
    }

    /// Another assistant in this window (other windows keep theirs): it
    /// opens on its conversation (what it showed belonged to the one before).
    func switchTo(_ id: String) {
        guard app.hostIDs.contains(id) else { return }
        let changed = id != activeHostID
        if changed {
            markSeen()
            // Its pages' panes are that computer's.
            paneOpenHere = [:]
        }
        hostID = id
        app.use(id)
        if changed { showAssistantConversation() }
    }

    /// Unpairs this window's assistant.
    func unpair() async {
        if let id = activeHostID { await app.unpair(id) }
    }

    // MARK: shared, through the app

    typealias Mode = AppModel.Mode
    var mode: Mode { app.mode }
    var hostIDs: [String] { app.hostIDs }
    var hosts: [String: PairedHost] { app.hosts }
    var stores: [String: AppStore] { app.stores }
    var launch: LaunchOptions { app.launch }
    var secrets: SecretStore { app.secrets }
    var memoryRevision: Int {
        get { app.memoryRevision }
        set { app.memoryRevision = newValue }
    }
    var namingDone: Bool {
        get { app.namingDone }
        set { app.namingDone = newValue }
    }
    var clientKind: String { app.clientKind }
    var clientVersion: String { app.clientVersion }
    var buildStamp: String { app.buildStamp }
    var hasSeveralHosts: Bool { app.hasSeveralHosts }
    var iconTheme: AppTheme { app.iconTheme }
    /// A conversation's unsent words, on this window's computer.
    func draftBox(_ c: Conversation) -> DraftBox { app.draftBox(host: activeHostID, c) }
    func draftBinding(_ c: Conversation) -> Binding<String> { app.draftBinding(host: activeHostID, c) }
    func assistantLabel(_ id: String) -> String { app.assistantLabel(id) }
    func isOnline(_ id: String) -> Bool { app.isOnline(id) }
    func displayName(_ id: String) -> String { app.displayName(id) }
    func rename(_ id: String, to name: String) { app.rename(id, to: name) }
    func theme(for id: String) -> AppTheme { app.theme(for: id) }
    func setTheme(_ theme: AppTheme, for id: String) async throws { try await app.setTheme(theme, for: id) }
    func pendingCount(_ id: String) -> Int { app.pendingCount(id) }
    func startDemo() { app.startDemo() }
    func exitDemo() { app.exitDemo() }
    func unpair(_ id: String) async { await app.unpair(id) }
    static func deviceLabel() async -> String { await AppModel.deviceLabel() }
    static var urlScheme: String { AppModel.urlScheme }
    static func clearTemporaryFiles() { AppModel.clearTemporaryFiles() }

    /// Preview / demo constructor.
    static func demo() -> WindowModel {
        WindowModel(app: AppModel(launch: LaunchOptions(demo: true, screen: nil, tab: nil)))
    }

    // MARK: navigation
    // Standard iOS navigation (pals-prd §2): a list (the assistant, its Pals,
    // its Allies) and the conversation picked from it. Phones open straight
    // into the assistant's conversation with the list one step back, like
    // Messages; iPads and the Mac keep the list in a collapsible sidebar.

    /// What the list holds, and the detail column shows.
    enum Conversation: Hashable {
        case palo
        case pal(String)
        case ally(String)
        /// 工作区: sessions tiled together (workbench-prd §5.3).
        case workspace(String)
        /// 以前的 (workbench-prd §2): sessions that ended or were put away,
        /// and the computer's conversations; one resumed opens as a session.
        case earlier
        /// One of the computer's sessions that isn't a Pal, read only (§14).
        case session(String)
        /// 电脑与设备 (docs/devices-prd.md): the paired computers, and the
        /// devices paired with the current one.
        case devices
    }
    /// The conversation picked in the list. Phones: nil once back on the list.
    var selection: Conversation? = .palo {
        didSet {
            guard selection != oldValue else { return }
            // Phones: a workspace opens straight at the session last shown in
            // it (else its first); its quick-switch strip goes to the others.
            if layout == .phone, case .workspace(let w)? = selection, let target = Self.landing(in: w, store: store) {
                selection = .pal(target)
                return
            }
            if case .pal(let id)? = selection, let w = store?.pal(id: id)?.workspaceId {
                var last = UserDefaults.standard.dictionary(forKey: Self.lastTabKey) as? [String: String] ?? [:]
                last[w] = id
                UserDefaults.standard.set(last, forKey: Self.lastTabKey)
            }
            // The last page's toolbar items (a workspace's ＋) go with it;
            // the new page puts up its own as it appears.
            clearMacToolbarMenus()
            // Each conversation starts at its own root.
            detailPath = NavigationPath()
            detailShown = false
            paneCover = false
            filesPanel = nil
        }
    }
    private static let lastTabKey = "workspaceLastTab"

    /// The session a workspace opens at on a phone: the one last shown in it
    /// while still a member, else its first; nil when it has none.
    static func landing(in workspaceID: String, store: AppStore?) -> String? {
        guard let members = store?.workspace(id: workspaceID)?.memberIds, !members.isEmpty else { return nil }
        let last = (UserDefaults.standard.dictionary(forKey: lastTabKey) as? [String: String])?[workspaceID]
        if let last, members.contains(last) { return last }
        return members.first
    }

    /// The title capsule's details are open (workbench-prd §6).
    var detailShown = false
    /// 新建会话 asked (⌘N, the sidebar's ＋): in a workspace when it has one.
    var newSession = false
    /// 并排 → 新开: the new session goes into this workspace as a tile.
    var newSessionIntoWorkspace: String?
    /// 向右分出 / 向下分出 → 新开一个会话: where in that workspace its pane goes.
    var newSessionPlacement: PanePlacement?
    /// The Mac: what the open page puts in the window toolbar (its ⋯, a
    /// workspace's ＋), and which page put it there.
    var macToolbarMenus: MacToolbarMenus?
    /// The conversation those menus were made for.
    var macToolbarPage: Conversation?
    @ObservationIgnored var macToolbarOwner: UUID?
    /// The page's menus while the window still shows the page that put them up.
    var currentMacToolbarMenus: MacToolbarMenus? {
        macToolbarPage != nil && macToolbarPage == selection ? macToolbarMenus : nil
    }
    func clearMacToolbarMenus() {
        macToolbarOwner = nil
        macToolbarPage = nil
        macToolbarMenus = nil
    }
    /// Each workspace's active tile (a session id), kept while the window is open.
    var activeTiles: [String: String] = [:]
    /// Phones (and short windows): the right pane as a full page.
    var paneCover = false
    /// Large screens: the right pane shown or not, per page (`paneKey`), as
    /// this window has it. The computer keeps one flag per page for every
    /// window and device; it is only the default here, for a page this
    /// window hasn't opened or closed the pane on (see `editPane`).
    var paneOpenHere: [String: Bool] = [:]
    /// The inspector's content is on screen (its onAppear/onDisappear), for the debug log.
    @ObservationIgnored var inspectorShown = false
    /// 从历史记录继续… is open: the ＋ menu sets it, `.historyPicker()` shows the sheet.
    var historyPickerPresented = false
    /// 新建工作区 asked (⌘⇧N, ＋, a session's 并排…): with these sessions chosen.
    var newWorkspace: [String]?
    /// The quick-switch strip's last move went forward (the next page slides in from the right).
    var quickSwitchForward = true

    /// Phones: the list or the conversation (the conversation at launch).
    var compactColumn: NavigationSplitViewColumn = .detail
    /// iPads and the Mac: the sidebar shown or put away (the system toggle).
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// What's pushed over the conversation (phones: the assistant's
    /// management, 成果, an item opened from the conversation).
    var detailPath = NavigationPath()

    /// Pages pushed over a conversation.
    enum Page: Hashable {
        /// The assistant's management: 目标, 履历, 记忆, the model, 设置.
        case manage
        /// 成果: the library, with search.
        case library
        /// One artifact, opened from the conversation.
        case artifact(String)
        /// One task, opened from the conversation.
        case task(String)
    }

    /// Phones: one column, pages pushed. iPads and the Mac: the sidebar and
    /// the conversation side by side; management is a sheet, 成果 the
    /// inspector beside the conversation. Set by the root from the size class.
    enum Layout: String, Equatable { case phone, split }
    private(set) var layout: Layout = .phone
    /// A short window (a big phone on its side): 成果 is pushed, not beside
    /// the conversation (there's no room for a column).
    var shortWindow = false
    /// 成果 opens beside the conversation (large screens) rather than pushed.
    /// The Mac always (a window starts out with the phone layout for a moment).
    var libraryBeside: Bool { Platform.isMac || layout == .split && !shortWindow }

    func setLayout(_ new: Layout, converting: Bool = false) {
        guard new != layout || converting else { return }
        if !converting { layout = new }
        if new == .phone {
            // The right pane beside the conversation becomes a full page,
            // opened again from its button.
            paneCover = false
        } else if selection == nil {
            // Back on the list (phones) is the assistant's conversation beside it.
            selection = .palo
        }
    }

    /// iPads and the Mac: the assistant's management, as a sheet.
    var showManagement = false {
        didSet { if !showManagement && oldValue { resetManagement() } }
    }
    /// The pane's 成果 tab: artifact ids pushed over the list.
    var libraryPath: [String] = []
    /// A folder's tree in the 成果 tab in place of its list (打开文件夹… in
    /// 成果; docs/files-prd.md). A session's files are the pane's own tab.
    var filesPanel: FileScope?
    /// ⌘F: the 成果 search field should take focus (consumed by LibraryView,
    /// which may only appear after the request).
    var librarySearchRequested = false

    /// The Mac: a click outside the composer asks it to give up focus, so an
    /// empty field turns back into the press-to-talk button.
    var composerUnfocusRequests = 0
    /// The composer that appears next takes the keyboard (back from
    /// 回到这里重来, with the message's words in it).
    var focusComposerOnAppear = false

    /// A conversation from the list, a card, a notification.
    func open(_ c: Conversation) {
        if selection != c { selection = c } else { detailPath = NavigationPath() }
        compactColumn = .detail
    }
    func openPalo() { open(.palo) }
    func openPal(_ id: String) { open(.pal(id)) }
    func openSession(_ id: String) { open(.session(id)) }
    func openWorkspace(_ id: String) { open(.workspace(id)) }
    func openAlly(_ id: String) { open(.ally(id)) }

    /// Another assistant came on screen: its conversation.
    func showAssistantConversation() {
        selection = .palo
        compactColumn = .detail
    }

    /// Phones: back to the list (a conversation that went away, the Ally just removed).
    func showList() {
        guard layout == .phone else {
            selection = .palo
            return
        }
        compactColumn = .sidebar
        selection = nil
    }

    /// The orb in the title: the assistant's management (phones: pushed over
    /// the conversation; large screens: a sheet).
    func openManagement() {
        guard layout == .phone else {
            showManagement = true
            return
        }
        if selection != .palo { selection = .palo }
        compactColumn = .detail
        var path = NavigationPath()
        path.append(Page.manage)
        detailPath = path
    }

    /// Done with management: back to the conversation.
    func closeManagement() {
        if layout == .phone { detailPath = NavigationPath() } else { showManagement = false }
    }

    private func resetManagement() {
        showSettings = false
        openTaskID = nil
    }

    /// ⌘1 / the Mac menu: management, or put it away.
    func toggleManagement() {
        if layout != .phone, showManagement { showManagement = false } else { openManagement() }
    }

    /// ⌘2 and the toolbar's button: the right pane of the page, or put it away.
    func toggleLibrary() { togglePane() }

    /// ⌘F: 成果 with its search field focused.
    func focusLibrarySearch() {
        debugLog("[layout] search 成果")
        openInPane { $0.openLibrary($1) }
        librarySearchRequested = true
    }

    /// From the conversation: just that artifact; one step back returns to it.
    func openArtifact(_ id: String) {
        libraryPath = [id]
        openInPane { $0.openLibrary($1) }
    }

    /// The way out of a single item to its whole collection.
    func showInLibrary(_ id: String? = nil) {
        libraryPath = id.map { [$0] } ?? []
        openInPane { $0.openLibrary($1) }
    }

    /// From the conversation: one task's detail; one step back returns to it.
    func openTask(_ id: String) {
        guard layout == .phone else {
            showSettings = false
            openTaskID = id
            showManagement = true
            return
        }
        detailPath.append(Page.task(id))
    }

    /// 履历, from a task's detail.
    func showAllTasks() {
        assistantTab = .history
        openTaskID = nil
        if layout == .phone {
            var path = NavigationPath()
            path.append(Page.manage)
            detailPath = path
        } else {
            showManagement = true
        }
    }

    /// 设置 (⌘, on the Mac): management with its settings page open.
    func openSettings() {
        openTaskID = nil
        // Phones: a sheet of its own, over the list. Through Palo's
        // management it landed on Palo's conversation instead (the list's
        // selection settling after the push cleared the pushed pages).
        if layout == .phone {
            showSettingsSheet = true
            return
        }
        openManagement()
        showSettings = true
    }
    /// Phones: 设置 from the list, as a sheet.
    var showSettingsSheet = false

    /// ⌘[ (and the in-page back buttons): one level back. A sheet or
    /// preview closes; then a pushed page pops; then 成果 beside the
    /// conversation closes.
    func goBack() {
        if NavigationBack.dismissPresented() { return }
        if NavigationBack.popVisible() { return }
        if paneIsOpen { setPane(open: false) }
    }

    var assistantTab: AssistantTab = .watches // 目标 opens first
    var showSettings = false
    /// How much room the title bar's orb takes (kept by OrbPresenceTracking).
    var orbPresence: OrbPresence = .rest
    /// The model / thinking-depth picker (opened from management).
    var showModelPicker = false
    var showPairingSheet = false
    /// The management header's name-and-form editor.
    var showIdentityEditor = false
    /// Why the pairing screen is open. Most people have one computer, so it
    /// only talks about "adding" when they asked to add another one.
    enum PairingIntent: Equatable {
        case first      // nothing paired yet (or demo)
        case add        // 「添加另一台电脑」
        case replace    // 「换一台电脑配对」: the current one is dropped once the new one is in
    }
    var pairingIntent: PairingIntent = .first

    /// Opens the pairing screen for a given purpose.
    func startPairing(_ intent: PairingIntent) {
        pairingIntent = mode == .paired ? intent : .first
        showPairingSheet = true
    }

    /// Pairs another computer (or re-pairs one), and this window switches to it.
    func pair(with link: PairingLink) async throws {
        try await app.pair(with: link, replacing: pairingIntent == .replace ? activeHostID : nil, in: self)
        pairingIntent = .first
        showPairingSheet = false
    }

    var pendingPairingLink: String?
    /// The pending link came from outside while this device already has an
    /// assistant: the pairing screen asks 「添加这台电脑？」 before using it.
    var confirmPairingLink = false
    /// A pairing link for a computer this device is already paired with (the
    /// assistant's pair_link tapped on the phone it was sent to): it's for
    /// another device, so it's offered for passing on instead.
    var linkForAnotherDevice: LinkForAnotherDevice?
    struct LinkForAnotherDevice: Identifiable, Equatable {
        let link: String
        let hostID: String
        var id: String { link }
    }
    /// Task whose detail should open in management (large screens).
    var openTaskID: String?
    /// An approval the conversation should scroll to (notification tap).
    var focusApprovalID: String?
    /// A notification tap on a question card: the chat brings it into view.
    var focusQuestionID: String?
    /// A message the conversation should scroll to and briefly highlight
    /// (a search hit in 成果).
    var focusMessageSeq: Int64?
    /// 添加 Ally: the invite QR sheet.
    var showAllyInvite = false
    /// An Ally's invite opened from the system Camera: the confirm sheet.
    var allyInvite: PendingAllyInvite?

    /// Back to the assistant's conversation and brings message `seq` into view.
    func jumpToMessage(seq: Int64) {
        focusMessageSeq = seq
        openPalo()
    }

    /// The orange 「等你…」 line, or Palo's waiting count: brings what waits
    /// on the owner in Palo's conversation (`store`, Palo's) into view, from
    /// elsewhere opening that conversation first (`open`). False when
    /// nothing there can be shown.
    @discardableResult
    func showWaiting(in store: AppStore, open: Bool = false) -> Bool {
        guard let item = store.firstWaiting else { return false }
        if open { openPalo() }
        switch item {
        case .message(let seq): focusMessageSeq = seq
        case .approval(let id): focusApprovalID = id
        case .question(let id): focusQuestionID = id
        }
        return true
    }

    /// Launch options take effect once the root knows its layout (phones
    /// push, large screens use a sheet and the inspector); in the first
    /// window only.
    private var launchApplied = false

    func applyLaunchScreen() {
        guard !launchApplied else { return }
        launchApplied = true
        guard app.claimLaunchScreen() else { return }
        switch launch.screen {
        case "library": toggleLibrary()
        // As if tapped in the conversation; `-demoArtifact <id>` picks which.
        case "artifact": openArtifact(UserDefaults.standard.string(forKey: "demoArtifact") ?? "ar1")
        case "assistant", "switcher": openManagement()
        case "settings": openSettings()
        case "hosts", "devices": open(.devices)
        case "pairing": if mode != .unpaired { startPairing(.replace) }
        case "identity": openManagement(); showIdentityEditor = true
        case "list", "allies", "sessions", "pals": showList()
        case "recent", "earlier": open(.earlier)
        #if DEBUG || PERF_HARNESS
        // `-demoScreen workspace`: the demo's split workspace (`-demoWorkspace <id>`, default ws-site).
        case "workspace":
            let id = UserDefaults.standard.string(forKey: "demoWorkspace") ?? "ws-site"
            Task { @MainActor in
                for _ in 0..<40 where store?.workspace(id: id) == nil { try? await Task.sleep(for: .milliseconds(100)) }
                openWorkspace(id)
                #if DEBUG
                // `-demoPaneTabs web | preview`: a file and a page open in its
                // right pane, that one showing.
                if let which = UserDefaults.standard.string(forKey: "demoPaneTabs"), let store {
                    let hub = PaneTabsHub.shared(for: store)
                    let key = PaneTabsKey.workspace(id)
                    editPane(key) { hub in
                        let cwd = store.pal(id: store.workspace(id: id)?.memberIds.first ?? "pal-site")?.cwd ?? ""
                        hub.openPreview(key, path: cwd.isEmpty ? "README.md" : FilePaths.join(cwd, "README.md"))
                        hub.openWeb(key, url: "https://example.com")
                    }
                    if which == "preview" { hub.activate(key, at: PaneTabsKey.pinnedCount) }
                }
                #endif
            }
        #endif
        #if DEBUG
        case "file": Task { await openDemoFile() }
        case "ally":
            let id = UserDefaults.standard.string(forKey: "demoAlly")
            Task { @MainActor in
                // Once the list has come in.
                for _ in 0..<40 where store?.allies.isEmpty ?? true { try? await Task.sleep(for: .milliseconds(100)) }
                if let id = id ?? store?.allies.first?.id { openAlly(id) }
            }
        case "allyInvite": showList(); showAllyInvite = true
        case "allyAccept": allyInvite = PendingAllyInvite(link: Self.demoAllyInviteLink())
        // `-demoSession <id>`: one of the computer's sessions, read only (default the first).
        case "session":
            Task { @MainActor in
                for _ in 0..<40 where store?.otherSessions.isEmpty ?? true { try? await Task.sleep(for: .milliseconds(100)) }
                if let id = UserDefaults.standard.string(forKey: "demoSession") ?? store?.otherSessions.first?.id { openSession(id) }
            }
        case "pal":
            let id = UserDefaults.standard.string(forKey: "demoPal") ?? "pal-site"
            Task { @MainActor in
                // Once the list has come in.
                for _ in 0..<40 where store?.pal(id: id) == nil { try? await Task.sleep(for: .milliseconds(100)) }
                openPal(id)
            }
        #endif
        default: break
        }
        if let t = launch.tab, let tab = AssistantTab(launchName: t) {
            assistantTab = tab
            openManagement()
        }
        #if DEBUG
        // `-demoSidebar hidden`: the sidebar put away (iPad screenshots).
        if UserDefaults.standard.string(forKey: "demoSidebar") == "hidden" { columnVisibility = .detailOnly }
        // `-demoAdopt <session id>`: 接管 tapped on that session in the list
        // (`-demoAdoptAfter 0` keeps a terminal one waiting to be quit).
        if let sid = UserDefaults.standard.string(forKey: "demoAdopt") {
            showList()
            Task { @MainActor in
                for _ in 0..<40 where store?.otherSessions.contains(where: { $0.id == sid }) != true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .milliseconds(600))
                _ = try? await store?.adopt(sessionId: sid)
            }
        }
        #endif
    }

    #if DEBUG
    /// `-demoScreen allyAccept`: someone else's invite, as the Camera opens it.
    static func demoAllyInviteLink() -> String {
        var c = URLComponents()
        c.scheme = "paloally"
        c.host = "ally"
        c.queryItems = [
            URLQueryItem(name: "relay", value: "https://relay.example.com"),
            URLQueryItem(name: "daemon", value: "demo-other"),
            URLQueryItem(name: "code", value: "135790"),
            URLQueryItem(name: "hostkey", value: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"),
            URLQueryItem(name: "name", value: "小林"),
            URLQueryItem(name: "exp", value: String(Date().epochMillis + 10 * 60_000)),
        ]
        return c.url?.absoluteString ?? "paloally://ally"
    }

    /// `-demoScreen file`: the morning brief as if its card in the chat was
    /// tapped — the Markdown sheet, for snapshots.
    private func openDemoFile() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let store, let a = store.artifact(id: "ar1"),
              let data = try? await store.readArtifact(id: a.id).data,
              let url = try? await QuickLookPresenter.file(key: "artifact-\(a.id)", revision: a.updatedAt,
                                                           name: (a.mainFile as NSString).lastPathComponent, data: { data })
        else { return }
        MarkdownFilePresenter.present(url: url, title: a.title, artifactID: a.id,
                                      imageSource: store.markdownImages(artifactID: a.id, documentPath: a.mainFile),
                                      openInLibrary: { [weak self] in self?.showInLibrary($0) })
    }
    #endif

    // MARK: things from outside

    /// A `paloally:` link, from outside (a click in Safari, Notes, Messages,
    /// Mail, the Camera) or tapped in a conversation: a computer's pairing
    /// link goes straight to pairing, an Ally's invite to its confirm sheet.
    func handle(url incoming: URL) {
        guard let url = AppLink.normalized(incoming, ownScheme: Self.urlScheme) else { return }
        // Someone else's assistant (the system Camera opened their QR code):
        // confirmed in a sheet over the conversation, added on this computer.
        if AllyInviteLink.isAllyLink(url.absoluteString) {
            appLog.info("ally invite received (mode \(String(describing: self.mode), privacy: .public))")
            debugLog("ally invite received (mode \(String(describing: self.mode)))")
            allyInvite = PendingAllyInvite(link: url.absoluteString)
            return
        }
        appLog.info("pairing link received (mode \(String(describing: self.mode), privacy: .public))")
        debugLog("pairing link received (mode \(String(describing: self.mode)))")
        let link = url.absoluteString
        // Nothing paired yet: the pairing screen is what's showing, and it
        // pairs right away.
        guard mode != .unpaired else {
            pendingPairingLink = link
            return
        }
        if mode == .paired, let id = (try? PairingLink.parse(link))?.daemonID, hostIDs.contains(id) {
            closeSheetsThen { self.linkForAnotherDevice = LinkForAnotherDevice(link: link, hostID: id) }
            return
        }
        // Another computer: the pairing screen opens on 「添加这台电脑？」.
        pendingPairingLink = link
        confirmPairingLink = true
        pairingIntent = mode == .paired ? .add : .first
        if !showPairingSheet { closeSheetsThen { self.showPairingSheet = true } }
    }

    /// A link clicked while a sheet is up: that one goes first, or the next
    /// one can't be shown. (An open pairing screen takes a new link itself.)
    private func closeSheetsThen(_ show: @escaping @MainActor () -> Void) {
        guard showManagement || showAllyInvite || allyInvite != nil || showPairingSheet else { return show() }
        showManagement = false
        showAllyInvite = false
        allyInvite = nil
        showPairingSheet = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            show()
        }
    }

    /// A notification tap (its assistant already on screen): navigates by id.
    func openFromNotification(_ userInfo: [String: String]) {
        showManagement = false
        // A Pal's (「X 在等你」): its page, where its cards are.
        let pal = userInfo["pal"].flatMap { $0.isEmpty ? nil : $0 }
        if let approvalId = userInfo["approvalId"], !approvalId.isEmpty {
            // Approvals live in the conversation they came from: go there and
            // bring the card into view.
            if let pal { openPal(pal) } else { openCard(source: store?.approval(id: approvalId)?.source) }
            focusApprovalID = approvalId
        } else if let questionId = userInfo["questionId"], !questionId.isEmpty {
            if let pal { openPal(pal) } else { openCard(source: store?.question(id: questionId)?.source) }
            focusQuestionID = questionId
        } else if let pal {
            openPal(pal)
        } else if let taskId = userInfo["taskId"], !taskId.isEmpty {
            openPalo()
            openTask(taskId)
        } else {
            openPalo() // a message: the conversation itself
        }
        bringToFront()
    }

    /// The conversation a card is shown in: its Pal's, else the assistant's.
    private func openCard(source: CardSource?) {
        if let source, source.isPal { openPal(source.id) } else { openPalo() }
    }

    /// iPads and the Mac: this window comes to the front (a notification
    /// tap brings the app forward, not necessarily this window).
    func bringToFront() {
        guard let scene, UIApplication.shared.supportsMultipleScenes,
              scene.activationState != .foregroundActive || !(scene.keyWindow?.isKeyWindow ?? false) else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
    }
}

// MARK: - a conversation as a window remembers it

extension WindowModel.Conversation {
    /// `palo`, `pal:<id>`, `workspace:<id>` …: for a window's restored state
    /// and for 在新窗口中打开.
    var storageKey: String {
        switch self {
        case .palo: "palo"
        case .pal(let id): "pal:\(id)"
        case .ally(let id): "ally:\(id)"
        case .workspace(let id): "workspace:\(id)"
        case .earlier: "earlier"
        case .session(let id): "session:\(id)"
        case .devices: "devices"
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "palo": self = .palo
        case "earlier": self = .earlier
        case "devices": self = .devices
        case "pal" where !id.isEmpty: self = .pal(id)
        case "ally" where !id.isEmpty: self = .ally(id)
        case "workspace" where !id.isEmpty: self = .workspace(id)
        case "session" where !id.isEmpty: self = .session(id)
        default: return nil
        }
    }
}
