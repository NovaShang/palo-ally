import Foundation
import os

/// A plain-text log file the owner can export from Settings, after bento's
/// `DebugLogger`: so a real-device incident (a dropped connection, a voice
/// failure) can be diagnosed from one file. Thread-safe, mirrored to os_log.
/// Never write message contents or secrets here — only what happened
/// (states, errors, timings).
///
/// Each launch starts a new `debug.log`; the previous launches are kept as
/// `debug.1.log` … `debug.4.log`, because a freeze usually ends with the app
/// being killed and reopened, and the run that froze is the one that matters.
/// A log that grows past `maxBytes` rotates the same way mid-run.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()

    public let fileURL: URL
    private var handle: FileHandle?
    private var written = 0
    private let lock = OSAllocatedUnfairLock()
    private let os = Logger(subsystem: "com.novashang.paloally", category: "debug")
    private static let keep = 5
    private static let maxBytes = 4 << 20
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// This launch's log and the kept earlier ones, newest first.
    public var allFileURLs: [URL] {
        (0..<Self.keep).map { Self.url(index: $0, base: fileURL) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("debug.log")
        Self.rotate(fileURL)
        handle = try? FileHandle(forWritingTo: fileURL)
        let info = Bundle.main.infoDictionary
        log("=== PaloAlly \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?") · \(info?["PaloAllyCommit"] as? String ?? "dev")) ===")
    }

    public func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let entry = "[\(Self.stamp.string(from: Date()))] [\((file as NSString).lastPathComponent):\(line)] \(message)\n"
        let data = Data(entry.utf8)
        lock.withLock {
            if written + data.count > Self.maxBytes {
                try? handle?.close()
                Self.rotate(fileURL)
                handle = try? FileHandle(forWritingTo: fileURL)
                written = 0
            }
            handle?.write(data)
            written += data.count
        }
        os.debug("\(message, privacy: .public)")
    }

    private static func url(index: Int, base: URL) -> URL {
        index == 0 ? base : base.deletingLastPathComponent().appendingPathComponent("debug.\(index).log")
    }

    /// debug.3 → debug.4, …, debug → debug.1; then a fresh, empty debug.log.
    private static func rotate(_ base: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url(index: keep - 1, base: base))
        for i in stride(from: keep - 2, through: 0, by: -1) {
            let from = url(index: i, base: base)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: url(index: i + 1, base: base)) }
        }
        fm.createFile(atPath: base.path, contents: nil)
    }
}

/// Shorthand.
public func debugLog(_ message: String, file: String = #fileID, line: Int = #line) {
    DebugLog.shared.log(message, file: file, line: line)
}

/// The last few things the app did (voice, sync, messages, scrolling, heavy
/// layout), kept in memory. When the main thread hangs, the stall watchdog
/// writes them to the debug log from its own thread, so the log says what
/// was going on when the app stopped answering. States and sizes only —
/// never message text.
public final class Breadcrumbs: @unchecked Sendable {
    public static let shared = Breadcrumbs()
    private let lock = OSAllocatedUnfairLock()
    private var ring: [String] = []
    private static let keep = 40

    public func note(_ event: String) {
        let t = Date().timeIntervalSince1970
        let entry = String(format: "%.3f ", t.truncatingRemainder(dividingBy: 100_000)) + event
        lock.withLock {
            ring.append(entry)
            if ring.count > Self.keep { ring.removeFirst(ring.count - Self.keep) }
        }
    }

    public func snapshot() -> [String] { lock.withLock { ring } }
}

/// Shorthand.
public func breadcrumb(_ event: String) { Breadcrumbs.shared.note(event) }
