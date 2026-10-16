import Foundation
import Observation
import PaloAllyKit
import SwiftUI
import UIKit
import os

let appLog = Logger(subsystem: "com.novashang.paloally", category: "app")

/// Launch options parsed from arguments / UserDefaults:
///   -demo YES            run against the in-memory demo host
///   -demoScreen <name>   chat (the default) | list | library | settings | pairing | artifact | voice | naming |
///                        identity | avatars | assistant (management, as the orb opens it)
///                        | file (DEBUG: the Markdown sheet a file card opens)
///                        | scrollLab (DEBUG: scroll experiments, `-labRun anchor|width|fling|sentinel`)
///   -demoTab <name>      management on watches (目标) | history (履历) | memory; old values tasks → history
///   -pairLink <url>      start pairing with this paloally:// link (automation; skips the open-URL prompt)
///   -demoHosts <n>       demo with n assistants (2 shows 切换助理 in management)
///   -demoState <name>    idle | busy | tasks — what the title capsule shows; quote — a reply quote in the composer;
///                        allies | alliesSent — an Ally's message and a draft back (sent, with `alliesSent`);
///                        `-demoDraftEdit YES` opens drafts in 改一下, `-demoAllyRemove YES` an Ally's page on 解除
///   -demoScreen hosts | switcher   设置 → 我的助理 / management with 切换助理
///   -demoScreen ally | allyInvite | allyAccept   one Ally's page (`-demoAlly <id>`, default the first) /
///                        the invite QR / an invite opened from the Camera
///   -demoScreen pal      one Pal's page (`-demoPal <id>`, default pal-site; `-demoPalPanel release | released |
///                        remove` opens it on that). `-demoAdopt <session id>` taps 接管 on the list
///                        (`-demoAdoptAfter <s>`: when the demo's owner quits a terminal session; 0 never).
///                        `-demoState sessions` keeps the sessions' and Pals' cards waiting
///   -demoScreen recent   最近的对话 (`-demoRecentPick <session id>` opens it asking 接管; `-demoRecentEmpty YES`
///                        none; `-demoAdoptError <why>` makes 接管 fail). `-demoState adopt`: the assistant's
///                        pal_adopt card in its conversation
struct LaunchOptions {
    var demo: Bool
    var screen: String?
    var tab: String?
    var pairLink: String? = nil
    var demoHosts: Int = 1
    /// -demoState idle | busy | tasks — title-capsule screenshot states.
    var demoState: String? = nil
    /// -demoLayout wide — on large screens, open the sidebar and the inspector.
    var demoLayout: String? = nil

    static func current() -> LaunchOptions {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        return LaunchOptions(
            demo: d.bool(forKey: "demo") || env["PALOALLY_DEMO"] == "1",
            screen: d.string(forKey: "demoScreen"),
            tab: d.string(forKey: "demoTab"),
            pairLink: d.string(forKey: "pairLink"),
            demoHosts: max(1, d.integer(forKey: "demoHosts")),
            demoState: d.string(forKey: "demoState"),
            demoLayout: d.string(forKey: "demoLayout")
        )
    }
}

enum AssistantTab: String, CaseIterable, Hashable {
    // 目标 first: what it's helping with over time (watches underneath).
    // 履历: what it's doing now and what it got done. Approvals have no tab —
    // they live in the conversation and the status capsule.
    case watches, history, memory

    var title: String {
        switch self {
        case .watches: String(localized: "目标")
        case .history: String(localized: "履历")
        case .memory: String(localized: "记忆")
        }
    }

    /// Launch-arg / old names map to the nearest current tab.
    init?(launchName: String) {
        switch launchName {
        case "tasks": self = .history
        case "approvals": self = .watches
        default: self.init(rawValue: launchName)
        }
    }
}

/// Root app state: which mode we're in (unpaired / paired / demo), the
/// computers this device is paired with, and which one the owner is looking at.
///
/// Each paired computer is an independent assistant (its own conversation,
/// memory, tasks). All of them stay connected while the app is in the
/// foreground so the switcher can show unread replies and pending approvals;
/// the screen shows the current one.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable { case unpaired, paired, demo }

    private(set) var mode: Mode = .unpaired
    /// Assistants in the owner's order (paired: daemon ids; demo: "demo-N").
    private(set) var hostIDs: [String] = []
    private(set) var hosts: [String: PairedHost] = [:]
    private(set) var stores: [String: AppStore] = [:]
    private var demoHosts: [String: DemoHost] = [:]
    private(set) var activeHostID: String?
    /// Owner-chosen names / colors and what they've seen, per assistant.
    private var meta = HostMeta()

    /// The current assistant's store (nil when nothing is paired).
    var store: AppStore? { activeHostID.flatMap { stores[$0] } }
    var pairedHost: PairedHost? { activeHostID.flatMap { hosts[$0] } }

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
        /// 最近的对话 (pals-prd §10): conversations that ended on the
        /// computer lately, to take over; one adopted opens as its Pal.
        case recent
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
            // Each conversation starts at its own root.
            detailPath = NavigationPath()
            if selection != .palo { inspectorShown = false }
        }
    }
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
    var shortWindow = false {
        didSet { if shortWindow && inspectorShown { setLayout(.phone, converting: true) } }
    }
    /// 成果 opens beside the conversation (large screens) rather than pushed.
    var libraryBeside: Bool { layout == .split && !shortWindow }

    func setLayout(_ new: Layout, converting: Bool = false) {
        guard new != layout || converting else { return }
        if !converting { layout = new }
        if new == .phone {
            // 成果 beside the conversation becomes 成果 pushed over it (a
            // sheet, management, stays a sheet).
            if inspectorShown {
                let items = libraryPath
                inspectorShown = false
                var path = NavigationPath()
                path.append(Page.library)
                for id in items { path.append(Page.artifact(id)) }
                if selection != .palo { selection = .palo }
                detailPath = path
            }
        } else if selection == nil {
            // Back on the list (phones) is the assistant's conversation beside it.
            selection = .palo
        }
    }

    /// iPads and the Mac: the assistant's management, as a sheet.
    var showManagement = false {
        didSet { if !showManagement && oldValue { resetManagement() } }
    }
    /// iPads and the Mac: 成果 beside the conversation.
    var inspectorShown = false {
        didSet {
            if inspectorShown != oldValue { debugLog("[layout] inspector \(inspectorShown)") }
            if !inspectorShown && oldValue { libraryPath = [] }
        }
    }
    /// The inspector's own stack: artifact ids pushed over the list.
    var libraryPath: [String] = []
    /// ⌘F: the 成果 search field should take focus (consumed by LibraryView,
    /// which may only appear after the request).
    var librarySearchRequested = false

    /// Bumped when a memory file is saved, so the memory list reloads its
    /// sizes and times.
    var memoryRevision = 0
    /// The Mac: a click outside the composer asks it to give up focus, so an
    /// empty field turns back into the press-to-talk button.
    var composerUnfocusRequests = 0
    /// The composer that appears next takes the keyboard (back from
    /// 回到这里重来, with the message's words in it).
    var focusComposerOnAppear = false
    /// Each conversation's unsent words, kept while the app is open (back to
    /// the list and in again, they're still there).
    var drafts: [Conversation: String] = [:]

    /// A conversation from the list, a card, a notification.
    func open(_ c: Conversation) {
        if selection != c { selection = c } else { detailPath = NavigationPath() }
        compactColumn = .detail
    }
    func openPalo() { open(.palo) }
    func openPal(_ id: String) { open(.pal(id)) }
    func openSession(_ id: String) { open(.session(id)) }
    func openAlly(_ id: String) { open(.ally(id)) }

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

    /// 成果, from the toolbar of the assistant's conversation (phones:
    /// pushed; large screens: the inspector, or put it away).
    func toggleLibrary() {
        guard !libraryBeside else {
            if inspectorShown {
                inspectorShown = false
            } else {
                libraryPath = []
                inspectorShown = true
            }
            return
        }
        openPalo()
        var path = NavigationPath()
        path.append(Page.library)
        detailPath = path
    }

    /// ⌘F: 成果 with its search field focused.
    func focusLibrarySearch() {
        debugLog("[layout] search 成果")
        if !libraryBeside {
            toggleLibrary()
        } else {
            libraryPath = []
            inspectorShown = true
        }
        librarySearchRequested = true
    }

    /// From the conversation: just that artifact; one step back returns to it.
    func openArtifact(_ id: String) {
        guard !libraryBeside else {
            libraryPath = [id]
            inspectorShown = true
            return
        }
        detailPath.append(Page.artifact(id))
    }

    /// The way out of a single item to its whole collection.
    func showInLibrary(_ id: String? = nil) {
        guard !libraryBeside else {
            libraryPath = id.map { [$0] } ?? []
            inspectorShown = true
            return
        }
        openPalo()
        var path = NavigationPath()
        path.append(Page.library)
        if let id { path.append(Page.artifact(id)) }
        detailPath = path
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
        openManagement()
        showSettings = true
    }

    /// ⌘[ (and the in-page back buttons): one level back. A sheet or
    /// preview closes; then a pushed page pops; then 成果 beside the
    /// conversation closes.
    func goBack() {
        if NavigationBack.dismissPresented() { return }
        if NavigationBack.popVisible() { return }
        if libraryBeside, inspectorShown { inspectorShown = false }
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
    /// Naming was answered (or skipped) this run; the host remembers it too.
    var namingDone = false
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
    let secrets: SecretStore = KeychainSecretStore()
    let launch: LaunchOptions
    private var pushToken: Data?

    init(launch: LaunchOptions = .current()) {
        self.launch = launch
        if launch.demo {
            startDemo()
        } else {
            let list = PairedHostList.load(from: secrets)
            if !list.isEmpty { openPaired(list) }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "orbSine") { OrbInput.shared.startSyntheticVoice() }
        #endif
        if let link = launch.pairLink, let url = URL(string: link) { handle(url: url) }
    }

    /// Preview / demo constructor.
    static func demo() -> AppModel {
        AppModel(launch: LaunchOptions(demo: true, screen: nil, tab: nil))
    }

    var clientKind: String { ProcessInfo.processInfo.isMacCatalystApp ? "mac" : "ios" }
    var clientVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }
    /// 「0.1.2 (261006.2015 · 94d328a)」: which build is running, for bug reports.
    var buildStamp: String {
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["PaloAllyCommit"] as? String ?? "dev"
        return "\(clientVersion) (\(build) · \(commit))"
    }

    /// Launch options take effect once the root knows its layout (phones
    /// push, large screens use a sheet and the inspector).
    private var launchApplied = false

    func applyLaunchScreen() {
        guard !launchApplied else { return }
        launchApplied = true
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
        case "recent": open(.recent)
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

    // MARK: assistants

    /// More than one assistant: the list's first row switches between them.
    var hasSeveralHosts: Bool { hostIDs.count > 1 }

    /// 「Palo（家里的 Mac）」: an assistant by its name and its computer's.
    func assistantLabel(_ id: String) -> String {
        let name = stores[id]?.assistantName.trimmingCharacters(in: .whitespaces) ?? ""
        return "\(name.isEmpty ? "Palo" : name)（\(displayName(id))）"
    }

    /// The computer's assistant is there now, as the owner is shown it.
    func isOnline(_ id: String) -> Bool { stores[id]?.displayedConnection.isOnline ?? false }

    func displayName(_ id: String) -> String {
        if let n = meta.names[id], !n.isEmpty { return n }
        if let s = stores[id], !s.hostName.isEmpty { return s.hostName }
        if let h = hosts[id], !h.hostLabel.isEmpty { return h.hostLabel }
        return String(localized: "电脑")
    }

    func rename(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.names[id] = t.isEmpty ? nil : t
        saveMeta()
    }

    /// The assistant's color, which is also the app's theme while it's on
    /// screen. It lives on its computer (settings.color), so every phone and
    /// Mac shows the same; `meta.themes` caches it for the next launch.
    func theme(for id: String) -> AppTheme {
        meta.themes[id].flatMap(AppTheme.init(rawValue:)) ?? .default
    }

    /// The whole app takes the current assistant's color.
    var currentTheme: AppTheme { activeHostID.map(theme(for:)) ?? .default }

    /// The owner picked a color: it shows right away and is saved on the
    /// computer. If the computer can't take it, the color it has comes back.
    func setTheme(_ theme: AppTheme, for id: String) async throws {
        let before = meta.themes[id]
        meta.themes[id] = theme.rawValue
        saveMeta()
        guard let store = stores[id], store.settings?.color != theme.rawValue else { return }
        do {
            try await store.updateSettings(patch: .object(["color": .string(theme.rawValue)]))
        } catch {
            meta.themes[id] = AppTheme(rawValue: store.settings?.color ?? "")?.rawValue ?? before
            saveMeta()
            throw error
        }
    }

    /// The computer's color wins. A computer that has none yet gets the one
    /// this device picked before colors were kept there (once).
    private func syncTheme(_ id: String, _ settings: HostSettings) {
        if let t = AppTheme(rawValue: settings.color) {
            guard meta.themes[id] != t.rawValue else { return }
            meta.themes[id] = t.rawValue
            saveMeta()
        } else if settings.color.isEmpty, let local = meta.themes[id], let store = stores[id] {
            Task { try? await store.updateSettings(patch: .object(["color": .string(local)])) }
        }
    }

    /// The home-screen icon follows the first assistant (switching icons
    /// shows a system alert, so it doesn't change with every switch).
    var iconTheme: AppTheme { hostIDs.first.map(theme(for:)) ?? .default }

    /// New assistants get a color nobody else uses yet, so they're told apart at a glance.
    private func assignTheme(_ id: String) {
        guard meta.themes[id] == nil else { return }
        let used = Set(meta.themes.values)
        let order: [AppTheme] = [.magenta, .blue, .teal, .violet, .orange, .graphite, .orchid, .rose, .berry]
        meta.themes[id] = (order.first { !used.contains($0.rawValue) } ?? .magenta).rawValue
    }

    /// Replies and notices on an assistant the owner isn't looking at.
    func unreadCount(_ id: String) -> Int {
        guard id != activeHostID, let s = stores[id], let seen = meta.lastSeen[id] else { return 0 }
        return s.unreadCount(after: seen)
    }

    func pendingCount(_ id: String) -> Int {
        guard let s = stores[id] else { return 0 }
        return s.pendingApprovals.count + s.pendingQuestions.count + s.pendingAllyDrafts.count
            + s.pals.reduce(0) { $0 + s.palPendingCount($1.id) }
    }

    /// Something is waiting on another assistant (the dot on the title).
    var othersNeedAttention: Bool {
        hostIDs.contains { $0 != activeHostID && (unreadCount($0) > 0 || pendingCount($0) > 0) }
    }

    /// The owner has seen everything on the current assistant up to now.
    func markSeen() {
        guard let id = activeHostID, let s = stores[id], s.hasSynced, meta.lastSeen[id] != s.lastSeq else { return }
        meta.lastSeen[id] = s.lastSeq
        saveMeta()
    }

    func switchTo(_ id: String) {
        guard hostIDs.contains(id), id != activeHostID else { return }
        markSeen()
        activate(id)
        selection = .palo
        compactColumn = .detail
    }

    private func activate(_ id: String) {
        activeHostID = id
        meta.active = id
        saveMeta()
        // Only the assistant on screen may write the clipboard.
        for (k, s) in stores { s.clipboardWriter = k == id ? AppStore.systemClipboardWriter : nil }
        markSeen()
    }

    private func makeStore(_ transport: any HostTransport, id: String) -> AppStore {
        let s = AppStore(transport: transport, clientKind: clientKind, clientVersion: clientVersion)
        s.onSynced = { [weak self] seq in self?.didSync(id, seq: seq) }
        s.onSettings = { [weak self] settings in self?.syncTheme(id, settings) }
        s.whenCommitted = { CommitWatch.shared.afterCommit($0) }
        s.revealClock = DisplayLinkRevealClock()
        s.finishingReply = { apply in ChatMotion.with(ChatMotion.follow, apply) }
        // 回到这里重来: the messages that leave fade out.
        s.animateRewind = { apply in withAnimation(RewindPanel.leaving, apply) }
        // Each Pal's conversation streams and reveals the same way.
        s.preparePalStore = { pal in
            pal.whenCommitted = { CommitWatch.shared.afterCommit($0) }
            pal.revealClock = DisplayLinkRevealClock()
            pal.finishingReply = { apply in ChatMotion.with(ChatMotion.follow, apply) }
            pal.animateRewind = { apply in withAnimation(RewindPanel.leaving, apply) }
        }
        // A terminal session quit there is a Pal now: its page opens.
        s.onAdopted = { [weak self] pal in
            guard let self, self.activeHostID == id else { return }
            self.openPal(pal.id)
        }
        return s
    }

    private func didSync(_ id: String, seq: Int64) {
        if id == activeHostID {
            markSeen()
        } else if meta.lastSeen[id] == nil {
            // First contact with an assistant in the background: what's there now isn't "new".
            meta.lastSeen[id] = seq
            saveMeta()
        }
    }

    // MARK: modes

    func startDemo() {
        tearDownStores()
        meta = HostMeta.load(demo: true)
        let names = ["我的 MacBook", "云端"]  // i18n-ok: demo data
        for i in 0..<max(1, launch.demoHosts) {
            let id = "demo-\(i + 1)"
            let identities = [("Palo", "magenta"), ("小云", "blue")]  // i18n-ok: demo data
            let who = i < identities.count ? identities[i] : ("Palo", "")
            let naming = launch.screen == "naming" && i == 0
            let host = DemoHost(speed: 1, hostName: i < names.count ? names[i] : "电脑 \(i + 1)",  // i18n-ok: demo data
                                assistantName: naming ? "" : who.0, color: naming ? "" : who.1, pals: i == 0)
            demoHosts[id] = host
            let s = makeStore(host.transport, id: id)
            stores[id] = s
            hostIDs.append(id)
            assignTheme(id)
            if let state = launch.demoState, state != "quote" { Task { await host.applyScenario(state) } }
            s.start()
            // -demoState quote: the composer with a reply quote open (screenshots).
            if launch.demoState == "quote" {
                s.replyDraft = ReplyTo(messageId: "m1", excerpt: "十一月回国机票降到 ¥4,860，比昨天低 ¥320")  // i18n-ok: demo data
            }
        }
        mode = .demo
        activate(meta.active.flatMap { hostIDs.contains($0) ? $0 : nil } ?? hostIDs[0])
    }

    private func openPaired(_ list: [PairedHost]) {
        meta = HostMeta.load(demo: false)
        // The theme picked before assistants had their own colors stays with the first one.
        if meta.themes.isEmpty, let first = list.first { meta.themes[first.daemonID] = AppTheme.current.rawValue }
        for host in list {
            hostIDs.append(host.daemonID)
            hosts[host.daemonID] = host
            assignTheme(host.daemonID)
            open(host)
        }
        mode = .paired
        activate(meta.active.flatMap { hosts[$0] != nil ? $0 : nil } ?? hostIDs[0])
        AppDelegate.requestPushPermission()
    }

    /// Connects to one computer (no-op if already connected).
    private func open(_ host: PairedHost) {
        guard stores[host.daemonID] == nil else { return }
        do {
            let identity = try DeviceIdentity.loadOrCreate(store: secrets)
            let s = makeStore(RelayTransport(host: host, identity: identity), id: host.daemonID)
            stores[host.daemonID] = s
            s.start()
            if let token = pushToken { s.registerPush(token: token, environment: PushEnv.current) }
        } catch {
            debugLog("can't open host \(host.daemonID): \(error)")
        }
    }

    /// Pairs another computer (or re-pairs one), and switches to it.
    func pair(with link: PairingLink) async throws {
        let replacing = pairingIntent == .replace ? activeHostID : nil
        let identity = try DeviceIdentity.loadOrCreate(store: secrets)
        let label = await Self.deviceLabel()
        let host = try await PairingClient().pair(link: link, identity: identity, deviceLabel: label)
        if mode != .paired {
            // From demo or nothing: start from the computers already saved.
            tearDownStores()
            let saved = PairedHostList.load(from: secrets)
            let list = PairedHostList.upsert(host, into: saved)
            try PairedHostList.save(list, to: secrets)
            openPaired(list)
        } else {
            let list = PairedHostList.upsert(host, into: hostIDs.compactMap { hosts[$0] })
            try PairedHostList.save(list, to: secrets)
            if !hostIDs.contains(host.daemonID) { hostIDs.append(host.daemonID) }
            hosts[host.daemonID] = host
            // Re-pairing the same computer: start over with the new credentials.
            stores.removeValue(forKey: host.daemonID)?.shutdown()
            assignTheme(host.daemonID)
            saveMeta()
            open(host)
        }
        markSeen()
        activate(host.daemonID)
        // 「换一台电脑配对」: the old computer goes once the new one is in.
        if let old = replacing, old != host.daemonID { await unpair(old) }
        pairingIntent = .first
        showPairingSheet = false
    }

    /// On Mac Catalyst UIDevice.name is a generic "iPad"; use the Mac's host
    /// name. `ProcessInfo.hostName` can block on DNS, so it runs off-main.
    static func deviceLabel() async -> String {
        #if targetEnvironment(macCatalyst)
        let host = await Task.detached(priority: .userInitiated) {
            ProcessInfo.processInfo.hostName
        }.value.replacingOccurrences(of: ".local", with: "")
        return host.isEmpty || host == "localhost" ? "Mac" : host
        #else
        return UIDevice.current.name
        #endif
    }

    /// Unpairs the current assistant.
    func unpair() async {
        if let id = activeHostID { await unpair(id) }
    }

    /// Tells that computer to drop this device (best-effort), then forgets it.
    func unpair(_ id: String) async {
        guard mode == .paired, hostIDs.contains(id) else { return }
        if let s = stores[id] { await s.unregisterDevice(pushToken: pushToken) }
        stores.removeValue(forKey: id)?.shutdown()
        hosts[id] = nil
        hostIDs.removeAll { $0 == id }
        try? PairedHostList.save(hostIDs.compactMap { hosts[$0] }, to: secrets)
        meta.forget(id)
        saveMeta()
        if hostIDs.isEmpty {
            resetToUnpaired()
        } else if activeHostID == id {
            activate(hostIDs[0])
            selection = .palo
        }
    }

    private func tearDownStores() {
        for s in stores.values { s.shutdown() }
        stores = [:]
        demoHosts = [:]
        hosts = [:]
        hostIDs = []
        activeHostID = nil
    }

    private func resetToUnpaired() {
        tearDownStores()
        mode = .unpaired
        selection = .palo
        showManagement = false
        Self.clearTemporaryFiles()
    }

    /// Artifact copies written for previews / sharing.
    static func clearTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Leaves the demo for pairing; computers paired earlier come back.
    func exitDemo() {
        resetToUnpaired()
        let list = PairedHostList.load(from: secrets)
        if !list.isEmpty { openPaired(list) }
    }

    private func saveMeta() { meta.save(demo: mode == .demo) }

    // MARK: system hooks

    /// The scheme this build registered for its links (`paloally`; a test
    /// build's own, so the installed app keeps `paloally:`).
    static let urlScheme: String = {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? AppLink.scheme
    }()

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

    func didBecomeActive() {
        // Long stays in the background leave a stale socket: each store forces
        // a fresh connection after 30 s away.
        for s in stores.values { s.didBecomeActive() }
    }

    func didEnterBackground() {
        markSeen()
        for s in stores.values { s.didEnterBackground() }
    }

    func didRegisterPush(token: Data) {
        pushToken = token
        for s in stores.values { s.registerPush(token: token, environment: PushEnv.current) }
    }

    /// Notification tap: payload carries hostId / seq / id / taskId / approvalId / questionId / pal.
    /// Switches to the assistant it came from first (falls back to the current
    /// one), then navigates by id — on cold launch too, before anything synced.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        if let hostId = userInfo["hostId"] as? String, hostIDs.contains(hostId) { switchTo(hostId) }
        showManagement = false
        // A Pal's (「X 在等你」): its page, where its cards are.
        let pal = (userInfo["pal"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let approvalId = userInfo["approvalId"] as? String, !approvalId.isEmpty {
            // Approvals live in the conversation they came from: go there and
            // bring the card into view.
            if let pal { openPal(pal) } else { openCard(source: store?.approval(id: approvalId)?.source) }
            focusApprovalID = approvalId
        } else if let questionId = userInfo["questionId"] as? String, !questionId.isEmpty {
            if let pal { openPal(pal) } else { openCard(source: store?.question(id: questionId)?.source) }
            focusQuestionID = questionId
        } else if let pal {
            openPal(pal)
        } else if let taskId = userInfo["taskId"] as? String, !taskId.isEmpty {
            openPalo()
            openTask(taskId)
        } else {
            openPalo() // a message: the conversation itself
        }
    }

    /// The conversation a card is shown in: its Pal's, else the assistant's.
    private func openCard(source: CardSource?) {
        if let source, source.isPal { openPal(source.id) } else { openPalo() }
    }
}

/// Per-assistant settings that aren't secrets: the owner's name and color
/// for each, what they've seen, and which one was open. Demo mode keeps its
/// own copy so it never mixes with real computers.
struct HostMeta: Codable {
    var names: [String: String] = [:]
    var themes: [String: String] = [:]
    var lastSeen: [String: Int64] = [:]
    var active: String?

    mutating func forget(_ id: String) {
        names[id] = nil
        themes[id] = nil
        lastSeen[id] = nil
        if active == id { active = nil }
    }

    private static func key(demo: Bool) -> String { demo ? "hostMeta.demo" : "hostMeta" }

    static func load(demo: Bool) -> HostMeta {
        guard let data = UserDefaults.standard.data(forKey: key(demo: demo)),
              let m = try? JSONDecoder().decode(HostMeta.self, from: data) else { return HostMeta() }
        return m
    }

    func save(demo: Bool) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(demo: demo)) }
    }
}

/// APNs environment: whatever the embedded provisioning profile says
/// (`aps-environment`), falling back to the build configuration.
enum PushEnv {
    static let current: PushEnvironment = fromProfile() ?? {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }()

    private static func fromProfile() -> PushEnvironment? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"),
            bundle.bundleURL.appendingPathComponent("embedded.provisionprofile"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let env = ProvisioningProfile.pushEnvironment(from: data) {
                return env
            }
        }
        return nil
    }
}
