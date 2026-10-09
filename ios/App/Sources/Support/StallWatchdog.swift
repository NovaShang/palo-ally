import Foundation
import PaloAllyKit
import UIKit

/// Notices when the main thread stops answering and logs how long it was
/// stuck, so a hang shows up in the debug log with a timestamp instead of
/// only as a frozen window. Past two seconds it also writes the latest
/// breadcrumbs (what the app was doing), from its own thread, because a hang
/// that ends with the app being killed never logs anything else. The call
/// stack of a hang arrives later through MetricKit (DiagnosticsCollector).
enum StallWatchdog {
    /// Stalls at least this long are logged (`-stallThresholdMs 50` for a
    /// finer look, e.g. during the resize test). Release builds only note
    /// stalls that a person would notice.
    static let threshold: TimeInterval = {
        let ms = UserDefaults.standard.double(forKey: "stallThresholdMs")
        if ms > 0 { return ms / 1000 }
        #if DEBUG
        return 0.25
        #else
        return 1
        #endif
    }()
    /// Past this the breadcrumbs are written too (DEBUG `-stallDumpMs 250`
    /// for every stall the threshold reports).
    private static let dumpAfter: TimeInterval = {
        #if DEBUG
        let ms = UserDefaults.standard.double(forKey: "stallDumpMs")
        if ms > 0 { return ms / 1000 }
        #endif
        return 2
    }()
    private static let queue = DispatchQueue(label: "stall-watchdog", qos: .userInitiated)
    /// Called once, from app launch.
    static func start() {
        queue.async { probe() }
    }

    /// Ask the main thread to answer; measure how long it took; ask again.
    private static func probe() {
        let sent = Date()
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { answered.signal() }
        var reported = false
        var dumped = false
        var nextNote: TimeInterval = 10
        while answered.wait(timeout: .now() + min(threshold, 0.5)) == .timedOut {
            let waited = Date().timeIntervalSince(sent)
            if !reported, waited >= threshold {
                reported = true
                debugLog("[stall] main thread busy for more than \(Int(threshold * 1000)) ms…")
            }
            if !dumped, waited >= dumpAfter {
                dumped = true
                let crumbs = Breadcrumbs.shared.snapshot().suffix(20)
                debugLog("[stall] still stuck after \(Int(dumpAfter * 1000)) ms; last breadcrumbs:\n  " + crumbs.joined(separator: "\n  "))
            }
            if waited >= nextNote {
                debugLog("[stall] still stuck: \(Int(waited)) s")
                nextNote += 10
            }
        }
        let took = Date().timeIntervalSince(sent)
        if took >= threshold { debugLog("[stall] main thread was stuck \(Int(took * 1000)) ms") }
        queue.asyncAfter(deadline: .now() + 0.1) { probe() }
    }
}

/// The window's trait changes, in the debug log (`[traits]`): which traits
/// changed and how, and when, counted from the last time the scene changed
/// state. Going to the background, the system lays the whole window out
/// again for its app-switcher snapshots, in the other appearance too; this
/// says on a device what those passes changed and how far apart they came
/// (the gap is roughly what one pass cost). States and numbers only.
@MainActor
enum TraitLog {
    /// The windows watched, numbered in the order they first became key.
    private static let watched = NSMapTable<UIWindow, NSNumber>.weakToStrongObjects()
    private static var windows = 0
    private static var phase = (name: "launch", at: CACurrentMediaTime(), changes: 0)

    /// Called once, from app launch.
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let window = note.object as? UIWindow
            MainActor.assumeIsolated { if let window { watch(window) } }
        }
        let phases: [(Notification.Name, String)] = [
            (UIScene.willDeactivateNotification, "resigning active"),
            (UIScene.didEnterBackgroundNotification, "going to the background"),
            (UIScene.willEnterForegroundNotification, "coming back"),
            (UIScene.didActivateNotification, "active"),
        ]
        for (name, label) in phases {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { phase = (label, CACurrentMediaTime(), 0) }
            }
        }
    }

    private static let traits: [UITrait] = [
        UITraitUserInterfaceStyle.self, UITraitUserInterfaceLevel.self, UITraitActiveAppearance.self,
        UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self,
        UITraitDisplayScale.self, UITraitDisplayGamut.self, UITraitHorizontalSizeClass.self,
        UITraitVerticalSizeClass.self, UITraitLayoutDirection.self, UITraitSceneCaptureState.self,
        UITraitImageDynamicRange.self,
    ]

    private static func watch(_ window: UIWindow) {
        guard watched.object(forKey: window) == nil else { return }
        windows += 1
        let number = windows
        watched.setObject(NSNumber(value: number), forKey: window)
        window.registerForTraitChanges(traits) { (window: UIWindow, previous: UITraitCollection) in
            note(window, number, from: previous)
        }
    }

    private static func note(_ window: UIWindow, _ number: Int, from previous: UITraitCollection) {
        let old = describe(previous), new = describe(window.traitCollection)
        let diff = zip(old, new).filter { $0.1 != $1.1 }.map { "\($0.0) \($0.1)→\($1.1)" }
        guard !diff.isEmpty else { return }
        phase.changes += 1
        let ms = Int((CACurrentMediaTime() - phase.at) * 1000)
        let line = diff.joined(separator: ", ")
            + "; change \(phase.changes), \(ms) ms after \(phase.name); window \(number) \(type(of: window)) \(Int(window.bounds.width))×\(Int(window.bounds.height))"
        breadcrumb("traits " + line)
        debugLog("[traits] " + line)
    }

    private static func describe(_ t: UITraitCollection) -> [(String, String)] {
        let style = switch t.userInterfaceStyle { case .light: "light"; case .dark: "dark"; default: "unspecified" }
        let active = switch t.activeAppearance { case .active: "active"; case .inactive: "inactive"; default: "unspecified" }
        return [
            ("style", style),
            ("level", "\(t.userInterfaceLevel.rawValue)"),
            ("activeAppearance", active),
            ("contrast", "\(t.accessibilityContrast.rawValue)"),
            ("contentSize", t.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: "")),
            ("legibility", "\(t.legibilityWeight.rawValue)"),
            ("scale", "\(t.displayScale)"),
            ("gamut", "\(t.displayGamut.rawValue)"),
            ("sizeClass", "\(t.horizontalSizeClass.rawValue)/\(t.verticalSizeClass.rawValue)"),
            ("direction", "\(t.layoutDirection.rawValue)"),
            ("capture", "\(t.sceneCaptureState.rawValue)"),
            ("dynamicRange", "\(t.imageDynamicRange.rawValue)"),
        ]
    }
}
