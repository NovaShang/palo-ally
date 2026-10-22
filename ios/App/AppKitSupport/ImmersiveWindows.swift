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
        guard let id = toolbarID, window.toolbar?.identifier.hasPrefix(id) == true else { return false }
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

    /// The title bar as AppKit has it, for the debug log: the window's
    /// titlebar settings, then every view of the titlebar container (class,
    /// frame, hidden, alpha; a visual effect view's material and state), so a
    /// band or a line drawn over the content can be told apart. Sizes and
    /// states only.
    @objc func titlebarFacts() -> String? {
        guard let id = Self.toolbarID else { return nil }
        var lines: [String] = []
        for window in NSApplication.shared.windows where window.toolbar?.identifier.hasPrefix(id) == true {
            let bar = window.toolbar
            lines.append("window \(Int(window.frame.width))x\(Int(window.frame.height)) key \(window.isKeyWindow ? 1 : 0) transparent \(window.titlebarAppearsTransparent ? 1 : 0) separator \(window.titlebarSeparatorStyle.rawValue) fullSize \(window.styleMask.contains(.fullSizeContentView) ? 1 : 0) toolbar style \(window.toolbarStyle.rawValue) baseline \(bar?.showsBaselineSeparator == true ? 1 : 0) visible \(bar?.isVisible == true ? 1 : 0)")
            guard let container = window.standardWindowButton(.closeButton)?.superview?.superview?.superview else { continue }
            func walk(_ v: NSView, _ depth: Int) {
                var line = String(repeating: "  ", count: depth) + String(describing: type(of: v))
                let f = v.frame
                line += " \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                if v.isHidden { line += " hidden" }
                if v.alphaValue < 1 { line += " alpha \(String(format: "%.2f", v.alphaValue))" }
                if let e = v as? NSVisualEffectView { line += " material \(e.material.rawValue) state \(e.state.rawValue) blending \(e.blendingMode.rawValue)" }
                if let c = v.layer?.backgroundColor, c.alpha > 0 { line += " fill \(String(format: "%.2f", c.alpha))" }
                lines.append(line)
                guard depth < 5 else { return }
                for sub in v.subviews where !(sub is NSButton) { walk(sub, depth + 1) }
            }
            walk(container, 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Where the traffic lights end, and the middle of their line, in the
    /// window's top-left coordinates as "x,y"; x is 0 in full screen (they
    /// are gone there), y 26 when there is no button to measure.
    @objc func leadingChrome() -> String? {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
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
              let window = NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
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

    /// A left click at "x,y" (the window's top-left coordinates, as UIKit
    /// has them) queued for the front app window as a real one is (the
    /// title bar's own handling included), paced like a hand's, without
    /// moving the pointer: the whole path a click takes.
    @objc func click(_ spec: String) -> String {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.keyWindow.flatMap({ $0.toolbar?.identifier.hasPrefix(id) == true ? $0 : nil })
                ?? NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
              let frame = window.contentView?.superview else { return "no window" }
        let xy = spec.split(separator: ",").compactMap { Double($0) }
        guard xy.count == 2 else { return "bad point" }
        let p = NSPoint(x: xy[0], y: frame.bounds.height - xy[1])
        // As a hand does it: the pointer arrives, rests, presses, lets go.
        let steps: [(NSEvent.EventType, Double)] = [(.mouseMoved, 0), (.mouseMoved, 0.15), (.leftMouseDown, 0.4), (.leftMouseUp, 0.52)]
        let number = window.windowNumber
        for (type, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let e = NSEvent.mouseEvent(with: type, location: type == .mouseMoved && delay == 0 ? NSPoint(x: p.x - 6, y: p.y + 4) : p,
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApplication.shared.postEvent(e, atStart: false)
                }
            }
        }
        let m = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return "clicked \(Int(xy[0])),\(Int(xy[1])) in \(Int(window.frame.width))x\(Int(window.frame.height)); the pointer at \(Int(m.x)),\(Int(frame.bounds.height - m.y))"
    }

    /// The titlebar (traffic lights, toolbar items, and any band) as a PNG
    /// at `path`, transparent where it draws nothing, and its frame in the
    /// window: the app draws it over its own snapshot for the demo's
    /// `-demoSnapshot`, when the screen can't be captured. Glass comes out flat.
    @objc func snapshotTitlebar(to path: String) -> String? {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
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
