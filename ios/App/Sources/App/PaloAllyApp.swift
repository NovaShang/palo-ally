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
                    switch phase {
                    case .active: appDelegate.model.didBecomeActive()
                    case .background: appDelegate.model.didEnterBackground()
                    default: break
                    }
                }
        }
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
        voiceLogSink = { debugLog("[voice] \($0)") }
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let sendable = info.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String { acc[k] = "\(kv.value)" }
        }
        await MainActor.run { self.model.handleNotification(userInfo: sendable) }
    }
}
