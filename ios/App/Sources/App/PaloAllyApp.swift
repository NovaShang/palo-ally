import PaloAllyKit
import PaloAllyVoice
import SwiftUI
import UIKit
import UserNotifications

@main
struct PaloAllyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Undo f2f2128, which pinned the app to Chinese whatever the system's
        // language: once, the language it wrote goes, and the system decides again.
        let d = UserDefaults.standard
        if !d.bool(forKey: "languagePinUndone") {
            d.set(true, forKey: "languagePinUndone")
            if (d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]) == ["zh-Hans"] {
                d.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    }

    var body: some Scene {
        // iPads and the Mac: any number of windows (File → 新建窗口, a row's
        // 在新窗口中打开, a row dragged out on an iPad), each with its own
        // `WindowModel`; phones: one. A window opened for a conversation is
        // given it as its value.
        WindowGroup(for: WindowTarget.self) { $target in
            WindowRoot(app: appDelegate.model, target: target)
        }
        // The app as a whole (any window up or none): the connections wake and sleep with it.
        .onChange(of: scenePhase) { _, phase in
            breadcrumb("scene \(phase)")
            switch phase {
            case .active: appDelegate.model.didBecomeActive()
            case .background: appDelegate.model.didEnterBackground()
            default: break
            }
        }
        .commands {
            // File → 新建会话 (⌘N), 新建工作区 (⌘⇧N) and 新建窗口 (⌥⌘N),
            // in place of the system's New.
            WindowCommands(app: appDelegate.model)
            // View → Show / Hide Sidebar (⌃⌘S), the system's. It also anchors
            // PlaceCommands below (`before: .sidebar`); without it the menu
            // build throws at launch. The collapsed state is saved from
            // `columnVisibility` (RootView), so the system toggle is remembered.
            SidebarCommands()
            PlaceCommands(app: appDelegate.model)
        }
    }
}

/// File: new things, in the window in front, and a new window.
private struct WindowCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建会话") { app.frontWindow?.newSession = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("新建工作区") { app.frontWindow?.newWorkspace = [] }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            if UIApplication.shared.supportsMultipleScenes {
                Divider()
                // On the computer of the window in front.
                Button("新建窗口") { openWindow(value: WindowTarget(.palo, host: app.frontWindow?.activeHostID)) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
    }
}

/// Mac menu bar / iPad hardware keyboard: the assistant's management (the
/// orb) and 成果 (beside the conversation on large windows), in the window in front.
private struct PlaceCommands: Commands {
    let app: AppModel

    private func inFront(_ body: (WindowModel) -> Void) {
        if let w = app.frontWindow { body(w) }
    }

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("管理助理") { inFront { $0.toggleManagement() } }
                .keyboardShortcut("1", modifiers: .command)
            Button("右侧栏") { inFront { $0.toggleLibrary() } }
                .keyboardShortcut("2", modifiers: .command)
            // ⌘F searches 成果 and the conversation (nothing else here has
            // Find). It lives here: Catalyst ignores a replaced text-editing
            // group, and the system Find items are taken out below.
            Button("搜索成果和对话") { inFront { $0.focusLibrarySearch() } }
                .keyboardShortcut("f", modifiers: .command)
            // One level back: a sheet closes, a pushed page pops, then 成果
            // beside the conversation closes.
            Button("返回") { inFront { $0.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            // A split workspace: a new session's pane off the active one.
            Button("向右分出新会话…") { inFront { $0.splitActivePane(horizontal: true) } }
                .keyboardShortcut("d", modifiers: .command)
            Button("向下分出新会话…") { inFront { $0.splitActivePane(horizontal: false) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        // ⌘, : management with its settings page.
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { inFront { $0.openSettings() } }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .textEditing) {}
    }
}

/// Owns the model so it exists before the system can deliver a notification
/// response (a tap that cold-launches the app arrives right after
/// didFinishLaunching, before any view appears; it waits for the first window).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A paloally: link tapped in a conversation (the window clicked in is the one used last).
        InAppLinks.open = { [model] in model.handle(url: $0) }
        // Voice logs already carry "[voice]"; append the time since the press.
        voiceLogSink = { debugLog("\($0)\(VoiceTiming.suffix)") }
        // Random per-device id the relay meters voice by; logged so a device
        // can be matched to its quota.
        debugLog("[voice] install id \(VoiceInstallID.current)")
        // Every build: a hang leaves a timestamp and breadcrumbs in the log,
        // and the system's own hang / crash reports (with stacks) land in
        // Documents/diagnostics on a later launch.
        StallWatchdog.start()
        TraitLog.start()
        AwayAppearance.start()
        DiagnosticsCollector.shared.start()
        #if DEBUG || PERF_HARNESS
        PerfProbe.start()
        #endif
        return true
    }

    /// Asked only once a computer is paired (not on first launch / in demo).
    @MainActor static func requestPushPermission() {
        // @Sendable: called back on a background queue (a main-actor closure would trap).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.didRegisterPush(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / unsigned builds land here; the app works without push.
    }

    // The completion-handler variants, not the async ones: an async delegate
    // method resumes off the main thread, and the system's completion then
    // runs there and trips UIKit's main-thread assertion (SIGABRT on tapping
    // a notification, iPhone 16, 2026-10-07 17:18).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sendable = info.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String { acc[k] = "\(kv.value)" }
        }
        // Handled, and the system told it's done, on the main thread.
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            self.model.handleNotification(userInfo: sendable)
            done()
        }
    }
}

/// While the app is in the background its windows keep the active
/// appearance. Leaving, the system makes the scene inactive and then lays
/// the windows out again for each of its app-switcher snapshots, switching
/// between inactive and active as well as dark and light; each switch makes
/// every view resolve its colors and text again. Nothing of the app is on
/// screen meanwhile, and the snapshot in the current appearance is taken
/// active anyway. The windows follow the scene again once it's active.
@MainActor
enum AwayAppearance {
    static func start() {
        // Phones only: an iPad or Mac window in the background may still
        // be seen, and the inactive look is part of how it says so.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        #if DEBUG
        // `-awayAppearance NO`: windows follow the scene in the background too (to compare).
        if UserDefaults.standard.object(forKey: "awayAppearance") != nil, !UserDefaults.standard.bool(forKey: "awayAppearance") { return }
        #endif
        let center = NotificationCenter.default
        center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                for window in scene?.windows ?? [] where window.traitCollection.activeAppearance == .active {
                    window.traitOverrides.activeAppearance = .active
                }
            }
        }
        center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                for window in scene?.windows ?? [] where window.traitOverrides.contains(UITraitActiveAppearance.self) {
                    window.traitOverrides.remove(UITraitActiveAppearance.self)
                }
            }
        }
    }
}
