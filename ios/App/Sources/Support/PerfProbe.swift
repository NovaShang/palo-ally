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
    private static var counts: [String: Int] = [:]
    private static var link: CADisplayLink?
    private static var target = Linker()
    private static var last: CFTimeInterval = 0
    private static var deltas: [Double] = []
    private static var windowStart: CFTimeInterval = 0
    private static var cpuStart: Double = 0
    private static var mainStart: Double = 0
    private static var mainThread: thread_act_t = 0

    /// A body ran.
    @inline(__always) static func count(_ name: String) {
        guard on else { return }
        counts[name, default: 0] += 1
    }

    /// `n` more of something (rows measured, say).
    @inline(__always) static func add(_ name: String, _ n: Int) {
        guard on, n > 0 else { return }
        counts[name, default: 0] += n
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
        debugLog("[perf] meter on")
    }

    fileprivate static func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if last > 0 { deltas.append((now - last) * 1000) }
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
