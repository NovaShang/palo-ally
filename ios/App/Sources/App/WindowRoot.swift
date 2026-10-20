import PaloAllyKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a window was opened for: a conversation (`Conversation.storageKey`)
/// on a computer (the one of the window it was opened from). Each one is new
/// (`nonce`), so opening the same conversation again makes another window
/// rather than bringing back the first.
struct WindowTarget: Codable, Hashable {
    var conversation: String
    /// The computer's id (nil: the one used last).
    var host: String?
    var nonce = UUID()

    init(_ conversation: WindowModel.Conversation, host: String?) {
        self.conversation = conversation.storageKey
        self.host = host
    }

    /// A sidebar row dragged out of the window (iPads): the system opens a
    /// window with this activity.
    static let activityType = "com.novashang.paloally.conversation"
    private static let key = "conversation"
    private static let hostKey = "host"

    static func activity(for conversation: WindowModel.Conversation, host: String?) -> NSUserActivity {
        let a = NSUserActivity(activityType: activityType)
        a.title = conversation.storageKey
        var info: [String: String] = [key: conversation.storageKey]
        if let host { info[hostKey] = host }
        a.userInfo = info
        a.targetContentIdentifier = conversation.storageKey
        return a
    }

    static func conversation(in activity: NSUserActivity) -> WindowModel.Conversation? {
        (activity.userInfo?[key] as? String).flatMap(WindowModel.Conversation.init(storageKey:))
    }

    static func host(in activity: NSUserActivity) -> String? {
        activity.userInfo?[hostKey] as? String
    }
}

/// One window: its own `WindowModel` over the shared `AppModel`. It
/// registers with the app (links, notification taps and menu commands go to
/// the window used last), and remembers the computer and the conversation it
/// shows, so it comes back with them (iPads and the Mac; phones always open
/// on Palo of the computer used last, as before).
struct WindowRoot: View {
    let app: AppModel
    let target: WindowTarget?
    @State private var model: WindowModel
    @SceneStorage("window.conversation") private var saved = ""
    @SceneStorage("window.host") private var savedHost = ""
    @Environment(\.scenePhase) private var scenePhase

    init(app: AppModel, target: WindowTarget?) {
        self.app = app
        self.target = target
        // Opened from another window: that window's computer (else the one used last, once registered).
        let host = target?.host.flatMap { app.stores[$0] != nil ? $0 : nil }
        _model = State(initialValue: WindowModel(app: app, hostID: host))
    }

    var body: some View {
        RootView()
            .environment(model)
            // A link the system handed to this window.
            .onOpenURL { model.handle(url: $0) }
            .onContinueUserActivity(WindowTarget.activityType) { activity in
                if let id = WindowTarget.host(in: activity) { model.switchTo(id) }
                if let c = WindowTarget.conversation(in: activity) { model.open(c) }
            }
            .background { SceneReader { model.scene = $0 } }
            .onAppear {
                restore()
                app.register(model)
                if let id = model.activeHostID { savedHost = id }
            }
            .onDisappear { app.unregister(model) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { app.windowBecameActive(model) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { note in
                if let w = note.object as? UIWindow, let scene = model.scene, w.windowScene === scene {
                    app.windowBecameActive(model)
                }
            }
            .onChange(of: model.selection) { _, c in
                if let c { saved = c.storageKey }
            }
            .onChange(of: model.activeHostID) { _, id in
                if let id { savedHost = id }
            }
    }

    /// What this window was opened for, else what it showed when it was last
    /// open (iPads and the Mac): the computer, then the conversation on it.
    private func restore() {
        guard UIDevice.current.userInterfaceIdiom != .phone else { return }
        // What it showed last wins over what it was opened for (it may have moved on since).
        if !savedHost.isEmpty {
            // Its computer was unpaired since: the one used last, on its assistant.
            guard app.stores[savedHost] != nil else { return }
            model.hostID = savedHost
        }
        let key = saved.isEmpty ? target?.conversation ?? "" : saved
        if let c = WindowModel.Conversation(storageKey: key), c != model.selection {
            model.selection = c
        }
    }
}

/// Hands over the window scene the view is in.
private struct SceneReader: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.found = found
        return v
    }
    func updateUIView(_ view: Probe, context: Context) { view.found = found }

    final class Probe: UIView {
        var found: ((UIWindowScene) -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isHidden = true
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }
}

/// 在新窗口中打开 on a sidebar row, and (iPads) the row dragged out of the
/// window to make one; the new window shows this window's computer.
struct OpenInNewWindow: ViewModifier {
    let conversation: WindowModel.Conversation
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if UIApplication.shared.supportsMultipleScenes {
            content.onDrag {
                let provider = NSItemProvider()
                provider.registerObject(WindowTarget.activity(for: conversation, host: model.activeHostID), visibility: .all)
                return provider
            }
        } else {
            content
        }
        #endif
    }
}

/// The context menu's 在新窗口中打开 (iPads and the Mac).
struct OpenInNewWindowButton: View {
    let conversation: WindowModel.Conversation
    @Environment(WindowModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if UIApplication.shared.supportsMultipleScenes {
            Button("在新窗口中打开", systemImage: "macwindow.badge.plus") {
                openWindow(value: WindowTarget(conversation, host: model.activeHostID))
            }
        }
    }
}
