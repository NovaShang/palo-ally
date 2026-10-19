import PaloAllyKit
import SwiftUI
import UIKit

enum Platform {
    /// Running as the Mac app (Catalyst, Mac idiom).
    static let isMac: Bool = {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }()

    /// The Mac keeps the sidebar toggle and 成果 in the window toolbar and
    /// floats the assistant's orb in its conversation itself.
    /// DEBUG `-phoneBar YES` shows the phone's bar there instead, to look at
    /// it without a simulator.
    static let barInWindowToolbar: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "phoneBar") { return false }
        #endif
        return isMac
    }()
}

/// Mac: a standard window toolbar with the system sidebar toggle by the
/// traffic lights (it shows and hides the list) and 成果 at the trailing
/// edge, and no window title. The orb isn't in the toolbar: it floats at the
/// top of the assistant's conversation (ChatView). Each column keeps its own
/// navigation bar inside it. Installed once per window; elsewhere it does
/// nothing.
struct MacWindowChrome: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.background(MacToolbarInstaller(model: model).frame(width: 0, height: 0))
        #else
        content
        #endif
    }
}

/// Mac: keeps this navigation stack's bar inside its column. Left alone,
/// UIKit moves every column's bar items into the window toolbar, where they
/// pile up and jump around as columns open and close.
struct InContentNavigationBar: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.background(NavigationBarStyleProbe().frame(width: 0, height: 0))
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct NavigationBarStyleProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ vc: Probe, context: Context) { vc.apply() }

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }
        func apply() {
            guard let bar = navigationController?.navigationBar, bar.preferredBehavioralStyle != .pad else { return }
            bar.preferredBehavioralStyle = .pad
        }
    }
}

private struct MacToolbarInstaller: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> InstallView { InstallView(model: model) }
    func updateUIView(_ view: InstallView, context: Context) {}

    final class InstallView: UIView {
        let model: AppModel
        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { MacToolbar.install(on: scene, model: model) }
        }
    }
}

/// The Mac app's AppKit bundle (PlugIns/PaloAllyAppKit.bundle, from
/// ios/App/AppKitSupport): window work UIKit has no API for.
@MainActor
enum AppKitBundle {
    private static let object: NSObject? = {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PaloAllyAppKit.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? NSObject.Type else {
            debugLog("[mac] the AppKit bundle didn't load")
            return nil
        }
        return type.init()
    }()

    /// A string-returning, argument-less call into the bundle (nil: not loaded).
    static func call(_ name: String) -> String? {
        object?.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String
    }

    /// The window with this toolbar: its content runs under a transparent
    /// titlebar, the traffic lights and toolbar items floating over it.
    static func immerseWindows(toolbar id: String) {
        _ = object?.perform(NSSelectorFromString("immerseWindowsWithToolbar:"), with: id)
    }

    #if DEBUG
    /// The window's titlebar as AppKit draws it, over `content` (`-demoSnapshot`).
    static func addTitlebar(to content: UIImage) -> UIImage? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("titlebar.png").path
        guard let object,
              let frame = object.perform(NSSelectorFromString("snapshotTitlebarTo:"), with: path)?
                .takeUnretainedValue() as? String,
              let titlebar = UIImage(contentsOfFile: path) else { return nil }
        let rect = NSCoder.cgRect(for: frame)
        return UIGraphicsImageRenderer(size: content.size).image { _ in
            content.draw(at: .zero)
            titlebar.draw(in: rect)
        }
    }
    #endif
}

private extension NSToolbarItem.Identifier {
    static let library = NSToolbarItem.Identifier("palo.library")
}

/// The window toolbar: 成果 at the trailing edge, nothing that can overflow
/// at any width. The sidebar's button is the capsule's (SidebarCollapse), so
/// it never meets the traffic lights or the page strips.
@MainActor
final class MacToolbar: NSObject, NSToolbarDelegate {
    private static var installed: [ObjectIdentifier: MacToolbar] = [:]

    private let model: AppModel
    private let toolbar = NSToolbar(identifier: "palo.main")

    static func install(on scene: UIWindowScene, model: AppModel) {
        let key = ObjectIdentifier(scene)
        guard installed[key] == nil, let titlebar = scene.titlebar else { return }
        let bar = MacToolbar(model: model)
        installed[key] = bar
        titlebar.titleVisibility = .hidden
        titlebar.toolbarStyle = .unified
        titlebar.separatorStyle = .none
        titlebar.toolbar = bar.toolbar
        AppKitBundle.immerseWindows(toolbar: bar.toolbar.identifier)
    }

    private init(model: AppModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    /// The separator that follows the sidebar's edge, and 成果 at the
    /// trailing edge.
    private static let items: [NSToolbarItem.Identifier] = [
        .primarySidebarTrackingSeparatorItemIdentifier, .flexibleSpace, .library,
    ]

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .library:
            return toggle(id, symbol: "sidebar.trailing", label: String(localized: "右侧栏"), tip: String(localized: "显示或隐藏右侧栏 ⌘2"),
                          action: #selector(toggleLibrary))
        default:
            return nil
        }
    }

    private func toggle(_ id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String,
                        action: Selector) -> NSToolbarItem {
        let button = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        let item = NSToolbarItem(itemIdentifier: id, barButtonItem: button)
        item.label = label
        item.toolTip = tip
        item.visibilityPriority = .high
        return item
    }

    @objc private func toggleLibrary() { model.toggleLibrary() }
}
#endif
