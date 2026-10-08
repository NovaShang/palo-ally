import Foundation
import Observation

/// A reply being written. The store changes `messages` only when the reply
/// starts and when it ends; in between, each piece that arrives goes here
/// (`received`), and the store's ticks reveal it at an even pace
/// (`RevealPacer`, design §3.2): `text` is what's on screen. The view showing
/// it subscribes (`listen`) and updates its text directly, so not even
/// SwiftUI is involved per tick (design §3.3); `text` is also observable,
/// for anything that wants it the SwiftUI way.
@MainActor
@Observable
public final class StreamingReply {
    public let id: String
    /// What's revealed: the text on screen.
    public private(set) var text: String
    /// The same text, read without subscribing (a view that gets the ticks
    /// through `listen` reads it once without taking every update).
    @ObservationIgnored public private(set) var current: String
    @ObservationIgnored private var pacer = RevealPacer()
    @ObservationIgnored private var listeners: [Int: @MainActor (String) -> Void] = [:]
    @ObservationIgnored private var nextListener = 0

    init(id: String, text: String, at time: TimeInterval) {
        self.id = id
        self.text = ""
        current = ""
        pacer.receive(text, at: time)
    }

    /// Everything that came so far, revealed or not.
    public var received: String { pacer.received }
    /// Nothing is waiting to be revealed.
    public var isCaughtUp: Bool { pacer.isCaughtUp }
    /// The longest a piece waited between arriving and being revealed.
    public var longestWait: TimeInterval { pacer.longestWait }

    /// Calls `change` with the whole revealed text after each change. Keep
    /// the token to stop (`stopListening`).
    public func listen(_ change: @escaping @MainActor (String) -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = change
        return nextListener
    }

    public func stopListening(_ token: Int) { listeners[token] = nil }

    func receive(_ more: String, at time: TimeInterval) {
        pacer.receive(more, at: time)
    }

    /// The whole text so far (a sync): if it changed what's shown, that is
    /// revealed again from the start of its line.
    func replace(with whole: String, at time: TimeInterval) {
        pacer.replace(with: whole, at: time)
        publish()
    }

    /// One tick of the pacer. True when the revealed text changed.
    @discardableResult
    func tick(at now: TimeInterval) -> Bool {
        let began = ReplyStats.threadCPU()
        let changed = pacer.tick(at: now)
        Self.pacingCPU += ReplyStats.threadCPU() - began
        guard changed else { return false }
        publish()
        return true
    }

    /// CPU seconds the pacers have taken (for `[reveal]`).
    static var pacingCPU = 0.0

    /// Reveals the rest at once (the app is leaving the screen).
    @discardableResult
    func flush(at now: TimeInterval) -> Bool {
        guard pacer.flush(at: now) else { return false }
        publish()
        return true
    }

    /// The reply ended: what was still waiting counts as shown now (the
    /// final text puts it on screen), without telling the view twice.
    func finish(at now: TimeInterval) -> TimeInterval {
        pacer.flush(at: now)
        return pacer.longestWait
    }

    private func publish() {
        let revealed = pacer.revealed
        guard revealed != current else { return }
        current = revealed
        text = revealed
        for l in listeners.values { l(current) }
    }
}

/// What drives the reveal ticks: calls `tick` with the time (system uptime)
/// about every 70 ms until it returns false. The app uses a display link, so
/// each tick lands at the start of a frame.
@MainActor
public protocol RevealClock: AnyObject {
    func start(_ tick: @escaping @MainActor (TimeInterval) -> Bool)
}

/// Without a display (tests, or before the app sets one): a timer.
@MainActor
public final class TimerRevealClock: RevealClock {
    private var task: Task<Void, Never>?

    public init() {}

    public func start(_ tick: @escaping @MainActor (TimeInterval) -> Bool) {
        task?.cancel()
        task = Task { @MainActor in
            while !Task.isCancelled {
                guard tick(ProcessInfo.processInfo.systemUptime) else { return }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }
}
