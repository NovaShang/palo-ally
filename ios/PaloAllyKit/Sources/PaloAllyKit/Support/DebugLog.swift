import Foundation
import os

/// A plain-text log file the owner can export from Settings, after bento's
/// `DebugLogger`: so a real-device incident (a dropped connection, a voice
/// failure) can be diagnosed from one file. Truncated at launch, thread-safe,
/// mirrored to os_log. Never write message contents or secrets here — only
/// what happened (states, errors, timings).
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()

    public let fileURL: URL
    private let handle: FileHandle?
    private let lock = OSAllocatedUnfairLock()
    private let os = Logger(subsystem: "com.novashang.paloally", category: "debug")
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("debug.log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil) // truncate on launch
        handle = try? FileHandle(forWritingTo: fileURL)
        let info = Bundle.main.infoDictionary
        log("=== PaloAlly \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?") · \(info?["PaloAllyCommit"] as? String ?? "dev")) ===")
    }

    public func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let entry = "[\(Self.stamp.string(from: Date()))] [\((file as NSString).lastPathComponent):\(line)] \(message)\n"
        lock.withLock {
            handle?.write(Data(entry.utf8))
        }
        os.debug("\(message, privacy: .public)")
    }
}

/// Shorthand.
public func debugLog(_ message: String, file: String = #fileID, line: Int = #line) {
    DebugLog.shared.log(message, file: file, line: line)
}
