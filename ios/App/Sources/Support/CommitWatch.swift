import PaloAllyKit
import UIKit

/// When the views' latest changes have reached the screen: the end of the
/// next UI update's Core Animation commit (UIKit's update link, iOS 18),
/// with what the commit cost the main thread. The store measures what a
/// reply's tick costs with it (`[reveal]`), and the fade its frames. The
/// frame's display-link callbacks (the glass's springs, the orb) come
/// before the commit and aren't counted: they run whether or not a reply is
/// being written.
@MainActor
final class CommitWatch {
    static let shared = CommitWatch()

    #if !targetEnvironment(macCatalyst)
    private var link: UIUpdateLink?
    #endif
    private var waiting: [@MainActor (Double) -> Void] = []
    /// CPU time at the end of the frame's display-link callbacks.
    private var commitBegan = 0.0

    /// Calls back at the end of the next commit with the main-thread CPU
    /// seconds it took (SwiftUI's update, layout and drawing, after the
    /// frame's display-link callbacks). Without an update link (Mac), up to
    /// the current transaction's completion instead (an upper bound).
    func afterCommit(_ done: @escaping @MainActor (Double) -> Void) {
        #if !targetEnvironment(macCatalyst)
        if let link = link ?? makeLink() {
            waiting.append(done)
            link.isEnabled = true
            return
        }
        #endif
        let began = Self.threadCPU()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done(Self.threadCPU() - began) } }
    }

    #if !targetEnvironment(macCatalyst)
    private func makeLink() -> UIUpdateLink? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        // Not continuous (the default): it only rides along updates that
        // happen anyway, never asks for frames of its own.
        let link = UIUpdateLink(windowScene: scene)
        link.addAction(to: .afterCADisplayLinkDispatch) { [weak self] _, _ in
            self?.commitBegan = Self.threadCPU()
        }
        link.addAction(to: .afterCATransactionCommit) { [weak self] link, _ in
            guard let self else { return }
            link.isEnabled = false
            let done = waiting
            waiting = []
            let commit = commitBegan > 0 ? Self.threadCPU() - commitBegan : 0
            commitBegan = 0
            for d in done { d(commit) }
        }
        self.link = link
        return link
    }
    #endif

    static func threadCPU() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000
    }
}

/// Drives a store's reveal ticks (`RevealPacer`) from a display link at
/// 15 Hz, so each tick (~67 ms) lands at the start of a frame. It runs in
/// every run-loop mode: the text keeps coming while the list is dragged.
@MainActor
final class DisplayLinkRevealClock: RevealClock {
    private var link: CADisplayLink?
    private var tick: (@MainActor (TimeInterval) -> Bool)?
    private var last = 0.0
    /// No ticks until then (system uptime): see `hold`.
    private static var heldUntil = 0.0
    /// How far the pacers' time is behind the real one after a hold, and
    /// when that was last brought up to date.
    private static var lag = 0.0
    private static var lagAt = 0.0

    /// Holds every reply's reveal for `seconds` (a spoken message's words
    /// flying to their place: the list mustn't move under them). The pacers'
    /// clock stands still meanwhile and then runs at twice the speed until
    /// it has caught up, so what arrived in between comes at a quick, even
    /// pace instead of all at once (which cost a frame of 50–60 ms).
    static func hold(seconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        _ = pacersNow(now)
        heldUntil = max(heldUntil, now + seconds)
    }

    /// The pacers' time: the real one, less what's left of a hold's lag.
    private static func pacersNow(_ now: TimeInterval) -> TimeInterval {
        let dt = max(0, now - lagAt)
        lagAt = now
        if now < heldUntil {
            lag += dt
        } else if lag > 0 {
            // Held until part way through dt; catch up for the rest.
            let held = max(0, min(dt, heldUntil - (now - dt)))
            lag = max(0, lag + held - (dt - held))
        }
        return now - lag
    }

    func start(_ tick: @escaping @MainActor (TimeInterval) -> Bool) {
        self.tick = tick
        if link == nil {
            let link = CADisplayLink(target: LinkTarget { [weak self] in self?.fire() }, selector: #selector(LinkTarget.fire))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    private func fire() {
        let now = ProcessInfo.processInfo.systemUptime
        // The link may come faster than asked (other content on screen).
        guard now - last >= 0.055 else { return }
        let paced = Self.pacersNow(now)
        guard now >= Self.heldUntil else { return }
        last = now
        // Each tick's growth is one short animation: the scroll view's bottom
        // anchor glides the list along instead of jumping a line at a time
        // (design §3.6; the scroll lab showed the anchor animates with it).
        if ChatMotion.with(ChatMotion.follow, { tick?(paced) }) != true {
            tick = nil
            link?.isPaused = true
        }
    }
}

/// A display link's target that doesn't keep its owner alive.
@MainActor
final class LinkTarget: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func fire() { action() }
}
