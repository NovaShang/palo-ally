#if DEBUG || PERF_HARNESS
import Darwin
import PaloAllyKit
import QuartzCore
import UIKit

/// `-perfMeter YES` (DEBUG, or a Release build with `PERF_HARNESS`): every
/// `-perfWindow` seconds (default 5) logs `[perf]` with the process's and
/// the main thread's CPU, the frames the display link saw (median, 95th
/// percentile, worst, and hitches: frames late by half a frame or more), and
/// how many times the counted view bodies ran.
@MainActor
enum PerfProbe {
    static let on = UserDefaults.standard.bool(forKey: "perfMeter")
    static let alternate = UserDefaults.standard.bool(forKey: "perfAlternate")
    private static let longFrames = UserDefaults.standard.bool(forKey: "perfLongFrames")
    private static var counts: [String: Int] = [:]
    /// The same, since the last `takeStep()` (a `-demoActions` step's own).
    private static var stepCounts: [String: Int] = [:]
    private static var link: CADisplayLink?
    private static var target = Linker()
    private static var last: CFTimeInterval = 0
    private static var deltas: [Double] = []
    /// The frames since the last `takeStep()`, and the main thread's CPU then.
    private static var stepDeltas: [Double] = []
    private static var stepMain: Double = 0
    private static var windowStart: CFTimeInterval = 0
    private static var cpuStart: Double = 0
    private static var mainStart: Double = 0
    private static var mainThread: thread_act_t = 0

    /// A body ran.
    @inline(__always) static func count(_ name: String) {
        guard on else { return }
        counts[name, default: 0] += 1
        stepCounts[name, default: 0] += 1
    }

    /// `n` more of something (rows measured, say).
    @inline(__always) static func add(_ name: String, _ n: Int) {
        guard on, n > 0 else { return }
        counts[name, default: 0] += n
        stepCounts[name, default: 0] += n
    }

    /// The bodies counted since the last call, most first; starts the next step.
    static func takeStep() -> String {
        defer { stepCounts = [:] }
        return frameStats() + " | " + stepCounts.sorted { $0.value > $1.value || $0.value == $1.value && $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    /// The step's frames: how many, the median, 95th percentile and worst
    /// gap, the ones late by half a frame or more, and the main thread's CPU
    /// time; starts the next step's.
    private static func frameStats() -> String {
        let sorted = stepDeltas.sorted()
        func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        // Late by half a frame or more against the display's own pace.
        let hitches = stepDeltas.filter { $0 > max(q(0.5), 8.3) * 1.5 }.count
        let main = mainThread == 0 ? 0 : threadCPU(mainThread)
        defer { stepDeltas.removeAll(keepingCapacity: true); stepMain = main }
        return String(format: "frames %d p50 %.1f p95 %.1f max %.1f ms hitches %d main %.0f ms",
                      stepDeltas.count, q(0.5), q(0.95), sorted.last ?? 0, hitches, (main - stepMain) * 1000)
    }

    static func start() {
        guard on, link == nil else { return }
        mainThread = mach_thread_self()
        if alternate { PerfSwitch.driving = false }
        let l = CADisplayLink(target: target, selector: #selector(Linker.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        windowStart = CACurrentMediaTime()
        cpuStart = processCPU()
        mainStart = threadCPU(mainThread)
        stepMain = mainStart
        debugLog("[perf] meter on")
    }

    fileprivate static func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if last > 0 {
            let gap = (now - last) * 1000
            deltas.append(gap)
            stepDeltas.append(gap)
            // `-perfLongFrames YES`: each frame of 50 ms or more, when it ended
            // (to line it up with what the log says happened then).
            if gap >= 50, longFrames { debugLog(String(format: "[perf] long frame %.0f ms", gap)) }
        }
        last = now
        let window = UserDefaults.standard.object(forKey: "perfWindow") != nil
            ? UserDefaults.standard.double(forKey: "perfWindow") : 5
        guard now - windowStart >= window else { return }
        let wall = now - windowStart
        let cpu = processCPU(), main = threadCPU(mainThread)
        let pct = (cpu - cpuStart) / wall * 100, mainPct = (main - mainStart) / wall * 100
        let expected = (l.targetTimestamp - l.timestamp) * 1000
        let sorted = deltas.sorted()
        func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let hitches = deltas.filter { $0 > max(expected, 8.3) * 1.5 }.count
        let top = counts.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        let label = alternate ? (PerfSwitch.driving ? "drive " : "rest  ") : ""
        if alternate { PerfSwitch.driving.toggle() }
        debugLog(String(format: "[perf] \(label)cpu %.0f%% main %.0f%% frames %d p50 %.1f p95 %.1f max %.1f ms hitches %d | ",
                        pct, mainPct, deltas.count, q(0.5), q(0.95), sorted.last ?? 0, hitches) + top)
        deltas.removeAll(keepingCapacity: true)
        counts = [:]
        windowStart = now
        cpuStart = cpu
        mainStart = main
    }

    private static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    private static func threadCPU(_ t: thread_act_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(t, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    @MainActor final class Linker: NSObject {
        @objc func tick(_ l: CADisplayLink) { PerfProbe.tick(l) }
    }
}
#endif
