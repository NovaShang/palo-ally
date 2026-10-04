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
struct LaunchOptions {
    var demo: Bool
    var screen: String?
    var tab: String?
    var pairLink: String? = nil

    static func current() -> LaunchOptions {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        return LaunchOptions(
            demo: d.bool(forKey: "demo") || env["PALOALLY_DEMO"] == "1",
            screen: d.string(forKey: "demoScreen"),
            tab: d.string(forKey: "demoTab"),
            pairLink: d.string(forKey: "pairLink")
        )
    }
}

enum AssistantTab: String, CaseIterable, Hashable {
    case tasks, approvals, watches, memory

    var title: String {
        switch self {
        case .tasks: "任务"
        case .approvals: "审批"
        case .watches: "定时"
        case .memory: "记忆"
        }
    }
}

/// Root app state: which mode we're in (unpaired / paired / demo) and the
/// live store.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable { case unpaired, paired, demo }

    private(set) var mode: Mode = .unpaired
    private(set) var store: AppStore?
    private(set) var pairedHost: PairedHost?
    private(set) var demoHost: DemoHost?

    // Navigation state (also driven by launch options / notifications).
    /// The library is a temporary sheet over the conversation, not a peer screen.
    var showLibrary = false
    var showAssistant = false
    var assistantTab: AssistantTab = .tasks
    var showSettings = false
    var showPairingSheet = false
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
        } else if let host = PairedHost.load(from: secrets) {
            connect(to: host)
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
        case "artifact": showLibrary = true; libraryPath = ["ar1"]
        case "assistant": showAssistant = true
        case "settings": showAssistant = true; showSettings = true
        case "pairing": if mode != .unpaired { showPairingSheet = true }
        default: break
        }
        if let t = launch.tab, let tab = AssistantTab(rawValue: t) {
            assistantTab = tab
            showAssistant = true
        }
    }

    // MARK: modes

    func startDemo() {
        store?.stop()
        let host = DemoHost(speed: 1)
        demoHost = host
        let s = AppStore(transport: host.transport, clientKind: clientKind, clientVersion: clientVersion)
        store = s
        mode = .demo
        s.start()
    }

    func connect(to host: PairedHost) {
        store?.stop()
        do {
            let identity = try DeviceIdentity.loadOrCreate(store: secrets)
            let transport = RelayTransport(host: host, identity: identity)
            let s = AppStore(transport: transport, clientKind: clientKind, clientVersion: clientVersion)
            store = s
            pairedHost = host
            demoHost = nil
            mode = .paired
            s.start()
            AppDelegate.requestPushPermission()
            if let token = pushToken { s.registerPush(token: token, environment: PushEnv.current) }
        } catch {
            mode = .unpaired
        }
    }

    func pair(with link: PairingLink) async throws {
        let identity = try DeviceIdentity.loadOrCreate(store: secrets)
        let label = await Self.deviceLabel()
        let host = try await PairingClient().pair(link: link, identity: identity, deviceLabel: label)
        try host.save(to: secrets)
        // Switching to a different computer: say goodbye to the old one.
        if mode == .paired, let old = pairedHost, old.daemonID != host.daemonID, let oldStore = store {
            await oldStore.unregisterDevice(pushToken: pushToken)
        }
        connect(to: host)
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

    /// Tells the host to drop this device (best-effort), then forgets it.
    func unpair() async {
        if mode == .paired, let store {
            await store.unregisterDevice(pushToken: pushToken)
        }
        forgetHost()
    }

    private func forgetHost() {
        store?.stop()
        store = nil
        PairedHost.forget(in: secrets)
        pairedHost = nil
        demoHost = nil
        mode = .unpaired
        showAssistant = false
        showSettings = false
        showLibrary = false
        libraryPath = []
        Self.clearTemporaryFiles()
    }

    /// Artifact copies written for previews / sharing.
    static func clearTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func exitDemo() {
        forgetHost()
    }

    // MARK: system hooks

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "paloally" else { return }
        appLog.info("pairing link received (mode \(String(describing: self.mode), privacy: .public))")
        pendingPairingLink = url.absoluteString
        if mode != .unpaired { showPairingSheet = true }
    }

    func didBecomeActive() {
        // Long stays in the background leave a stale socket: the store forces
        // a fresh connection after 30 s away.
        store?.didBecomeActive()
    }

    func didEnterBackground() {
        store?.didEnterBackground()
    }

    func didRegisterPush(token: Data) {
        pushToken = token
        store?.registerPush(token: token, environment: PushEnv.current)
    }

    /// Notification tap: payload carries seq / id / taskId / approvalId.
    /// Works on cold launch too (the store may not have synced yet), so it
    /// navigates by id without checking what's loaded.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        showSettings = false
        showLibrary = false
        if let approvalId = userInfo["approvalId"] as? String, !approvalId.isEmpty {
            openTaskID = nil
            assistantTab = .approvals
            showAssistant = true
        } else if let taskId = userInfo["taskId"] as? String, !taskId.isEmpty {
            assistantTab = .tasks
            showAssistant = true
            openTaskID = taskId
        } else {
            openTaskID = nil
            showAssistant = false
        }
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
