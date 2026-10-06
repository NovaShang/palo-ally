import UIKit

/// ⌘[ on large screens: pop one page off the navigation stack the owner is
/// looking at. Several stacks can be on screen at once (the 「它」 sidebar,
/// the conversation, 成果); the narrow layout keeps the off-screen places
/// alive beside the window. Only stacks actually inside the window count, and
/// of those the rightmost one with something pushed (成果, then 「它」). A
/// sheet or preview on top has its own way out (Esc / its buttons).
@MainActor
enum NavigationBack {
    /// A sheet, popover or preview on top: close it (SwiftUI's own
    /// presentations follow along). Returns whether there was one.
    @discardableResult
    static func dismissPresented() -> Bool {
        guard let root = keyWindow()?.rootViewController else { return false }
        var top: UIViewController?
        var next = root.presentedViewController
        while let vc = next, !vc.isBeingDismissed { top = vc; next = vc.presentedViewController }
        guard let top else { return false }
        top.dismiss(animated: true)
        return true
    }

    @discardableResult
    static func popVisible() -> Bool {
        guard let window = keyWindow(), let root = window.rootViewController else { return false }
        if let presented = root.presentedViewController, !presented.isBeingDismissed { return false }
        var best: UINavigationController?
        var bestX = -CGFloat.infinity
        func visit(_ vc: UIViewController) {
            if let nav = vc as? UINavigationController, nav.viewControllers.count > 1,
               nav.view.window === window, !nav.view.isHidden, nav.view.alpha > 0.01 {
                let frame = nav.view.convert(nav.view.bounds, to: window)
                let visible = frame.intersection(window.bounds)
                if visible.width > 40, visible.height > 40, frame.midX > bestX {
                    best = nav
                    bestX = frame.midX
                }
            }
            for child in vc.children { visit(child) }
        }
        visit(root)
        guard let best else { return false }
        best.popViewController(animated: true)
        return true
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
    }
}
