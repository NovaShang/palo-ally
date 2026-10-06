import Foundation
import PaloAllyKit

#if DEBUG
/// DEBUG only: notices when the main thread stops answering and logs how long
/// it was stuck, so a hang shows up in the debug log with a timestamp instead
/// of only as a frozen window.
enum StallWatchdog {
    /// Stalls at least this long are logged (`-stallThresholdMs 50` for a
    /// finer look, e.g. during the resize test).
    static let threshold: TimeInterval = {
        let ms = UserDefaults.standard.double(forKey: "stallThresholdMs")
        return ms > 0 ? ms / 1000 : 0.25
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
        while answered.wait(timeout: .now() + threshold) == .timedOut {
            if !reported {
                reported = true
                debugLog("[stall] main thread busy for more than \(Int(threshold * 1000)) ms…")
            }
        }
        let took = Date().timeIntervalSince(sent)
        if took >= threshold { debugLog("[stall] main thread was stuck \(Int(took * 1000)) ms") }
        queue.asyncAfter(deadline: .now() + 0.1) { probe() }
    }
}
#endif
