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

    /// Where the traffic lights end, and the middle of their line, in the
    /// window's top-left coordinates as "x,y"; x is 0 in full screen (they
    /// are gone there), y 26 when there is no button to measure.
    @objc func leadingChrome() -> String? {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.windows.first(where: { $0.toolbar?.identifier == id }),
              let frame = window.contentView?.superview else { return nil }
        if window.styleMask.contains(.fullScreen) { return "0,26" }
        guard let zoom = window.standardWindowButton(.zoomButton) else { return "80,26" }
        let r = zoom.convert(zoom.bounds, to: nil)
        return "\(r.maxX),\(frame.bounds.height - r.midY)"
    }

    #if DEBUG
    /// The titlebar (traffic lights, toolbar items, and any band) as a PNG
    /// at `path`, transparent where it draws nothing, and its frame in the
    /// window: the app draws it over its own snapshot for the demo's
    /// `-demoSnapshot`, when the screen can't be captured. Glass comes out flat.
    @objc func snapshotTitlebar(to path: String) -> String? {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.windows.first(where: { $0.toolbar?.identifier == id }),
              let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview,
              let frame = window.contentView?.superview,
              let rep = titlebar.bitmapImageRepForCachingDisplay(in: titlebar.bounds) else { return nil }
        titlebar.cacheDisplay(in: titlebar.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSLog("[appkit] window %@ styleMask %lx transparent %d titlebar %@ contentLayoutRect %@",
              NSStringFromRect(window.frame), window.styleMask.rawValue, window.titlebarAppearsTransparent ? 1 : 0,
              NSStringFromRect(titlebar.frame), NSStringFromRect(window.contentLayoutRect))
        // In the window's top-left coordinates, as UIKit has them.
        let r = titlebar.convert(titlebar.bounds, to: nil)
        return NSStringFromRect(NSRect(x: r.minX, y: frame.bounds.height - r.maxY, width: r.width, height: r.height))
    }
    #endif
}
