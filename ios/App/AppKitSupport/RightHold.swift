import AppKit

/// Holding the right mouse button anywhere in a window talks, as holding the
/// composer does: Bento Term's right-hold (GhosttyTerminalSurface_macOS,
/// rightMouseDown/Up), for every window of the app instead of one terminal.
///
/// Bento's way, kept: the press does nothing on the way down; a timer in the
/// common run loop modes (it fires while the button is held) turns it into
/// voice after 0.25 s; released before that it was a plain right click, and
/// gets what a right click always got. Here that is the system's (context
/// menus on rows, messages, panes, text), which UIKit opens on the way
/// DOWN, so the down is held back and both halves are posted again, in
/// order, when the click turns out short. Moved further than a few points
/// before the threshold, the press is a drag and goes on as the system's.
///
/// Text fields too: a hold there talks like anywhere else, a short right
/// click still opens the field's own menu (Bento's surface has no exception
/// either). Control-click is a left click and keeps its menu at once.
///
/// The app hears the hold as `PaloAllyRightHold` notifications (phase
/// begin/move/end/cancel, the point in the window's top-left coordinates as
/// UIKit has them, and the window's toolbar identifier), in MacRightHold.
@MainActor
final class RightHold {
    static let shared = RightHold()

    /// Bento Term's `voiceHoldThreshold`.
    static let threshold: TimeInterval = 0.25
    /// How far the pointer may drift before the threshold and still be a hold.
    static let slop: CGFloat = 6
    static let note = Notification.Name("PaloAllyRightHold")

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// The press held back (nil: no press, or it is the system's).
    private var down: NSEvent?
    private var last: NSPoint = .zero
    private var timer: Timer?
    private var holding = false
    private weak var window: NSWindow?
    /// Events posted back for the system, let through untouched when they
    /// come round (known by type and time: they keep their own). A menu
    /// opened by the press may take its release itself, so this is not a count.
    private var replayed: [(NSEvent.EventType, TimeInterval)] = []

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let e = event
            nonisolated(unsafe) var out: NSEvent?
            MainActor.assumeIsolated { out = RightHold.shared.handle(e) }
            return out
        }
        // The window lost (another app came forward mid-hold): the hold ends without a word sent.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            let w = note.object as? NSWindow
            MainActor.assumeIsolated {
                let me = RightHold.shared
                guard me.holding, w === me.window else { return }
                me.holding = false
                me.down = nil
                me.post("cancel", at: me.last, in: w)
            }
        }
        #if DEBUG
        watchMenus()
        #endif
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if let i = replayed.firstIndex(where: { $0.0 == e.type && $0.1 == e.timestamp }) {
            replayed.remove(at: i)
            return e
        }
        switch e.type {
        case .rightMouseDown:
            timer?.invalidate()
            guard e.window != nil, !holding else { return e }
            down = e
            window = e.window
            last = e.locationInWindow
            let t = Timer(timeInterval: Self.threshold, repeats: false) { _ in
                MainActor.assumeIsolated { RightHold.shared.held() }
            }
            RunLoop.current.add(t, forMode: .common)
            timer = t
            return nil
        case .rightMouseDragged:
            if holding {
                last = e.locationInWindow
                post("move", at: last, in: window)
                return nil
            }
            guard let d = down else { return e }
            let p = e.locationInWindow
            guard hypot(p.x - d.locationInWindow.x, p.y - d.locationInWindow.y) > Self.slop else {
                last = p
                return nil
            }
            // A drag, not a hold: the system's from here, its press first.
            timer?.invalidate()
            down = nil
            passBack(d, e)
            log("moved off before the threshold: the press is the system's")
            return nil
        case .rightMouseUp:
            timer?.invalidate()
            timer = nil
            if holding {
                holding = false
                down = nil
                post("end", at: e.window === window ? e.locationInWindow : last, in: window)
                return nil
            }
            guard let d = down else { return e }
            // A short right click: the system gets it as it came.
            down = nil
            passBack(d, e)
            log("short right click (\(Int((e.timestamp - d.timestamp) * 1000)) ms): passed on")
            return nil
        default:
            return e
        }
    }

    /// A press that turned out not to be a hold, to the system as it came.
    private func passBack(_ events: NSEvent...) {
        replayed = events.map { ($0.type, $0.timestamp) }
        for e in events { NSApplication.shared.postEvent(e, atStart: false) }
    }

    /// Held past the threshold: voice, in this window.
    private func held() {
        timer = nil
        guard down != nil, let window else { return }
        holding = true
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        post("begin", at: last, in: window)
    }

    private func post(_ phase: String, at p: NSPoint, in window: NSWindow?) {
        guard let window else { return }
        let frame = window.contentView?.superview ?? window.contentView
        let height = frame?.bounds.height ?? window.frame.height
        NotificationCenter.default.post(name: Self.note, object: nil, userInfo: [
            "phase": phase, "x": Double(p.x), "y": Double(height - p.y),
            "toolbar": window.toolbar?.identifier ?? "",
            "window": String(describing: type(of: window)),
        ])
    }

    func log(_ text: String) {
        #if DEBUG
        NotificationCenter.default.post(name: Self.note, object: nil, userInfo: ["phase": "log", "text": text])
        #endif
    }

    #if DEBUG
    /// Menus opened, for the log; while a `rightPress:` drill runs they
    /// close again after a second (nobody is there to close them).
    private var menuObserver: NSObjectProtocol?
    var drilling = false

    private func watchMenus() {
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu else { return }
                let titles = menu.items.prefix(6).map { $0.isSeparatorItem ? "|" : $0.title }
                RightHold.shared.log("menu opened: \(menu.items.count) items [\(titles.joined(separator: ", "))]")
                guard RightHold.shared.drilling else { return }
                nonisolated(unsafe) let open = menu
                let t = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { open.cancelTracking() }
                }
                RunLoop.current.add(t, forMode: .common)
            }
        }
    }
    #endif
}

extension ImmersiveWindows {
    /// Holding the right mouse button talks (RightHold).
    @objc func installRightHold() {
        RightHold.shared.install()
    }

    #if DEBUG
    /// `spec` "x,y,seconds[,ex,ey]" in the window's top-left coordinates: a
    /// right press at x,y held that long (and moved to ex,ey on the way),
    /// queued for a popover's window when one is up (Palo's), else the key window, as a real one is, without moving the
    /// pointer.
    @objc func rightPress(_ spec: String) -> String {
        let v = spec.split(separator: ",").compactMap { Double($0) }
        guard v.count >= 3,
              // A popover's window when one is up (Palo's), else the key window.
              let window = NSApplication.shared.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") })
                ?? NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first(where: { $0.toolbar?.identifier.hasPrefix("palo.main") == true }),
              let frame = window.contentView?.superview else { return "no window" }
        RightHold.shared.drilling = true
        RightHold.shared.log("windows: " + NSApplication.shared.windows.filter(\.isVisible).map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))
        let h = frame.bounds.height
        let start = NSPoint(x: v[0], y: h - v[1])
        let end = v.count >= 5 ? NSPoint(x: v[3], y: h - v[4]) : start
        let hold = v[2]
        var steps: [(NSEvent.EventType, Double, NSPoint)] = [(.mouseMoved, 0, start), (.rightMouseDown, 0.15, start)]
        if end != start {
            // Slides there after the threshold, arriving just before the release.
            let a = RightHold.threshold + 0.1, b = max(a, hold - 0.15)
            for k in 1...8 {
                let f = Double(k) / 8
                let p = NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
                steps.append((.rightMouseDragged, 0.15 + a + (b - a) * f, p))
            }
        }
        steps.append((.rightMouseUp, 0.15 + hold, end))
        let number = window.windowNumber
        for (type, delay, p) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: number, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .rightMouseUp || type == .mouseMoved ? 0 : 1) {
                    NSApplication.shared.postEvent(e, atStart: false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + 3) {
            MainActor.assumeIsolated { RightHold.shared.drilling = false }
        }
        return "right press at \(Int(v[0])),\(Int(v[1])) in a \(type(of: window)) \(Int(window.frame.width))x\(Int(window.frame.height)) for \(hold) s\(end != start ? " to \(Int(v[3])),\(Int(v[4]))" : "")"
    }
    #endif
}
