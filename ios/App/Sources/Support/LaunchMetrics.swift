import Darwin
import Foundation
import PaloAllyKit

/// Two numbers for the chat's budgets (design §6), written to the debug log
/// in every build: how long after the process started the conversation was
/// first laid out with messages in it (`[launch]`), and the app's memory
/// footprint, the number iOS judges memory by (`[mem]`).
enum LaunchMetrics {
    @MainActor private(set) static var conversationLogged = false

    /// The conversation was laid out with `messages` in it, `laidOut` of
    /// them in full: the first time, log how long that took from launch.
    @MainActor static func conversationLaidOut(messages: Int, laidOut: Int) {
        guard !conversationLogged, messages > 0 else { return }
        conversationLogged = true
        let ms = processStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        debugLog("[launch] conversation laid out \(ms) ms after the process started (\(messages) messages, \(laidOut) laid out)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            logFootprint("5 s after the conversation appeared")
        }
    }

    @MainActor static func logFootprint(_ when: String) {
        guard let mb = footprintMB else { return }
        debugLog(String(format: "[mem] footprint %.0f MB, %@", mb, when))
    }

    /// When this process started (from the kernel).
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }()

    /// Physical footprint in MB.
    static var footprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
