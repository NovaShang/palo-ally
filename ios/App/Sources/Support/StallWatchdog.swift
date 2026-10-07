import Foundation
import PaloAllyKit

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
    private static let dumpAfter: TimeInterval = 2
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
                debugLog("[stall] still stuck after \(Int(dumpAfter)) s; last breadcrumbs:\n  " + crumbs.joined(separator: "\n  "))
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
