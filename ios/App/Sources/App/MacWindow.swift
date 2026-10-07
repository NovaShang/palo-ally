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

    /// The Mac keeps the conversation's two place buttons in the window
    /// toolbar (system toggles) and floats the orb in the conversation itself.
    /// DEBUG `-phoneBar YES` shows the phone's bar there instead, to look at
    /// it without a simulator.
    static let barInWindowToolbar: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "phoneBar") { return false }
        #endif
        return isMac
    }()
}

/// Mac: a standard window toolbar with only two toggles — 「它」 by the
/// traffic lights, 成果 at the trailing edge — and no window title. They open
/// the same panels as the phone's buttons, and slide the places in the
/// narrow layout. The orb isn't in the toolbar: it floats at the top of
/// the conversation (ChatView). Each place keeps its own navigation bar inside
/// its column. Installed once per window; elsewhere it does nothing.
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

private extension NSToolbarItem.Identifier {
    static let assistant = NSToolbarItem.Identifier("palo.assistant")
    static let library = NSToolbarItem.Identifier("palo.library")
}

/// The window toolbar: just the two toggles, nothing that can overflow at any
/// width, with the same symbols as the phone's top bar.
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
        titlebar.toolbar = bar.toolbar
    }

    private init(model: AppModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    /// 「它」 by the traffic lights, 成果 at the trailing edge, at every width:
    /// they open and close panels (or, narrow, slide the places), never a
    /// split view's sidebar, so there's no tracking separator.
    private static let items: [NSToolbarItem.Identifier] = [.assistant, .flexibleSpace, .library]

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .assistant:
            return toggle(id, symbol: "sidebar.left", label: "它", tip: "显示或隐藏「它」 ⌘1",
                          action: #selector(toggleAssistant))
        case .library:
            return toggle(id, symbol: "books.vertical", label: "成果", tip: "显示或隐藏成果 ⌘2",
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

    @objc private func toggleAssistant() { model.toggleAssistant() }
    @objc private func toggleLibrary() { model.toggleLibrary() }
}
#endif
