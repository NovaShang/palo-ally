import PaloAllyKit
import PaloAllyVoice
import SwiftUI
import UIKit
import UserNotifications

@main
struct PaloAllyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .onOpenURL { appDelegate.model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    breadcrumb("scene \(phase)")
                    switch phase {
                    case .active: appDelegate.model.didBecomeActive()
                    case .background: appDelegate.model.didEnterBackground()
                    default: break
                    }
                }
        }
        .commands { PlaceCommands(model: appDelegate.model) }
    }
}

/// Mac menu bar / iPad hardware keyboard: the two places beside the
/// conversation (panels on large windows, slides on narrow ones).
private struct PlaceCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("「它」") { model.toggleAssistant() }
                .keyboardShortcut("1", modifiers: .command)
            Button("成果") { model.toggleLibrary() }
                .keyboardShortcut("2", modifiers: .command)
            // ⌘F searches 成果 and the conversation (nothing else here has
            // Find). It lives here: Catalyst ignores a replaced text-editing
            // group, and the system Find items are taken out below.
            Button("搜索成果和对话") { model.focusLibrarySearch() }
                .keyboardShortcut("f", modifiers: .command)
            // One level back: a sheet closes, a pushed page → its list, then
            // the open panel closes (narrow: the place slides back to the chat).
            Button("返回") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
        }
        // ⌘, : 「它」 with its settings page.
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .textEditing) {}
    }
}

/// Owns the model so it exists before the system can deliver a notification
/// response (a tap that cold-launches the app arrives right after
/// didFinishLaunching, before any view appears).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        DiagnosticsCollector.shared.start()
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
