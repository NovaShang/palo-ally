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
        #if DEBUG
        Self.logTitlebarClicks()
        #endif
    }

    #if DEBUG
    private static var clickMonitor: Any?

    /// A click in the title bar row: which AppKit view takes it (the app's
    /// content gets it as UINSInputView; anything else is the titlebar's).
    private static func logTitlebarClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if let window = event.window, let frame = window.contentView?.superview {
                    let top = frame.bounds.height - event.locationInWindow.y
                    if top < 60 {
                        var chain: [String] = []
                        var v = frame.hitTest(event.locationInWindow)
                        while let view = v, chain.count < 4 {
                            chain.append(String(describing: type(of: view)))
                            v = view.superview
                        }
                        NSLog("[titlebar-click] %d,%d: %@", Int(event.locationInWindow.x), Int(top), chain.joined(separator: " < "))
                    }
                }
            }
            return event
        }
    }
    #endif

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
        // Full screen: AppKit takes the toolbar out of the content into a band
        // of its own above it (the owner saw it as a separate title bar).
        // Hide it there; the page keeps its own controls. Back on leaving.
        let full = window.styleMask.contains(.fullScreen)
        if let bar = window.toolbar, bar.isVisible == full { bar.isVisible = !full }
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

    /// The pointer over a split workspace's divider: "h" the left-right resize
    /// cursor, "v" the up-down one, anything else the arrow again.
    @objc func setResizeCursor(_ kind: String) {
        switch kind {
        case "h": NSCursor.resizeLeftRight.set()
        case "v": NSCursor.resizeUpDown.set()
        default: NSCursor.arrow.set()
        }
    }

    #if DEBUG
    /// `spec` "x,y|x,y" in the window's top-left coordinates: for each
    /// point, the AppKit view a click there goes to and its ancestors
    /// (whether the titlebar takes it or the app's content gets it).
    @objc func hitChain(_ spec: String) -> String {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.windows.first(where: { $0.toolbar?.identifier == id }),
              let frame = window.contentView?.superview else { return "no window" }
        var lines: [String] = []
        for item in spec.split(separator: "|") {
            let xy = item.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { continue }
            let p = NSPoint(x: xy[0], y: frame.bounds.height - xy[1])
            var chain: [String] = []
            var v = frame.hitTest(frame.convert(p, to: frame.superview))
            while let view = v, chain.count < 4 {
                chain.append(String(describing: type(of: view)))
                v = view.superview
            }
            lines.append("\(Int(xy[0])),\(Int(xy[1])): \(chain.joined(separator: " < "))")
        }
        return lines.joined(separator: "\n")
    }

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
