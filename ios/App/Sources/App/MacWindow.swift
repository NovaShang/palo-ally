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

    /// The Mac draws the conversation's bar items in the window toolbar
    /// instead of its own bar. DEBUG `-phoneBar YES` shows the phone's bar
    /// there too, to look at it without a simulator.
    static let barInWindowToolbar: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "phoneBar") { return false }
        #endif
        return isMac
    }()
}

/// Mac: one toolbar in the window's title bar at every width, every item in a
/// fixed place — the 「它」 toggle on the left, the orb (with its caption) in
/// the middle, 成果 on the right — and no window title. Each place keeps its
/// own navigation bar inside its column (back buttons stay where they
/// belong). Installed once per window; elsewhere it does nothing.
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
    static let orb = NSToolbarItem.Identifier("palo.orb")
    static let library = NSToolbarItem.Identifier("palo.library")
}

/// The window toolbar and the status card that drops from its orb.
@MainActor
final class MacToolbar: NSObject, NSToolbarDelegate, UIPopoverPresentationControllerDelegate {
    private static var installed: [ObjectIdentifier: MacToolbar] = [:]

    private let model: AppModel
    private weak var scene: UIWindowScene?
    private let toolbar = NSToolbar(identifier: "palo.main")
    private var orbItem: NSToolbarItem?
    private weak var card: UIViewController?

    static func install(on scene: UIWindowScene, model: AppModel) {
        let key = ObjectIdentifier(scene)
        guard installed[key] == nil, let titlebar = scene.titlebar else { return }
        let bar = MacToolbar(model: model, scene: scene)
        installed[key] = bar
        titlebar.titleVisibility = .hidden
        titlebar.toolbarStyle = .unified
        titlebar.toolbar = bar.toolbar
        bar.followCard()
        // Already asked for before the window was up (`-demoScreen switcher`).
        if model.showHostSwitcher {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                bar.syncCard()
            }
        }
    }

    private init(model: AppModel, scene: UIWindowScene) {
        self.model = model
        self.scene = scene
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.orb]
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.assistant, .flexibleSpace, .orb, .flexibleSpace, .library]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .assistant:
            let b = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain,
                                    target: self, action: #selector(toggleAssistant))
            let item = NSToolbarItem(itemIdentifier: id, barButtonItem: b)
            item.label = "它"
            item.toolTip = "显示或隐藏「它」 ⌘1"
            return item
        case .library:
            let b = UIBarButtonItem(image: UIImage(systemName: "books.vertical"), style: .plain,
                                    target: self, action: #selector(toggleLibrary))
            let item = NSToolbarItem(itemIdentifier: id, barButtonItem: b)
            item.label = "成果"
            item.toolTip = "显示或隐藏成果 ⌘2"
            return item
        case .orb:
            let host = UIHostingController(rootView: ToolbarOrb(model: model) { [weak self] in self?.orbTapped() })
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize
            let item = NSUIViewToolbarItem(itemIdentifier: id, uiView: host.view)
            item.label = "状态"
            orbItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func toggleAssistant() { model.toggleAssistant() }
    @objc private func toggleLibrary() { model.toggleLibrary() }

    // MARK: status card

    private func orbTapped() { model.showHostSwitcher.toggle() }

    /// The card follows `model.showHostSwitcher`, like the phone's popover:
    /// picking something inside it closes it the same way on both.
    private func followCard() {
        withObservationTracking {
            _ = model.showHostSwitcher
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncCard()
                self.followCard()
            }
        }
    }

    private func syncCard() {
        if model.showHostSwitcher, card == nil {
            presentCard()
        } else if !model.showHostSwitcher, let card {
            card.dismiss(animated: true)
            self.card = nil
        }
    }

    private func presentCard() {
        guard let store = model.store, let orbItem,
              let root = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        else { model.showHostSwitcher = false; return }
        var top = root
        while let next = top.presentedViewController { top = next }
        let host = UIHostingController(rootView: StatusCard().environment(model).environment(store))
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .popover
        host.popoverPresentationController?.sourceItem = orbItem
        host.popoverPresentationController?.permittedArrowDirections = .up
        host.popoverPresentationController?.delegate = self
        card = host
        top.present(host, animated: true)
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated {
            card = nil
            if model.showHostSwitcher { model.showHostSwitcher = false }
        }
    }
}

/// The orb as the toolbar shows it: reads the current assistant itself, so
/// switching assistants (or pairing the first one) just works.
private struct ToolbarOrb: View {
    let model: AppModel
    let action: () -> Void

    var body: some View {
        if let store = model.store {
            TitleOrb(arrangement: .inline, action: action)
                .environment(model)
                .environment(store)
                .appTheme(model.currentTheme)
        }
    }
}
#endif
