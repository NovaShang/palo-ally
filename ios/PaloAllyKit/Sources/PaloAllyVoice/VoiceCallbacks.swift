import Foundation

// PaloAlly: keeps a cancelled recording quiet. A quick tap on the composer
// arms a recording and cancels it a moment later; the half-open socket then
// fails with "cancelled", and that must never reach the user as 「没连上」.

/// Each recording gets a generation; callbacks from an older one are dropped.
public struct VoiceGeneration: Sendable {
    public private(set) var current = 0
    public init() {}

    /// A new recording starts; returns its token.
    public mutating func next() -> Int {
        current += 1
        return current
    }

    /// The current recording was cancelled or finished: drop its late callbacks.
    public mutating func invalidate() { current += 1 }

    public func isCurrent(_ token: Int) -> Bool { token == current }
}

public enum VoiceErrors {
    /// Errors that only mean "we stopped it ourselves" (task / URL session /
    /// socket cancellation), not a real failure.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ECANCELED) { return true }
        return false
    }
}
