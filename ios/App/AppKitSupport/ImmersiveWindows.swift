import AppKit

/// AppKit work for the Mac app that UIKit has no API for, in a bundle the
/// Catalyst app loads from its PlugIns (MacWindow.swift, AppKitBundle).
///
/// The window that shows the app's toolbar runs its content under the
/// titlebar: a full-size content view under a transparent titlebar, the
/// traffic lights and the toolbar's items floating over the conversation,
/// with no band and no separator. The titlebar still drags the window
/// where there's no control.
@MainActor
@objc(PaloAllyImmersiveWindows)
final class ImmersiveWindows: NSObject {
    private static var toolbarID: NSToolbar.Identifier?
    private static var observers: [NSObjectProtocol] = []

    /// Makes every window showing the toolbar `id` immersive: now, or as
    /// soon as AppKit has put the toolbar in its window, and again whenever
    /// one comes forward (AppKit may redo its titlebar around full screen).
    @objc func immerseWindows(withToolbar id: String) {
        Self.toolbarID = id
        if Self.observers.isEmpty {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                Self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    let window = note.object as? NSWindow
                    MainActor.assumeIsolated { _ = window.map(Self.apply) }
                })
            }
        }
        Self.applyAll(tries: 30)
    }

    /// The scene's window and its toolbar come a little after UIKit asks for
    /// them: tries every 0.1 s until one is there.
    private static func applyAll(tries: Int) {
        let applied = NSApplication.shared.windows.map(apply).contains(true)
        guard !applied, tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { applyAll(tries: tries - 1) }
        }
    }

    @discardableResult
    private static func apply(_ window: NSWindow) -> Bool {
        guard let id = toolbarID, window.toolbar?.identifier == id else { return false }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        return true
    }
}
