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
///   -demoHostVersion <x.y.z>  the demo computer reports that version (a newer one shows the Mac app's update hint)
///   -demoTab <name>      management on watches (目标) | history (履历) | memory; old values tasks → history
///   -pairLink <url>      start pairing with this paloally:// link (automation; skips the open-URL prompt)
///   -demoHosts <n>       demo with n assistants (2: the sidebar lists both computers, each with its own
///                        sessions; DEBUG `-demoLocalHost <n>`: the n-th stands for this Mac, default the first;
///                        `-demoOfflineHost <n>`: the n-th never connects)
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
    /// -demoPaneTabs web | preview | address — with `-demoScreen workspace` (DEBUG): a file and a page in its right pane.
    var demoLayout: String? = nil
    /// -demoHostVersion 9.9.9 (or PALOALLY_DEMO_HOST_VERSION): the demo computer reports
    /// that version, to show the Mac app's 「有新版本」 hint. Default: none.
    var demoHostVersion: String? = nil

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
            demoLayout: d.string(forKey: "demoLayout"),
            demoHostVersion: d.string(forKey: "demoHostVersion") ?? env["PALOALLY_DEMO_HOST_VERSION"]
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
        case .history: String(localized: "记录")
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

/// What the whole app shares, whatever window it's in: which mode we're in
/// (unpaired / paired / demo), the computers this device is paired with,
/// one connection (store) per computer, the one used last, the unsent words
/// of every conversation, and the open windows.
///
/// Each paired computer is an independent assistant (its own conversation,
/// memory, tasks). All of them stay connected while the app is in the
/// foreground so the switcher can show unread replies and pending approvals.
///
/// What one window shows (the computer, the conversation picked, its sheets,
/// the sidebar and the pane) is that window's own: `WindowModel`. iPads and
/// the Mac can have several windows, each on its own computer; phones have one.
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
    #if DEBUG
    /// The demo's computer behind a store (`-demoActions` `tick:` / `stream:`).
    func demoHost(_ id: String) -> DemoHost? { demoHosts[id] }
    #endif
    /// The computer used last (the one in the window in front): a new
    /// window and the next launch open on it; phones show it.
    private(set) var lastHostID: String?
    /// Owner-chosen names / colors and what they've seen, per assistant.
    private var meta = HostMeta()

    /// Bumped when a memory file is saved, so the memory list reloads its
    /// sizes and times.
    var memoryRevision = 0
    /// Naming was answered (or skipped) this run; the host remembers it too.
    var namingDone = false

    /// Each conversation's unsent words, kept while the app is open (back to
    /// the list and in again, they're still there), the same in every
    /// window. One box per computer and conversation (two windows on two
    /// computers each have their own Palo), observed on its own: a keystroke
    /// in one tile redraws that tile's composer, not every tile's (one shared
    /// dictionary did).
    private struct DraftKey: Hashable {
        let host: String
        let conversation: WindowModel.Conversation
    }
    @ObservationIgnored private var draftBoxes: [DraftKey: DraftBox] = [:]

    func draftBox(host: String?, _ c: WindowModel.Conversation) -> DraftBox {
        let key = DraftKey(host: host ?? "", conversation: c)
        if let box = draftBoxes[key] { return box }
        let box = DraftBox(persistKey: "\(key.host)|\(c.storageKey)")
        draftBoxes[key] = box
        return box
    }

    /// A binding to one conversation's unsent words; the same one every
    /// time, so handing it down again (each update of a split workspace's
    /// page) doesn't count as a change and redraw every tile's chat.
    func draftBinding(host: String?, _ c: WindowModel.Conversation) -> Binding<String> { draftBox(host: host, c).binding }

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
        #if targetEnvironment(macCatalyst)
        watchMacFront()
        Task { [weak self] in
            await MachineIdentity.loadName()
            self?.localNameRevision += 1
            debugLog("[hosts] this Mac \(MachineIdentity.local == nil ? "has no hardware id (names compared)" : "has its hardware id"); its computer \(self?.localHostID ?? "-")")
        }
        #endif
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

    /// Launch options (`-demoScreen` …) are for the first window only.
    @ObservationIgnored private var launchClaimed = false
    func claimLaunchScreen() -> Bool {
        guard !launchClaimed else { return false }
        launchClaimed = true
        return true
    }

    // MARK: windows

    private struct WeakWindow { weak var model: WindowModel? }
    @ObservationIgnored private var windowRefs: [WeakWindow] = []
    /// The window the owner used last (the key window on the Mac).
    @ObservationIgnored private weak var lastActive: WindowModel?
    /// Something from outside (a link, a notification tap) that came before any window was up.
    @ObservationIgnored private var waiting: [(WindowModel) -> Void] = []

    /// The open windows (phones: one).
    var windows: [WindowModel] { windowRefs.compactMap(\.model) }

    /// The window links, notification taps and menu commands go to: the key
    /// window (the Mac's front one), else the one used last, else any.
    var frontWindow: WindowModel? {
        let all = windows
        if all.count > 1,
           let key = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene })
               .first(where: { $0.windows.contains(where: \.isKeyWindow) }),
           let w = all.first(where: { $0.scene === key }) {
            return w
        }
        return lastActive ?? all.first
    }

    func register(_ window: WindowModel) {
        windowRefs.removeAll { $0.model == nil || $0.model === window }
        windowRefs.append(WeakWindow(model: window))
        // A window that just opened is the one in front (and its computer the one used last).
        settleWindows()
        lastActive = window
        if let id = window.activeHostID { use(id) }
        let pending = waiting
        waiting = []
        for deliver in pending { deliver(window) }
    }

    func unregister(_ window: WindowModel) {
        windowRefs.removeAll { $0.model == nil || $0.model === window }
        if lastActive === window { lastActive = windows.first }
    }

    func windowBecameActive(_ window: WindowModel) {
        lastActive = window
        if let id = window.activeHostID, id != lastHostID { use(id) }
    }

    /// Runs `body` on the front window, or on the first one to come up.
    func inFrontWindow(_ body: @escaping (WindowModel) -> Void) {
        if let w = frontWindow { body(w) } else { waiting.append(body) }
    }

    /// Something that belongs to one computer (a notification tap): a window
    /// already showing it (the front one if it does), else the front window,
    /// which switches to that computer.
    func inWindow(showing id: String?, _ body: @escaping (WindowModel) -> Void) {
        guard let id, hostIDs.contains(id) else { return inFrontWindow(body) }
        if let w = window(showing: id) { return body(w) }
        inFrontWindow { w in
            w.switchTo(id)
            body(w)
        }
    }

    /// A window showing this computer: the front one if it does, else the
    /// one opened last of them.
    func window(showing id: String) -> WindowModel? {
        if let front = frontWindow, front.activeHostID == id { return front }
        return windows.last { $0.activeHostID == id }
    }

    /// Whether a window in front shows session `pal`: its page, or a pane of
    /// the workspace it shows.
    func showsOnScreen(pal: String) -> Bool {
        windows.contains { w in
            guard w.scene?.activationState == .foregroundActive else { return false }
            switch w.selection {
            case .pal(let id)?: return id == pal
            case .workspace(let ws)?: return w.store?.workspace(id: ws)?.memberIds.contains(pal) == true
            default: return false
            }
        }
    }

    /// The computers some window shows.
    var hostsOnScreen: Set<String> { Set(windows.compactMap(\.activeHostID)) }

    /// Every window shows a computer that's still there: one whose computer
    /// went (unpaired, or the demo left) shows the one used last, on its
    /// assistant's conversation.
    private func settleWindows() {
        // Not before the computers are known: a window restored at launch
        // (WindowMemory) names its computer before that computer's store is
        // made, and was sent back to the assistant's conversation for it.
        guard !hostIDs.isEmpty else { return }
        for w in windows where w.hostID.map({ !hostIDs.contains($0) || stores[$0] == nil }) ?? true {
            let had = w.hostID != nil
            w.hostID = lastHostID
            if had { w.showAssistantConversation() }
        }
    }

    // MARK: assistants

    /// More than one assistant: the sidebar lists each computer in a section of its own.
    var hasSeveralHosts: Bool { hostIDs.count > 1 }

    // MARK: the sidebar's computers (docs/workbench-design/multi-host-sidebar.html)

    /// The owner's order of the computers in the sidebar (上移 / 下移 on a
    /// computer's name); computers not in it follow in pairing order. Never
    /// by recency.
    private(set) var hostOrder: [String] = []
    /// Computers whose section the owner folded (false: opened); none set: the default.
    private(set) var collapsedHosts: [String: Bool] = [:]
    /// Each computer's machine (hashed) as it last said, so this Mac's own
    /// is known before it connects again.
    private var machineIDs: [String: String] = [:]

    /// The Mac: the computer whose host runs on this Mac (its hello's
    /// machine id is this Mac's, `MachineIdentity`). Phones and iPads: none.
    var localHostID: String? {
        guard Platform.isMac else { return nil }
        _ = localNameRevision
        return hostIDs.first { id in
            let name = stores[id]?.hostName ?? ""
            return MachineIdentity.matches(machineID: stores[id]?.hostMachineID ?? machineIDs[id],
                                           hostName: name.isEmpty ? hosts[id]?.hostLabel ?? "" : name)
        }
    }

    /// The computers as the sidebar lists them: the owner's order, and on
    /// the Mac this Mac's own first whatever that order says.
    var sidebarHostIDs: [String] {
        var ids = hostOrder.filter(hostIDs.contains) + hostIDs.filter { !hostOrder.contains($0) }
        if let local = localHostID, let i = ids.firstIndex(of: local), i > 0 {
            ids.remove(at: i)
            ids.insert(local, at: 0)
        }
        return ids
    }

    /// Whether 上移 (-1) / 下移 (+1) can move this computer (this Mac's own stays first).
    func canMoveHost(_ id: String, by delta: Int) -> Bool {
        let ids = sidebarHostIDs
        guard let i = ids.firstIndex(of: id) else { return false }
        let j = i + delta
        guard ids.indices.contains(j) else { return false }
        let local = localHostID
        return id != local && ids[j] != local
    }

    func moveHost(_ id: String, by delta: Int) {
        guard canMoveHost(id, by: delta) else { return }
        var ids = sidebarHostIDs
        let i = ids.firstIndex(of: id)!
        ids.swapAt(i, i + delta)
        hostOrder = ids
        saveSidebarPrefs()
    }

    /// A computer's section is folded: as the owner left it; else, the
    /// first time, on the Mac every one but the first (this Mac's own), on
    /// phones and iPads none.
    func isHostCollapsed(_ id: String) -> Bool {
        collapsedHosts[id] ?? (Platform.isMac && id != sidebarHostIDs.first)
    }

    /// The owner hasn't folded or opened this computer's section yet.
    func hostFoldUnset(_ id: String) -> Bool { collapsedHosts[id] == nil }

    func setHostCollapsed(_ id: String, _ collapsed: Bool) {
        collapsedHosts[id] = collapsed
        saveSidebarPrefs()
    }

    /// The demo keeps its own order and folds, apart from real computers'.
    @ObservationIgnored private var sidebarDemo = false
    private func sidebarKey(_ name: String) -> String { sidebarDemo ? "\(name).demo" : name }
    /// Bumped once this Mac's name is known (`MachineIdentity.localName`, the fallback).
    private var localNameRevision = 0

    private func loadSidebarPrefs(demo: Bool) {
        sidebarDemo = demo
        let d = UserDefaults.standard
        hostOrder = d.stringArray(forKey: sidebarKey("sidebarHostOrder")) ?? []
        collapsedHosts = d.dictionary(forKey: sidebarKey("sidebarHostCollapsed")) as? [String: Bool] ?? [:]
        // The demo's computers say who they are on every launch (`-demoLocalHost`): none kept.
        machineIDs = demo ? [:] : d.dictionary(forKey: sidebarKey("hostMachineIDs")) as? [String: String] ?? [:]
    }

    private func saveSidebarPrefs() {
        let d = UserDefaults.standard
        d.set(hostOrder, forKey: sidebarKey("sidebarHostOrder"))
        d.set(collapsedHosts, forKey: sidebarKey("sidebarHostCollapsed"))
        d.set(machineIDs, forKey: sidebarKey("hostMachineIDs"))
    }

    /// What waits on the owner on a computer (a folded section's count): the
    /// open items of its 等你的事, which hold everything that waits.
    func waitingTotal(_ id: String) -> Int {
        stores[id]?.openPending.count ?? 0
    }

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
        return String(localized: "主机")
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

    /// Replies and notices on an assistant since the owner last had it on screen.
    func unreadCount(_ id: String) -> Int {
        guard let s = stores[id], let seen = meta.lastSeen[id] else { return 0 }
        return s.unreadCount(after: seen)
    }

    /// The owner has seen everything on this assistant up to now (a window shows it).
    func markSeen(_ id: String) {
        guard let s = stores[id], s.hasSynced, meta.lastSeen[id] != s.lastSeq else { return }
        meta.lastSeen[id] = s.lastSeq
        saveMeta()
    }

    /// The owner is using this computer now (its window is in front, or
    /// switched to it): a new window and the next launch open on it.
    func use(_ id: String) {
        guard stores[id] != nil else { return }
        if lastHostID != id {
            lastHostID = id
            meta.active = id
            saveMeta()
        }
        // Only the assistant in front may write the clipboard.
        for (k, s) in stores { s.clipboardWriter = k == id ? AppStore.systemClipboardWriter : nil }
        markSeen(id)
    }

    private func makeStore(_ transport: any HostTransport, id: String) -> AppStore {
        let s = AppStore(transport: transport, clientKind: clientKind, clientVersion: clientVersion)
        // Its downloaded files are kept apart from another computer's.
        s.fileCacheHost = id
        #if DEBUG
        // `-demoDownload sequential`: downloads as before (256 KiB, one at a
        // time), to measure against; `-demoClearDownloads YES`: an empty cache.
        let d = UserDefaults.standard
        if d.string(forKey: "demoDownload") == "sequential" || d.bool(forKey: "demoClearDownloads") {
            let sequential = d.string(forKey: "demoDownload") == "sequential"
            let clear = d.bool(forKey: "demoClearDownloads")
            Task {
                if sequential { await FileFetcher.shared.configure(chunkSize: 256 * 1024, parallel: 1) }
                if clear { await FileFetcher.shared.clearCache() }
            }
        }
        #endif
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
        // A terminal session quit there is a Pal now: its page opens in a
        // window showing that computer (the front one if it does).
        s.onAdopted = { [weak self] pal in
            self?.window(showing: id)?.openPal(pal.id)
        }
        // Said to the host once it's connected.
        if inFront { s.setPresence(true) }
        return s
    }

    private func didSync(_ id: String, seq: Int64) {
        if !sidebarDemo, let m = stores[id]?.hostMachineID, machineIDs[id] != m {
            machineIDs[id] = m
            saveSidebarPrefs()
        }
        if hostsOnScreen.contains(id) {
            markSeen(id)
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
        loadSidebarPrefs(demo: true)
        let names = ["我的 MacBook", "公司的 Mac"]  // i18n-ok: demo data
        // Which demo computer stands for this Mac (its hello says this Mac's machine).
        var localIndex = 0
        // DEBUG `-demoOfflineHost <n>`: the n-th demo computer never connects (a gray dot, faded rows).
        var offlineIndex = -1
        #if DEBUG
        if UserDefaults.standard.integer(forKey: "demoLocalHost") > 0 { localIndex = UserDefaults.standard.integer(forKey: "demoLocalHost") - 1 }
        offlineIndex = UserDefaults.standard.integer(forKey: "demoOfflineHost") - 1
        #endif
        debugLog("[hosts] demo: \(launch.demoHosts) computers, this Mac's is \(localIndex + 1), offline \(offlineIndex + 1), hardware id \(MachineIdentity.local == nil ? "unread" : "read")")
        for i in 0..<max(1, launch.demoHosts) {
            let id = "demo-\(i + 1)"
            let identities = [("Palo", "magenta"), ("小云", "blue")]  // i18n-ok: demo data
            let who = i < identities.count ? identities[i] : ("Palo", "")
            let naming = launch.screen == "naming" && i == 0
            let host = DemoHost(speed: 1, offline: i == offlineIndex, hostName: i < names.count ? names[i] : "主机 \(i + 1)",  // i18n-ok: demo data
                                assistantName: naming ? "" : who.0, color: naming ? "" : who.1, pals: i <= 1,
                                version: i == 0 ? launch.demoHostVersion : nil,
                                machineId: i == localIndex ? MachineIdentity.local : nil, office: i == 1)
            demoHosts[id] = host
            let s = makeStore(host.transport, id: id)
            stores[id] = s
            hostIDs.append(id)
            assignTheme(id)
            if let state = launch.demoState, state != "quote" { Task { await host.applyScenario(state) } }
            #if DEBUG || PERF_HARNESS
            if i == 0 { Task { await host.startPerfTicks() } }
            #endif
            s.start()
            // -demoState quote: the composer with a reply quote open (screenshots).
            if launch.demoState == "quote" {
                s.replyDraft = ReplyTo(messageId: "m1", excerpt: "十一月回国机票降到 ¥4,860，比昨天低 ¥320")  // i18n-ok: demo data
            }
        }
        mode = .demo
        use(meta.active.flatMap { hostIDs.contains($0) ? $0 : nil } ?? hostIDs[0])
        settleWindows()
    }

    private func openPaired(_ list: [PairedHost]) {
        meta = HostMeta.load(demo: false)
        loadSidebarPrefs(demo: false)
        // The theme picked before assistants had their own colors stays with the first one.
        if meta.themes.isEmpty, let first = list.first { meta.themes[first.daemonID] = AppTheme.current.rawValue }
        for host in list {
            hostIDs.append(host.daemonID)
            hosts[host.daemonID] = host
            assignTheme(host.daemonID)
            open(host)
        }
        mode = .paired
        use(meta.active.flatMap { hosts[$0] != nil ? $0 : nil } ?? hostIDs[0])
        settleWindows()
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

    /// Pairs another computer (or re-pairs one); `window` switches to it.
    /// `replacing`: 「换一台电脑配对」, the computer that goes once the new one is in.
    func pair(with link: PairingLink, replacing: String?, in window: WindowModel?) async throws {
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
        use(host.daemonID)
        window?.switchTo(host.daemonID)
        // 「换一台电脑配对」: the old computer goes once the new one is in.
        if let old = replacing, old != host.daemonID { await unpair(old) }
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
        } else {
            // The windows that showed it move to the one used last (or the first).
            if lastHostID.map({ stores[$0] == nil }) ?? true { use(hostIDs[0]) }
            settleWindows()
        }
    }

    private func tearDownStores() {
        for s in stores.values { s.shutdown() }
        stores = [:]
        demoHosts = [:]
        hosts = [:]
        hostIDs = []
        lastHostID = nil
    }

    private func resetToUnpaired() {
        tearDownStores()
        mode = .unpaired
        for w in windows {
            w.selection = .palo
            w.showManagement = false
        }
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

    /// A `paloally:` link (from outside, or tapped in a conversation): the
    /// window used last shows what it opens.
    func handle(url: URL) {
        inFrontWindow { $0.handle(url: url) }
    }

    // MARK: in front

    /// The app is in front: phones, the scene active; the Mac, the app
    /// frontmost (Catalyst keeps the scene active behind other apps). Every
    /// host is told (`presence`) and holds its pushes back meanwhile.
    @ObservationIgnored private(set) var inFront = false

    func setInFront(_ front: Bool) {
        guard front != inFront else { return }
        inFront = front
        breadcrumb("in front \(front)")
        for s in stores.values { s.setPresence(front) }
    }

    #if targetEnvironment(macCatalyst)
    @ObservationIgnored private var macFrontObservers: [NSObjectProtocol] = []

    /// NSApplication's active state, read and followed through the runtime (no AppKit import on Catalyst).
    private func watchMacFront() {
        if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
           let active = app.value(forKey: "active") as? Bool {
            setInFront(active)
        }
        let nc = NotificationCenter.default
        macFrontObservers = [
            nc.addObserver(forName: .init("NSApplicationDidBecomeActiveNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInFront(true) }
            },
            nc.addObserver(forName: .init("NSApplicationDidResignActiveNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInFront(false) }
            },
        ]
    }
    #endif

    func didBecomeActive() {
        // Long stays in the background leave a stale socket: each store forces
        // a fresh connection after 30 s away.
        for s in stores.values { s.didBecomeActive() }
        // Shared from another app's share sheet while away.
        takeShares()
        if !watchingShareTargets {
            watchingShareTargets = true
            writeShareTargets()
            watchShareTargets()
        }
    }
    @ObservationIgnored private var watchingShareTargets = false

    func didEnterBackground() {
        for id in hostsOnScreen { markSeen(id) }
        writeShareTargets()
        for s in stores.values { s.didEnterBackground() }
    }

    func didRegisterPush(token: Data) {
        pushToken = token
        for s in stores.values { s.registerPush(token: token, environment: PushEnv.current) }
    }

    /// Notification tap: payload carries hostId / seq / id / taskId / approvalId / questionId / pal.
    /// A window already showing the assistant it came from comes forward and
    /// navigates by id; if none does, the window in front switches to it
    /// (no hostId: the front window as it is) — on cold launch too, before
    /// anything synced.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        let info = userInfo.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String { acc[k] = "\(kv.value)" }
        }
        inWindow(showing: info["hostId"]) { $0.openFromNotification(info) }
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

/// One conversation's unsent words (AppModel.draftBox). With a `persistKey`
/// they are kept on the device as they change, so a crash or a quit doesn't
/// take them (11-03): the box made again on the next launch has them back,
/// and the words of a recording that never finished after them.
@MainActor @Observable
final class DraftBox {
    var text = "" {
        didSet { if let persistKey, text != oldValue { Self.store(text, for: persistKey) } }
    }
    @ObservationIgnored let persistKey: String?
    @ObservationIgnored lazy var binding = Binding<String>(get: { [unowned self] in self.text },
                                                           set: { [unowned self] in self.text = $0 })

    init(persistKey: String? = nil) {
        self.persistKey = persistKey
        guard let persistKey else { return }
        var kept = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey)?[persistKey] as? String) ?? ""
        if let words = VoiceRecovery.take(for: persistKey) {
            kept = kept.isEmpty ? words : kept + words
            debugLog("[draft] \(words.count) characters of an unfinished recording put back")
        }
        text = kept
        if !kept.isEmpty { Self.store(kept, for: persistKey) }
    }

    private static let defaultsKey = "composerDrafts"

    private static func store(_ text: String, for key: String) {
        let d = UserDefaults.standard
        var all = d.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = text.isEmpty ? nil : text
        d.set(all, forKey: defaultsKey)
    }
}
