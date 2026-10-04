import Foundation
import Observation
import PaloAllyKit
import SwiftUI
import UIKit

/// Launch options parsed from arguments / UserDefaults:
///   -demo YES            run against the in-memory demo host
///   -demoScreen <name>   chat | library | assistant | settings | pairing | artifact
///   -demoTab <name>      tasks | approvals | watches | memory
struct LaunchOptions {
    var demo: Bool
    var screen: String?
    var tab: String?

    static func current() -> LaunchOptions {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        return LaunchOptions(
            demo: d.bool(forKey: "demo") || env["PALOALLY_DEMO"] == "1",
            screen: d.string(forKey: "demoScreen"),
            tab: d.string(forKey: "demoTab")
        )
    }
}

enum AppTab: Hashable { case chat, library }

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
    var tab: AppTab = .chat
    var showAssistant = false
    var assistantTab: AssistantTab = .tasks
    var showSettings = false
    var showPairingSheet = false
    var pendingPairingLink: String?
    var libraryPath: [String] = []

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
    }

    /// Preview / demo constructor.
    static func demo() -> AppModel {
        AppModel(launch: LaunchOptions(demo: true, screen: nil, tab: nil))
    }

    var clientKind: String { ProcessInfo.processInfo.isMacCatalystApp ? "mac" : "ios" }
    var clientVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    private func applyLaunchScreen() {
        switch launch.screen {
        case "library": tab = .library
        case "artifact": tab = .library; libraryPath = ["ar1"]
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
            if let token = pushToken { s.registerPush(token: token, environment: Self.pushEnvironment) }
        } catch {
            mode = .unpaired
        }
    }

    func pair(with link: PairingLink) async throws {
        let identity = try DeviceIdentity.loadOrCreate(store: secrets)
        let host = try await PairingClient().pair(link: link, identity: identity, deviceLabel: UIDevice.current.name)
        try host.save(to: secrets)
        connect(to: host)
        showPairingSheet = false
    }

    func unpair() {
        store?.stop()
        store = nil
        PairedHost.forget(in: secrets)
        pairedHost = nil
        demoHost = nil
        mode = .unpaired
        showAssistant = false
        showSettings = false
    }

    func exitDemo() {
        unpair()
    }

    // MARK: system hooks

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "paloally" else { return }
        pendingPairingLink = url.absoluteString
        if mode != .unpaired { showPairingSheet = true }
    }

    func didBecomeActive() {
        store?.reconnectNow()
    }

    static var pushEnvironment: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    func didRegisterPush(token: Data) {
        pushToken = token
        store?.registerPush(token: token, environment: Self.pushEnvironment)
    }

    /// Notification tap: payload carries seq / id / taskId / approvalId.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        showSettings = false
        if userInfo["approvalId"] != nil, store?.pendingApprovals.isEmpty == false {
            tab = .chat
            assistantTab = .approvals
            showAssistant = true
        } else if let taskId = userInfo["taskId"] as? String, !taskId.isEmpty {
            assistantTab = .tasks
            showAssistant = true
        } else {
            tab = .chat
            showAssistant = false
        }
    }
}
