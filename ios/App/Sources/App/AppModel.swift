import Foundation
import Observation
import PaloAllyKit
import SwiftUI
import UIKit
import os

let appLog = Logger(subsystem: "com.novashang.paloally", category: "app")

/// Launch options parsed from arguments / UserDefaults:
///   -demo YES            run against the in-memory demo host
///   -demoScreen <name>   chat | library | assistant | settings | pairing | artifact | voice | naming | identity | avatars
///                        | file (DEBUG: the Markdown sheet a file card opens)
///   -demoTab <name>      watches (目标) | history (履历) | memory; old values tasks → history, approvals → watches
///   -pairLink <url>      start pairing with this paloally:// link (automation; skips the open-URL prompt)
///   -demoHosts <n>       demo with n assistants (2 shows the switcher)
///   -demoState <name>    idle | busy | tasks — what the title capsule shows; quote — a reply quote in the composer
///   -demoScreen hosts | switcher   设置 → 我的助理 / the assistant switcher open
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
        case .watches: "目标"
        case .history: "履历"
        case .memory: "记忆"
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

    // Navigation state (also driven by launch options / notifications).
    /// The app is one horizontal space: 「它」 (the assistant) on the left, the
    /// conversation in the middle, 「成果」 (the library) on the right. The top
    /// buttons push the conversation aside; going back slides it home.
    enum Place: Equatable { case assistant, chat, library }
    var place: Place = .chat {
        didSet {
            // Large screens: 「它」 and 「成果」 are panels beside the
            // conversation, so going to a place means opening its panel.
            if layout != .phone {
                if !quietPlaceChange { showColumns(for: place) }
                return
            }
            guard place != oldValue else { return }
            // What was open in a place doesn't come back next time: an item
            // opened from the chat reverts to the place's normal root. Reset
            // after the slide so nothing changes while it's still on screen.
            let left = oldValue
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, self.place != left else { return }
                self.resetPlace(left)
            }
        }
    }
    /// What the assistant place shows at its root: the tabs, or one task
    /// opened from the conversation (back from it returns to the chat).
    enum AssistantRoot: Equatable { case tabs, task(String) }
    var assistantRoot: AssistantRoot = .tabs
    /// What the library place shows at its root: the list, or one artifact
    /// opened from the conversation (back from it returns to the chat).
    enum LibraryRoot: Equatable { case list, artifact(String) }
    var libraryRoot: LibraryRoot = .list

    /// Bumped when a memory file is saved, so the memory list reloads its
    /// sizes and times.
    var memoryRevision = 0
    /// The Mac: a click outside the composer asks it to give up focus, so an
    /// empty field turns back into the press-to-talk button.
    var composerUnfocusRequests = 0

    /// ⌘[ (and the in-page back buttons): one level back. A sheet or
    /// preview closes; then a pushed page in a visible place or panel pops;
    /// then, narrow, the place slides back to the chat, and on large screens
    /// the open panel closes (成果 first).
    func goBack() {
        if NavigationBack.dismissPresented() { return }
        if NavigationBack.popVisible() { return }
        if layout == .phone {
            if place != .chat { place = .chat }
        } else {
            closeTopPanel()
        }
    }

    /// Large screens: put the open panel away (成果 first). Esc and ⌘[.
    func closeTopPanel() {
        if inspectorShown {
            inspectorShown = false
        } else if sidebarShown {
            sidebarShown = false
        }
    }

    // MARK: large-screen layout

    /// How the three places are laid out, set by the root container from the
    /// window's actual width (not the device): phone = one place at a time,
    /// sliding; medium / wide = the conversation always on screen, 「它」
    /// (`sidebarShown`) and 「成果」 (`inspectorShown`) as panels on either
    /// side, closed by default. Wide windows can have both open.
    enum Layout: String, Equatable { case phone, medium, wide }
    private(set) var layout: Layout = .phone
    var sidebarShown = false {
        didSet {
            if sidebarShown != oldValue { debugLog("[layout] sidebar \(sidebarShown) (\(layout.rawValue), place \(place))") }
            columnChanged(.assistant, shown: sidebarShown, was: oldValue)
        }
    }
    var inspectorShown = false {
        didSet {
            if inspectorShown != oldValue { debugLog("[layout] inspector \(inspectorShown) (\(layout.rawValue), place \(place))") }
            columnChanged(.library, shown: inspectorShown, was: oldValue)
        }
    }
    /// ⌘F: the 成果 search field should take focus (consumed by LibraryView,
    /// which may only appear after the request).
    var librarySearchRequested = false
    private var quietPlaceChange = false

    func setLayout(_ new: Layout) {
        guard new != layout else { return }
        let old = layout
        if new == .phone {
            // One place at a time: keep the conversation in front unless a
            // narrower window should keep showing what was just opened.
            let front: Place = inspectorShown && place == .library ? .library
                : (old == .medium && sidebarShown && place == .assistant ? .assistant : .chat)
            layout = new
            sidebarShown = false
            inspectorShown = false
            quietly { place = front }
            return
        }
        layout = new
        // Panels are opened on demand, never by default.
        let demoWide = launch.demoLayout == "wide"
        sidebarShown = place == .assistant || demoWide
        inspectorShown = place == .library || (old != .phone && inspectorShown) || demoWide
        if new == .medium, sidebarShown, inspectorShown {
            if place == .library { sidebarShown = false } else { inspectorShown = false }
        }
    }

    /// The conversation's top-left button: on phones slide to 「它」, on large
    /// screens open or close its panel.
    func toggleAssistant() {
        guard layout != .phone else { showAssistant = place != .assistant; return }
        if sidebarShown {
            sidebarShown = false
        } else {
            assistantRoot = .tabs
            place = .assistant
        }
    }

    /// The conversation's top-right button: 「成果」 slides in, or its panel toggles.
    func toggleLibrary() {
        guard layout != .phone else { showLibrary = place != .library; return }
        if inspectorShown {
            inspectorShown = false
        } else {
            libraryRoot = .list
            place = .library
        }
    }

    /// ⌘F: 成果 with its search field focused.
    func focusLibrarySearch() {
        debugLog("[layout] search 成果")
        libraryRoot = .list
        libraryPath = []
        place = .library
        librarySearchRequested = true
    }

    private func showColumns(for p: Place) {
        switch p {
        // Medium width has room for one panel, not both: opening one puts
        // the other away.
        case .assistant:
            if !sidebarShown { sidebarShown = true }
            if layout == .medium, inspectorShown { inspectorShown = false }
        case .library:
            if !inspectorShown { inspectorShown = true }
            if layout == .medium, sidebarShown { sidebarShown = false }
        case .chat:
            // Medium width: the panels cover the conversation, so going to
            // the conversation puts them away. Wide: they sit beside it.
            if layout == .medium {
                if sidebarShown { sidebarShown = false }
                if inspectorShown { inspectorShown = false }
            }
        }
    }

    private func columnChanged(_ p: Place, shown: Bool, was: Bool) {
        guard layout != .phone, was, !shown else { return }
        if place == p {
            quietly { place = p == .assistant ? (inspectorShown ? .library : .chat) : (sidebarShown ? .assistant : .chat) }
        }
        // Like leaving a place on phones: what was open in the panel goes
        // back to its root, after the panel has finished closing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.layout != .phone else { return }
            let stillClosed = p == .assistant ? !self.sidebarShown : !self.inspectorShown
            if stillClosed { self.resetPlace(p) }
        }
    }

    private func quietly(_ change: () -> Void) {
        quietPlaceChange = true
        change()
        quietPlaceChange = false
    }

    private func resetPlace(_ p: Place) {
        switch p {
        case .assistant:
            assistantRoot = .tabs
            showSettings = false
            showHostList = false
            openTaskID = nil
        case .library:
            libraryRoot = .list
            libraryPath = []
        case .chat:
            break
        }
    }

    /// Closing a place returns to the conversation. On large screens that
    /// only puts the panel away where it covers the conversation (medium);
    /// wide, it stays beside it.
    var showLibrary: Bool {
        get { layout == .phone ? place == .library : inspectorShown }
        set {
            if newValue { libraryRoot = .list; place = .library }
            else if layout == .medium { inspectorShown = false }
            else if place == .library { place = .chat }
        }
    }
    var showAssistant: Bool {
        get { layout == .phone ? place == .assistant : sidebarShown }
        set {
            if newValue { assistantRoot = .tabs; place = .assistant }
            else if layout == .medium { sidebarShown = false }
            else if place == .assistant { place = .chat }
        }
    }
    /// From the conversation: slide to the item's place with just that item
    /// open; one step back returns to the chat.
    func openArtifact(_ id: String) {
        libraryPath = []
        libraryRoot = .artifact(id)
        place = .library
    }
    func openTask(_ id: String) {
        showSettings = false
        openTaskID = nil
        assistantRoot = .task(id)
        place = .assistant
    }
    /// The way out of a single item to its whole collection.
    func showInLibrary(_ id: String? = nil) {
        libraryRoot = .list
        libraryPath = id.map { [$0] } ?? []
        place = .library
    }
    func showAllTasks() {
        assistantRoot = .tabs
        assistantTab = .history
        openTaskID = nil
        place = .assistant
    }
    var assistantTab: AssistantTab = .watches // 目标 opens first
    var showSettings = false
    var showHostList = false
    /// The status card behind the title bar's orb.
    var showHostSwitcher = false
    /// How much room the title bar's orb takes (kept by OrbPresenceTracking).
    var orbPresence: OrbPresence = .rest
    /// The model / thinking-depth picker (opened from the status card).
    var showModelPicker = false
    var showPairingSheet = false
    /// The 「它」 header's name-and-form editor.
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

    /// 设置 (⌘, on the Mac): 「它」 with its settings page open.
    func openSettings() {
        assistantRoot = .tabs
        openTaskID = nil
        showSettings = true
        showAssistant = true
    }

    /// Opens the pairing screen for a given purpose.
    func startPairing(_ intent: PairingIntent) {
        pairingIntent = mode == .paired ? intent : .first
        showPairingSheet = true
    }
    var pendingPairingLink: String?
    var libraryPath: [String] = []
    /// Task whose detail should open on the assistant page (notification tap).
    var openTaskID: String?
    /// An approval the conversation should scroll to (notification tap).
    var focusApprovalID: String?
    /// A notification tap on a question card: the chat brings it into view.
    var focusQuestionID: String?
    /// A message the conversation should scroll to and briefly highlight
    /// (a search hit in 成果).
    var focusMessageSeq: Int64?

    /// Slides back to the conversation and brings message `seq` into view.
    func jumpToMessage(seq: Int64) {
        focusMessageSeq = seq
        place = .chat
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
        applyLaunchScreen()
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

    private func applyLaunchScreen() {
        switch launch.screen {
        case "library": showLibrary = true
        case "artifact": openArtifact("ar1") // as if tapped in the conversation
        case "assistant": showAssistant = true
        case "settings": showAssistant = true; showSettings = true
        case "hosts": showAssistant = true; showSettings = true; showHostList = true
        case "switcher": showHostSwitcher = true
        case "pairing": if mode != .unpaired { startPairing(.replace) }
        case "identity": showAssistant = true; showIdentityEditor = true
        #if DEBUG
        case "file": Task { await openDemoFile() }
        #endif
        default: break
        }
        if let t = launch.tab, let tab = AssistantTab(launchName: t) {
            assistantTab = tab
            showAssistant = true
        }
    }

    #if DEBUG
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

    /// More than one assistant: the title becomes a switcher.
    var hasSeveralHosts: Bool { hostIDs.count > 1 }

    func displayName(_ id: String) -> String {
        if let n = meta.names[id], !n.isEmpty { return n }
        if let s = stores[id], !s.hostName.isEmpty { return s.hostName }
        if let h = hosts[id], !h.hostLabel.isEmpty { return h.hostLabel }
        return "电脑"
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
        return s.pendingApprovals.count + s.pendingQuestions.count
    }

    /// Something is waiting on another assistant (the dot on the title).
    var othersNeedAttention: Bool {
        hostIDs.contains { $0 != activeHostID && (unreadCount($0) > 0 || pendingCount($0) > 0) }
    }

    /// Switcher order: assistants waiting on an approval first, then the owner's order.
    var switcherOrder: [String] {
        hostIDs.enumerated().sorted { a, b in
            let (pa, pb) = (pendingCount(a.element) > 0, pendingCount(b.element) > 0)
            return pa != pb ? pa : a.offset < b.offset
        }.map(\.element)
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
        place = .chat
    }

    func moveHosts(from source: IndexSet, to destination: Int) {
        hostIDs.move(fromOffsets: source, toOffset: destination)
        if mode == .paired { try? PairedHostList.save(hostIDs.compactMap { hosts[$0] }, to: secrets) }
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
        let names = ["我的 MacBook", "云端"]
        for i in 0..<max(1, launch.demoHosts) {
            let id = "demo-\(i + 1)"
            let identities = [("Palo", "magenta"), ("小云", "blue")]
            let who = i < identities.count ? identities[i] : ("Palo", "")
            let naming = launch.screen == "naming" && i == 0
            let host = DemoHost(speed: 1, hostName: i < names.count ? names[i] : "电脑 \(i + 1)",
                                assistantName: naming ? "" : who.0, color: naming ? "" : who.1)
            demoHosts[id] = host
            let s = makeStore(host.transport, id: id)
            stores[id] = s
            hostIDs.append(id)
            assignTheme(id)
            if let state = launch.demoState, state != "quote" { Task { await host.applyScenario(state) } }
            s.start()
            // -demoState quote: the composer with a reply quote open (screenshots).
            if launch.demoState == "quote" {
                s.replyDraft = ReplyTo(messageId: "m1", excerpt: "十一月回国机票降到 ¥4,860，比昨天低 ¥320")
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
            place = .chat
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
        place = .chat
        showHostSwitcher = false
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

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "paloally" else { return }
        appLog.info("pairing link received (mode \(String(describing: self.mode), privacy: .public))")
        debugLog("pairing link received (mode \(String(describing: self.mode)))")
        pendingPairingLink = url.absoluteString
        if mode != .unpaired {
            // A link from outside: the screen asks whether to switch or add.
            pairingIntent = .first
            showPairingSheet = true
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

    /// Notification tap: payload carries hostId / seq / id / taskId / approvalId.
    /// Switches to the assistant it came from first (falls back to the current
    /// one), then navigates by id — on cold launch too, before anything synced.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        if let hostId = userInfo["hostId"] as? String, hostIDs.contains(hostId) { switchTo(hostId) }
        showHostSwitcher = false
        if let approvalId = userInfo["approvalId"] as? String, !approvalId.isEmpty {
            // Approvals live in the conversation: go there and bring the card into view.
            place = .chat
            focusApprovalID = approvalId
        } else if let questionId = userInfo["questionId"] as? String, !questionId.isEmpty {
            place = .chat
            focusQuestionID = questionId
        } else if let taskId = userInfo["taskId"] as? String, !taskId.isEmpty {
            openTask(taskId)
        } else {
            place = .chat // a message: the conversation itself
        }
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
