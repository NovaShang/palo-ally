import Foundation
import Observation
import PaloAllyKit
import SwiftUI
import UIKit
import os

let appLog = Logger(subsystem: "com.novashang.paloally", category: "app")

/// Launch options parsed from arguments / UserDefaults:
///   -demo YES            run against the in-memory demo host
///   -demoScreen <name>   chat | library | assistant | settings | pairing | artifact | voice
///   -demoTab <name>      tasks | approvals | watches | memory
///   -pairLink <url>      start pairing with this paloally:// link (automation; skips the open-URL prompt)
///   -demoHosts <n>       demo with n assistants (2 shows the switcher)
///   -demoState <name>    idle | busy | tasks — what the title capsule shows
///   -demoScreen hosts | switcher   设置 → 我的助理 / the assistant switcher open
struct LaunchOptions {
    var demo: Bool
    var screen: String?
    var tab: String?
    var pairLink: String? = nil
    var demoHosts: Int = 1
    /// -demoState idle | busy | tasks — title-capsule screenshot states.
    var demoState: String? = nil

    static func current() -> LaunchOptions {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        return LaunchOptions(
            demo: d.bool(forKey: "demo") || env["PALOALLY_DEMO"] == "1",
            screen: d.string(forKey: "demoScreen"),
            tab: d.string(forKey: "demoTab"),
            pairLink: d.string(forKey: "pairLink"),
            demoHosts: max(1, d.integer(forKey: "demoHosts")),
            demoState: d.string(forKey: "demoState")
        )
    }
}

enum AssistantTab: String, CaseIterable, Hashable {
    // 目标 first: what it's helping with over time (watches underneath).
    case watches, tasks, approvals, memory

    var title: String {
        switch self {
        case .tasks: "任务"
        case .approvals: "审批"
        case .watches: "目标"
        case .memory: "记忆"
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

    var showLibrary: Bool {
        get { place == .library }
        set { if newValue { libraryRoot = .list; place = .library } else if place == .library { place = .chat } }
    }
    var showAssistant: Bool {
        get { place == .assistant }
        set { if newValue { assistantRoot = .tabs; place = .assistant } else if place == .assistant { place = .chat } }
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
        assistantTab = .tasks
        openTaskID = nil
        place = .assistant
    }
    var assistantTab: AssistantTab = .watches // 目标 opens first
    var showSettings = false
    var showHostList = false
    var showHostSwitcher = false
    var showPairingSheet = false
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
    var libraryPath: [String] = []
    /// Task whose detail should open on the assistant page (notification tap).
    var openTaskID: String?

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
        if let link = launch.pairLink, let url = URL(string: link) { handle(url: url) }
    }

    /// Preview / demo constructor.
    static func demo() -> AppModel {
        AppModel(launch: LaunchOptions(demo: true, screen: nil, tab: nil))
    }

    var clientKind: String { ProcessInfo.processInfo.isMacCatalystApp ? "mac" : "ios" }
    var clientVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    private func applyLaunchScreen() {
        switch launch.screen {
        case "library": showLibrary = true
        case "artifact": openArtifact("ar1") // as if tapped in the conversation
        case "assistant": showAssistant = true
        case "settings": showAssistant = true; showSettings = true
        case "hosts": showAssistant = true; showSettings = true; showHostList = true
        case "switcher": showHostSwitcher = true
        case "pairing": if mode != .unpaired { startPairing(.replace) }
        default: break
        }
        if let t = launch.tab, let tab = AssistantTab(rawValue: t) {
            assistantTab = tab
            showAssistant = true
        }
    }

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

    func theme(for id: String) -> AppTheme {
        meta.themes[id].flatMap(AppTheme.init(rawValue:)) ?? .default
    }

    /// The whole app takes the current assistant's color.
    var currentTheme: AppTheme { activeHostID.map(theme(for:)) ?? .default }

    func setTheme(_ theme: AppTheme, for id: String) {
        meta.themes[id] = theme.rawValue
        saveMeta()
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

    func pendingCount(_ id: String) -> Int { stores[id]?.pendingApprovals.count ?? 0 }

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
            let host = DemoHost(speed: 1, hostName: i < names.count ? names[i] : "电脑 \(i + 1)")
            demoHosts[id] = host
            let s = makeStore(host.transport, id: id)
            stores[id] = s
            hostIDs.append(id)
            assignTheme(id)
            if let state = launch.demoState { Task { await host.applyScenario(state) } }
            s.start()
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
            assistantRoot = .tabs
            assistantTab = .approvals
            openTaskID = nil
            place = .assistant
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
