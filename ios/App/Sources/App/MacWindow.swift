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

/// An entry of a menu in the Mac window toolbar (built as a UIMenu): an
/// action, or with `children` a submenu (`inline`: a titled section).
struct MacMenuItem {
    var title: String
    var image: String? = nil
    var checked = false
    var destructive = false
    var disabled = false
    var children: [MacMenuItem]? = nil
    var inline = false
    var action: () -> Void = {}
}

/// What the open page puts in the Mac window toolbar, left of the right
/// pane's button: its ⋯ menu, and a workspace's ＋ (a new pane).
struct MacToolbarMenus {
    var menu: [MacMenuItem]? = nil
    var add: [MacMenuItem]? = nil
}

/// The Mac: the page's menus in the window toolbar while it is shown.
/// `signature` says when they changed (they hold actions, not values).
/// They belong to the conversation the page was made for: the toolbar shows
/// them only while the window still shows that one (`macToolbarPage`), and a
/// new selection drops them at once (WindowModel.selection), so a page that
/// lingers (its removal animating, a late disappear) can't leave its ＋ or
/// ⋯ on the next page.
private struct MacToolbarMenusHost: ViewModifier {
    let menus: () -> MacToolbarMenus
    let signature: String
    @Environment(WindowModel.self) private var model
    @State private var token = UUID()
    /// The window's conversation when this page came up.
    @State private var page: WindowModel.Conversation?

    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content
                .onChange(of: signature, initial: true) { publish() }
                .onAppear { publish() }
                .onDisappear {
                    // Only its own: the next page may have put its menus up first.
                    guard model.macToolbarOwner == token else { return }
                    model.clearMacToolbarMenus()
                }
        } else {
            content
        }
    }

    private func publish() {
        if page == nil { page = model.selection }
        // A page on its way out (the window moved on) doesn't put its menus back.
        guard let page, page == model.selection else { return }
        model.macToolbarOwner = token
        model.macToolbarPage = page
        model.macToolbarMenus = menus()
    }
}

extension View {
    /// The Mac: this page's ⋯ and ＋ as window toolbar items (MacToolbar).
    func macToolbarMenus(signature: String, _ menus: @escaping () -> MacToolbarMenus) -> some View {
        modifier(MacToolbarMenusHost(menus: menus, signature: signature))
    }
}

/// Mac: a standard window toolbar with the system sidebar toggle by the
/// traffic lights (it shows and hides the list) and 成果 at the trailing
/// edge, and no window title. The orb isn't in the toolbar: it floats at the
/// top of the assistant's conversation (ChatView). Each column keeps its own
/// navigation bar inside it. Installed once per window; elsewhere it does
/// nothing.
struct MacWindowChrome: ViewModifier {
    let model: WindowModel

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
    let model: WindowModel

    func makeUIView(context: Context) -> InstallView { InstallView(model: model) }
    func updateUIView(_ view: InstallView, context: Context) {}

    final class InstallView: UIView {
        let model: WindowModel
        init(model: WindowModel) {
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
    static let object: NSObject? = {
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
    static let pageMenu = NSToolbarItem.Identifier("palo.pageMenu")
    static let addPane = NSToolbarItem.Identifier("palo.addPane")
    static let library = NSToolbarItem.Identifier("palo.library")
}

/// The window toolbar, the title bar row's right-hand group
/// (docs/workbench-design/mac-titlebar.html): the open page's ⋯, a
/// workspace's ＋ (a new pane), and the right pane's button last. System
/// items, so they take their clicks by construction. Nothing that can
/// overflow. The sidebar's button is the capsule's (SidebarCollapse); the
/// page's identity is the page's own, in the middle of the row.
@MainActor
final class MacToolbar: NSObject, NSToolbarDelegate {
    private static var installed: [ObjectIdentifier: MacToolbar] = [:]

    private let model: WindowModel
    /// One identifier per window: AppKit keeps toolbars that share one in
    /// step across windows.
    private let toolbar = NSToolbar(identifier: "palo.main.\(UUID().uuidString)")

    static func install(on scene: UIWindowScene, model: WindowModel) {
        let key = ObjectIdentifier(scene)
        guard installed[key] == nil, let titlebar = scene.titlebar else { return }
        // Windows closed since let go of their toolbars (and their models).
        let open = Set(UIApplication.shared.connectedScenes.map(ObjectIdentifier.init))
        installed = installed.filter { open.contains($0.key) }
        let bar = MacToolbar(model: model)
        installed[key] = bar
        titlebar.titleVisibility = .hidden
        titlebar.toolbarStyle = .unified
        titlebar.separatorStyle = .none
        titlebar.toolbar = bar.toolbar
        AppKitBundle.immerseWindows(toolbar: "palo.main")
        MacRightHold.install()
    }

    /// The model of the window whose toolbar is `id` (MacRightHold).
    static func model(toolbar id: String) -> WindowModel? {
        installed.values.first { $0.toolbar.identifier == id }?.model
    }

    /// Every window's model.
    static var models: [WindowModel] { installed.values.map(\.model) }

    private init(model: WindowModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        track()
    }

    /// The separator that follows the sidebar's edge, room, and the pane's
    /// button; the page's items go in before that (`refresh`).
    private static let items: [NSToolbarItem.Identifier] = [
        .primarySidebarTrackingSeparatorItemIdentifier, .flexibleSpace, .library,
    ]
    private static let pageItems: [NSToolbarItem.Identifier] = [.pageMenu, .addPane]

    /// Follows the page's menus (they come and go with the page).
    private func track() {
        withObservationTracking {
            _ = model.macToolbarMenus
            _ = model.macToolbarPage
            _ = model.selection
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
    }

    private func refresh() {
        let menus = model.currentMacToolbarMenus
        let wanted = Self.pageItems.filter { menuItems(for: $0, in: menus) != nil }
        let shown = toolbar.items.map(\.itemIdentifier).filter(Self.pageItems.contains)
        if shown != wanted {
            for i in toolbar.items.indices.reversed() where Self.pageItems.contains(toolbar.items[i].itemIdentifier) {
                toolbar.removeItem(at: i)
            }
            let at = toolbar.items.firstIndex { $0.itemIdentifier == .library } ?? toolbar.items.count
            for (k, id) in wanted.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: at + k) }
            debugLog("[toolbar] page items \(wanted.map(\.rawValue)) for \(model.selection?.storageKey ?? "-")")
        }
        for case let item as NSMenuToolbarItem in toolbar.items {
            if let entries = menuItems(for: item.itemIdentifier, in: menus) { item.itemMenu = UIMenu(children: Self.elements(entries)) }
        }
    }

    private func menuItems(for id: NSToolbarItem.Identifier, in menus: MacToolbarMenus?) -> [MacMenuItem]? {
        switch id {
        case .pageMenu: menus?.menu
        case .addPane: menus?.add
        default: nil
        }
    }

    private static func elements(_ entries: [MacMenuItem]) -> [UIMenuElement] {
        entries.map { e in
            let image = e.image.flatMap { UIImage(systemName: $0) }
            if let children = e.children {
                return UIMenu(title: e.title, image: image, options: e.inline ? .displayInline : [], children: elements(children))
            }
            var attributes: UIMenuElement.Attributes = []
            if e.destructive { attributes.insert(.destructive) }
            if e.disabled { attributes.insert(.disabled) }
            let action = e.action
            return UIAction(title: e.title, image: image, attributes: attributes, state: e.checked ? .on : .off) { _ in action() }
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items + Self.pageItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .library:
            let button = UIBarButtonItem(image: UIImage(systemName: "sidebar.trailing"), style: .plain,
                                         target: self, action: #selector(toggleLibrary))
            let item = NSToolbarItem(itemIdentifier: id, barButtonItem: button)
            item.label = String(localized: "右侧栏")
            item.toolTip = String(localized: "显示或隐藏右侧栏 ⌘2")
            item.visibilityPriority = .high
            return item
        case .pageMenu, .addPane:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            let add = id == .addPane
            item.image = UIImage(systemName: add ? "plus" : "ellipsis")
            item.showsIndicator = false
            item.label = add ? String(localized: "新窗格") : String(localized: "更多")
            item.toolTip = add ? String(localized: "在右边分出一个会话 ⌘D") : nil
            item.visibilityPriority = .high
            if let entries = menuItems(for: id, in: model.currentMacToolbarMenus) { item.itemMenu = UIMenu(children: Self.elements(entries)) }
            return item
        default:
            return nil
        }
    }

    @objc private func toggleLibrary() { model.toggleLibrary() }
}
#endif
