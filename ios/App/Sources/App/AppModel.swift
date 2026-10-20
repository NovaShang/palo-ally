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

/// What the whole app shares, whatever window it's in: which mode we're in
/// (unpaired / paired / demo), the computers this device is paired with,
/// one connection (store) per computer, which one the owner is looking at,
/// the unsent words of every conversation, and the open windows.
///
/// Each paired computer is an independent assistant (its own conversation,
/// memory, tasks). All of them stay connected while the app is in the
/// foreground so the switcher can show unread replies and pending approvals;
/// the screen shows the current one.
///
/// What one window shows (the conversation picked, its sheets, the sidebar
/// and the pane) is that window's own: `WindowModel`. iPads and the Mac can
/// have several windows; phones have one.
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

    /// Bumped when a memory file is saved, so the memory list reloads its
    /// sizes and times.
    var memoryRevision = 0
    /// Naming was answered (or skipped) this run; the host remembers it too.
    var namingDone = false

    /// Each conversation's unsent words, kept while the app is open (back to
    /// the list and in again, they're still there), the same in every
    /// window. One box per conversation, observed on its own: a keystroke in
    /// one tile redraws that tile's composer, not every tile's (one shared
    /// dictionary did).
    @ObservationIgnored private var draftBoxes: [WindowModel.Conversation: DraftBox] = [:]

    func draftBox(_ c: WindowModel.Conversation) -> DraftBox {
        if let box = draftBoxes[c] { return box }
        let box = DraftBox()
        draftBoxes[c] = box
        return box
    }

    /// A binding to one conversation's unsent words; the same one every
    /// time, so handing it down again (each update of a split workspace's
    /// page) doesn't count as a change and redraw every tile's chat.
    func draftBinding(_ c: WindowModel.Conversation) -> Binding<String> { draftBox(c).binding }

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

    /// The window links, notification taps and menu commands go to: the one
    /// used last, else any.
    var frontWindow: WindowModel? { lastActive ?? windows.first }

    func register(_ window: WindowModel) {
        windowRefs.removeAll { $0.model == nil || $0.model === window }
        windowRefs.append(WeakWindow(model: window))
        if lastActive == nil { lastActive = window }
        let pending = waiting
        waiting = []
        for deliver in pending { deliver(window) }
    }

    func unregister(_ window: WindowModel) {
        windowRefs.removeAll { $0.model == nil || $0.model === window }
        if lastActive === window { lastActive = windows.first }
    }

    func windowBecameActive(_ window: WindowModel) {
        guard lastActive !== window else { return }
        lastActive = window
    }

    /// Runs `body` on the front window, or on the first one to come up.
    func inFrontWindow(_ body: @escaping (WindowModel) -> Void) {
        if let w = frontWindow { body(w) } else { waiting.append(body) }
    }

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

    /// Another assistant on screen: every window opens on its conversation
    /// (what they showed belonged to the one before).
    func switchTo(_ id: String) {
        guard hostIDs.contains(id), id != activeHostID else { return }
        markSeen()
        activate(id)
        for w in windows { w.showAssistantConversation() }
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
        // A terminal session quit there is a Pal now: its page opens (in the window used last).
        s.onAdopted = { [weak self] pal in
            guard let self, self.activeHostID == id else { return }
            self.frontWindow?.openPal(pal.id)
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
                                assistantName: naming ? "" : who.0, color: naming ? "" : who.1, pals: i == 0,
                                version: i == 0 ? launch.demoHostVersion : nil)
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
    /// `replacing`: 「换一台电脑配对」, the computer that goes once the new one is in.
    func pair(with link: PairingLink, replacing: String?) async throws {
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
            for w in windows { w.selection = .palo }
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
    /// one), then the window used last navigates by id — on cold launch too,
    /// before anything synced.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        if let hostId = userInfo["hostId"] as? String, hostIDs.contains(hostId) { switchTo(hostId) }
        let info = userInfo.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String { acc[k] = "\(kv.value)" }
        }
        inFrontWindow { $0.openFromNotification(info) }
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

/// One conversation's unsent words (AppModel.draftBox).
@MainActor @Observable
final class DraftBox {
    var text = ""
    @ObservationIgnored lazy var binding = Binding<String>(get: { [unowned self] in self.text },
                                                           set: { [unowned self] in self.text = $0 })
}
