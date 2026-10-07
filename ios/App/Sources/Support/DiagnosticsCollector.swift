import Foundation
import MachO
import MetricKit
import PaloAllyKit

/// Collects the system's own hang, crash and CPU diagnostics (MetricKit) into
/// Documents/diagnostics/, with a pointer line in the debug log. These carry
/// what our log can't: the call stacks of a hang, even one that ended with
/// the app being killed. MetricKit hands them over on a later launch,
/// usually the next one (or the next day).
///
/// Each payload is kept as MetricKit's JSON (binary name, UUID and offset per
/// frame) plus a `.txt` with the stacks as readable as this device can make
/// them: system frames named via dladdr when the same OS build is still
/// loaded. Frames in PaloAlly itself stay `PaloAlly.debug.dylib + offset`;
/// symbolicate those with the build that produced them (its image UUID is in
/// the file), e.g. `atos -o <app>/PaloAlly.debug.dylib -l 0 <offset>`.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsCollector()
    private static let keep = 20
    private let queue = DispatchQueue(label: "diagnostics", qos: .utility)

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// The saved reports, newest first.
    static var files: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted(by: >).map { directory.appendingPathComponent($0) }
    }

    /// Called once, from app launch.
    func start() {
        MXMetricManager.shared.add(self)
        // Payloads delivered before this launch subscribed (they stay
        // available for a while, so the same ones come back each launch).
        nonisolated(unsafe) let past = MXMetricManager.shared.pastDiagnosticPayloads
        guard !past.isEmpty else { return }
        queue.async { self.save(past) }
    }

    /// Called by MetricKit off the main thread.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.sync { save(payloads) }
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let fm = FileManager.default
        let dir = Self.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = DateFormatter()
        names.dateFormat = "yyyyMMdd-HHmmss"
        names.locale = Locale(identifier: "en_US_POSIX")
        for p in payloads {
            let json = p.jsonRepresentation()
            // Named by the period it covers, so a payload seen again is skipped.
            let base = "\(names.string(from: p.timeStampBegin))-\(Self.kind(p))"
            let url = dir.appendingPathComponent(base + ".json")
            if fm.fileExists(atPath: url.path) { continue }
            try? json.write(to: url)
            try? Self.readable(p, json: json).write(to: dir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
            debugLog("[diag] \(Self.summary(p)) → Documents/diagnostics/\(base).json")
        }
        prune(dir)
    }

    private static func kind(_ p: MXDiagnosticPayload) -> String {
        if !(p.crashDiagnostics ?? []).isEmpty { return "crash" }
        if !(p.hangDiagnostics ?? []).isEmpty { return "hang" }
        if !(p.cpuExceptionDiagnostics ?? []).isEmpty { return "cpu" }
        return "other"
    }

    private static func summary(_ p: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        if let h = p.hangDiagnostics, !h.isEmpty {
            parts.append("hang " + h.map { "\(Int($0.hangDuration.converted(to: .milliseconds).value)) ms" }.joined(separator: ", "))
        }
        if let c = p.crashDiagnostics, !c.isEmpty {
            parts.append("crash " + c.map { d in
                [d.exceptionType.map { "exception \($0)" }, d.signal.map { "signal \($0)" }, d.terminationReason]
                    .compactMap { $0 }.joined(separator: " ")
            }.joined(separator: ", "))
        }
        if let c = p.cpuExceptionDiagnostics, !c.isEmpty { parts.append("cpu exception ×\(c.count)") }
        if let d = p.diskWriteExceptionDiagnostics, !d.isEmpty { parts.append("disk writes ×\(d.count)") }
        if parts.isEmpty { parts.append("diagnostic") }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return parts.joined(separator: "; ") + " (\(f.string(from: p.timeStampBegin))–\(f.string(from: p.timeStampEnd)))"
    }

    private func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        // Names start with the date, so they sort oldest first.
        let bases = Set(files.map { ($0 as NSString).deletingPathExtension }).sorted()
        for old in bases.dropLast(Self.keep) {
            for ext in ["json", "txt"] { try? fm.removeItem(at: dir.appendingPathComponent("\(old).\(ext)")) }
        }
    }

    // MARK: readable stacks

    /// The payload's diagnostics with their stacks, heaviest path first.
    private static func readable(_ p: MXDiagnosticPayload, json: Data) -> String {
        var out = "\(summary(p))\n"
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return out }
        let images = loadedImages()
        for (key, list) in root where key.hasSuffix("Diagnostics") {
            guard let list = list as? [[String: Any]] else { continue }
            for d in list {
                out += "\n== \(key)\n"
                if let meta = d["diagnosticMetaData"] as? [String: Any] {
                    for k in ["appVersion", "appBuildVersion", "osVersion", "deviceType", "hangDuration",
                              "exceptionType", "signal", "terminationReason", "totalCPUTime", "totalSampledTime"] {
                        if let v = meta[k] { out += "\(k): \(v)\n" }
                    }
                }
                guard let tree = d["callStackTree"] as? [String: Any],
                      let stacks = tree["callStacks"] as? [[String: Any]] else { continue }
                for (i, stack) in stacks.enumerated() {
                    let attributed = stack["threadAttributed"] as? Bool ?? false
                    out += "-- stack \(i)\(attributed ? " (the thread at fault)" : "")\n"
                    for frame in (stack["callStackRootFrames"] as? [[String: Any]]) ?? [] {
                        write(frame, depth: 0, images: images, into: &out)
                    }
                }
            }
        }
        return out
    }

    private static func write(_ frame: [String: Any], depth: Int, images: [String: UInt], into out: inout String) {
        guard depth < 400 else { return }
        let name = frame["binaryName"] as? String ?? "?"
        let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uintValue ?? 0
        let samples = (frame["sampleCount"] as? NSNumber)?.intValue ?? 0
        var line = "\(String(repeating: " ", count: min(depth, 60)))\(name) + 0x\(String(offset, radix: 16))"
        if let uuid = frame["binaryUUID"] as? String, let base = images[uuid.uppercased()],
           let symbol = symbolName(at: base + offset) {
            line += "  \(symbol)"
        }
        if samples > 1 { line += "  ×\(samples)" }
        out += line + "\n"
        // Siblings are alternative paths (sampled); show each, heaviest first.
        let subs = (frame["subFrames"] as? [[String: Any]]) ?? []
        for sub in subs.sorted(by: { (($0["sampleCount"] as? NSNumber)?.intValue ?? 0) > (($1["sampleCount"] as? NSNumber)?.intValue ?? 0) }) {
            write(sub, depth: depth + 1, images: images, into: &out)
        }
    }

    /// Image UUID → load address, for everything loaded in this process.
    private static func loadedImages() -> [String: UInt] {
        var map: [String: UInt] = [:]
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i) else { continue }
            if let uuid = imageUUID(header) { map[uuid] = UInt(bitPattern: header) }
        }
        return map
    }

    private static func imageUUID(_ header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == UInt32(MH_MAGIC_64) else { return nil }
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == UInt32(LC_UUID) {
                let u = cmd.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: u).uuidString
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return nil
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let demangle: Demangle? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: Demangle.self)
    }()

    private static func symbolName(at address: UInt) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let sname = info.dli_sname else { return nil }
        var name = String(cString: sname)
        if let demangle, let d = demangle(sname, strlen(sname), nil, nil, 0) {
            name = String(cString: d)
            free(d)
        }
        let delta = address - UInt(bitPattern: info.dli_saddr)
        return "\(name) + \(delta)"
    }
}
