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
        Self.reportClicks()
        Self.takeWheelOverText()
        Self.offerCopy()
    }

    private static var copyMonitor: Any?

    /// ⌘C is offered to the app first (`PaloAllyCopy`): text selected in a
    /// file preview is copied from there even when the keyboard stayed with
    /// the composer (11-04: ⌘C copied nothing, the right-click menu did).
    /// When the app copied (`handled`), the key goes no further.
    private static func offerCopy() {
        guard copyMonitor == nil else { return }
        copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
            let result = NSMutableDictionary()
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: NSNotification.Name("PaloAllyCopy"), object: nil, userInfo: ["result": result])
            }
            return result["handled"] as? Bool == true ? nil : event
        }
    }

    private static var wheelMonitor: Any?

    /// A mouse wheel's notches over text being edited (11-04): UIKit doesn't
    /// pass them to the text view while it edits (a trackpad's scroll does
    /// get there), and many of them took the app down in UIKit's event
    /// handling. Each notch is offered to the app first (`PaloAllyWheel`,
    /// with the place and lines); when the app scrolls a text view with it
    /// (it sets `handled`), the event goes no further.
    private static func takeWheelOverText() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // A trackpad (or a Magic Mouse) has precise deltas and phases: left alone.
            guard !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
                  let window = event.window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
                  let frame = window.contentView?.superview else { return event }
            // An event without a window has its place on the screen.
            let at = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            let result = NSMutableDictionary()
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: NSNotification.Name("PaloAllyWheel"), object: nil, userInfo: [
                    "x": Double(at.x), "y": Double(frame.bounds.height - at.y),
                    "lines": Double(event.scrollingDeltaY), "result": result,
                ])
            }
            return result["handled"] as? Bool == true ? nil : event
        }
    }

    private static var clickMonitor: Any?

    /// Every left click in an app window, for the app's debug log (posted as
    /// `PaloAllyClick`; the app adds what UIKit makes of it): where it
    /// landed in the window's top-left coordinates, whether the window was
    /// key, the click count, and which AppKit view takes it (the app's
    /// content gets it as UINSInputView; a toolbar item is the titlebar's).
    /// Buttons that "take a few clicks" (10-29) are told apart this way.
    private static func reportClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if let window = event.window, let frame = window.contentView?.superview {
                    let top = frame.bounds.height - event.locationInWindow.y
                    var chain: [String] = []
                    var v = frame.hitTest(event.locationInWindow)
                    while let view = v, chain.count < 3 {
                        chain.append(String(describing: type(of: view)))
                        v = view.superview
                    }
                    NotificationCenter.default.post(name: NSNotification.Name("PaloAllyClick"), object: nil, userInfo: [
                        "x": Double(event.locationInWindow.x), "y": Double(top),
                        "key": window.isKeyWindow, "count": event.clickCount,
                        "appkit": chain.joined(separator: " < "),
                    ])
                }
            }
            return event
        }
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

    /// The pointer moved to "x,y" (as `click:` has them) and resting there,
    /// in a few steps as a hand's: hovers only, no click.
    @objc func move(_ spec: String) -> String {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.keyWindow.flatMap({ $0.toolbar?.identifier.hasPrefix(id) == true ? $0 : nil })
                ?? NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
              let frame = window.contentView?.superview else { return "no window" }
        let xy = spec.split(separator: ",").compactMap { Double($0) }
        guard xy.count == 2 else { return "bad point" }
        let p = NSPoint(x: xy[0], y: frame.bounds.height - xy[1])
        let number = window.windowNumber
        for k in 0...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.05) {
                let q = NSPoint(x: p.x - Double(4 - k) * 6, y: p.y + Double(4 - k) * 4)
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: q, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: number, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    NSApplication.shared.postEvent(e, atStart: false)
                }
            }
        }
        return "moved to \(Int(xy[0])),\(Int(xy[1]))"
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

    /// ⌘C pressed, as the keyboard does, queued for the app.
    @objc func pressCopy() -> String {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
              let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                                       isARepeat: false, keyCode: 8) else { return "no window" }
        NSApplication.shared.postEvent(e, atStart: false)
        return "pressed ⌘C"
    }

    /// Keys pressed one by one, as the keyboard does: letters, digits,
    /// space, ↑↓←→; `\n` Return; `⌘x` that key with ⌘. Queued for the app,
    /// a key every 80 ms, the app brought in front first. An input method
    /// doesn't compose them (they come in as the letters): `compose:` for that.
    @objc func pressKeys(_ spec: String) -> String {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.toolbar != nil })
        else { return "no window" }
        let wasActive = NSApplication.shared.isActive
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            " ": 49, "\n": 36, "↓": 125, "↑": 126, "←": 123, "→": 124,
        ]
        var keys: [(Character, NSEvent.ModifierFlags)] = []
        var command = false
        for c in spec {
            if c == "⌘" { command = true; continue }
            keys.append((c, command ? .command : []))
            command = false
        }
        for (i, (c, flags)) in keys.enumerated() {
            guard let code = codes[c] else { continue }
            let arrows: [Character: Int] = ["↑": 0xF700, "↓": 0xF701, "←": 0xF702, "→": 0xF703]
            let chars = c == "\n" ? "\r" : arrows[c].map { String(UnicodeScalar($0)!) } ?? String(c)
            for (k, type) in [NSEvent.EventType.keyDown, .keyUp].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.08 + Double(k) * 0.03) {
                    // A keyboard's event underneath (UIKit reads that one), queued for this app only.
                    guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown) else { return }
                    cg.flags = flags.contains(.command) ? .maskCommand : []
                    let units = Array(chars.utf16)
                    cg.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    if let e = NSEvent(cgEvent: cg) { NSApplication.shared.postEvent(e, atStart: false) }
                }
            }
        }
        return "pressed \(keys.count) keys (the app \(wasActive ? "was" : "wasn't") in front)"
    }

    /// A mouse wheel turned at "x,y" (as `click:` has them) by `lines` lines,
    /// "x,y,lines" (negative: towards the end), in a few notches as a hand's:
    /// a real wheel event, queued for the app as one from the mouse is.
    @objc func scroll(_ spec: String) -> String {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.keyWindow.flatMap({ $0.toolbar?.identifier.hasPrefix(id) == true ? $0 : nil })
                ?? NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
              let frame = window.contentView?.superview else { return "no window" }
        let v = spec.split(separator: ",").compactMap { Double($0) }
        guard v.count == 3 else { return "bad spec" }
        let local = NSPoint(x: v[0], y: frame.bounds.height - v[1])
        let screen = window.convertPoint(toScreen: local)
        let main = NSScreen.screens.first?.frame.height ?? 0
        let notches = 6
        for k in 0..<notches {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(k) * 0.05) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: Int32(v[2] / Double(notches)), wheel2: 0, wheel3: 0) else { return }
                cg.location = CGPoint(x: screen.x, y: main - screen.y)
                if let e = NSEvent(cgEvent: cg) { NSApplication.shared.postEvent(e, atStart: false) }
            }
        }
        return "scrolled \(Int(v[2])) lines at \(Int(v[0])),\(Int(v[1]))"
    }

    /// A left drag from "x1,y1" to "x2,y2" (as `click:` has them), pressed,
    /// moved a step a frame and let go as a hand does: a divider dragged.
    @objc func drag(_ spec: String) -> String {
        guard let id = Self.toolbarID,
              let window = NSApplication.shared.keyWindow.flatMap({ $0.toolbar?.identifier.hasPrefix(id) == true ? $0 : nil })
                ?? NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix(id) == true }),
              let frame = window.contentView?.superview else { return "no window" }
        let v = spec.split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { return "bad points" }
        let h = frame.bounds.height
        let a = NSPoint(x: v[0], y: h - v[1]), b = NSPoint(x: v[2], y: h - v[3])
        var steps: [(NSEvent.EventType, Double, NSPoint)] = [(.mouseMoved, 0, a), (.mouseMoved, 0.15, a), (.leftMouseDown, 0.4, a)]
        for k in 1...30 {
            let f = Double(k) / 30
            steps.append((.leftMouseDragged, 0.5 + f * 0.5, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)))
        }
        steps.append((.leftMouseUp, 1.1, b))
        let number = window.windowNumber
        for (type, delay, p) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: number, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1) {
                    NSApplication.shared.postEvent(e, atStart: false)
                }
            }
        }
        return "dragged \(Int(v[0])),\(Int(v[1])) to \(Int(v[2])),\(Int(v[3]))"
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
