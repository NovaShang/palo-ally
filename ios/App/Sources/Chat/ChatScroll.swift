import PaloAllyKit
import SwiftUI

/// What the chat's scroll code reads from the scroll view, and its logs.
enum ChatScroll {
    /// What the coordinator reads from ScrollGeometry.
    struct Metrics: Equatable {
        /// From the end of the content to the bottom of what the reader can
        /// see (above the composer and keyboard); 0 on the end.
        var distanceFromBottom: CGFloat
        /// Composer + keyboard + home indicator: grows when the keyboard rises.
        var bottomInset: CGFloat
        var insetTop: CGFloat
        /// Where the list is scrolled to, and how tall it is.
        var offsetY: CGFloat
        var contentHeight: CGFloat
        /// The whole visible height (the insets included) and width.
        var viewport: CGFloat
        var width: CGFloat

        init(_ g: ScrollGeometry) {
            distanceFromBottom = ChatScrollMath.distanceFromBottom(
                contentHeight: g.contentSize.height, visibleMaxY: g.visibleRect.maxY, bottomInset: g.contentInsets.bottom)
            bottomInset = g.contentInsets.bottom
            insetTop = g.contentInsets.top
            offsetY = g.contentOffset.y
            contentHeight = g.contentSize.height
            viewport = g.visibleRect.height
            width = g.visibleRect.width
        }
    }

    /// The latest distance from the end (for the logs).
    @MainActor static var lastDistance: CGFloat = 0

    /// A change between following the end and reading back in history,
    /// persisted (all builds): `[scroll] following → detached (drag), 412 pt
    /// from the end`. States and numbers only.
    @MainActor static func log(_ what: String) {
        debugLog("[scroll] \(what), \(Int(lastDistance)) pt from the end")
        ChatSignposts.chat.emitEvent("scroll", "\(what)")
    }

    #if DEBUG
    /// The latest distance from the end, for the jump drill's log.
    @MainActor static var debugDistance: CGFloat { lastDistance }
    @MainActor static var traced = 0
    @MainActor static var lastTrace = ""
    /// `-pinTrace YES`: the scroll coordinator's phases and decisions (and,
    /// with `-pinTraceFrames YES`, every frame of the reader's scroll).
    @MainActor static let pinTraceOn = UserDefaults.standard.bool(forKey: "pinTrace")
    @MainActor static var pinTraced = 0
    @MainActor static func pinTrace(_ what: String) {
        guard pinTraceOn, pinTraced < 2000 else { return }
        pinTraced += 1
        debugLog("[pin] \(what), \(Int(debugDistance)) pt from the end")
    }
    @MainActor static weak var uiScrollView: UIScrollView?
    /// `-scrollTrace YES`: content height / offset as layout sees them (first 20 000 changes).
    @MainActor static let traceOn = UserDefaults.standard.bool(forKey: "scrollTrace")
    @MainActor static func trace(_ g: ScrollGeometry) {
        guard traceOn, traced < 20_000 else { return }
        var line = "h=\(Int(g.contentSize.height)) y=\(Int(g.contentOffset.y)) vis=\(Int(g.visibleRect.minY))-\(Int(g.visibleRect.maxY)) inset=\(Int(g.contentInsets.top)),\(Int(g.contentInsets.bottom))"
        if let sv = uiScrollView {
            // What UIKit holds and shows, beside what SwiftUI reports.
            let anims = sv.layer.animationKeys()?.joined(separator: ",") ?? ""
            line += " | ui y=\(Int(sv.contentOffset.y)) h=\(Int(sv.contentSize.height)) shown=\(Int(sv.layer.presentation()?.bounds.origin.y ?? -1))\(anims.isEmpty ? "" : " anim=\(anims)")"
        }
        guard line != lastTrace else { return }
        lastTrace = line
        traced += 1
        debugLog("[geo] \(line)")
    }
    #endif
}

/// Small glass circle above the composer while the reader is up in history:
/// tap to jump to the newest text and follow it again. Neutral, not themed;
/// only its dot, for something new below that the reader hasn't seen, takes
/// the theme color. The system glass button: a hand-made interactive glass
/// circle inside a plain button took the touches for its own press effect,
/// so taps often never reached the button.
struct JumpToLatestButton: View {
    /// A message (or more of one) arrived below since the reader scrolled up.
    var hasNew: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.primary) // the glass style draws its label in the tint
        .overlay(alignment: .topTrailing) {
            if hasNew {
                // On the circle's edge, up and to the right.
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: -7, y: 2)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: hasNew)
        .accessibilityLabel(hasNew ? "回到最新，下面有新消息" : "回到最新")
        .accessibilityIdentifier("jumpToLatest")
    }
}

/// The chat's motion: following a reply as it's written, and a sent
/// message rising to the top (design §3.5). One short ease each, given to
/// the changes themselves (a reveal tick, a send) so the scroll view's own
/// bottom anchor carries the list along with them; nothing animates under
/// Reduce Motion.
@MainActor
enum ChatMotion {
    /// A reveal tick's growth: about three tick-to-tick gaps, so
    /// consecutive ones blend into one glide.
    static var follow: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2) }
    /// A sent message rising to the top of the view.
    static var send: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.45) }

    /// Runs `body` in a transaction carrying `animation` (none: no animation).
    static func with<T>(_ animation: Animation?, _ body: () throws -> T) rethrows -> T {
        var t = Transaction(animation: animation)
        t.disablesAnimations = animation == nil
        return try withTransaction(t, body)
    }
}

#if DEBUG
/// `-frameTrace YES`: from a send (or a reply starting) until the reply is
/// written, every frame's scroll position as shown on screen (the UIKit
/// scroll view's presentation layer) and how late the frame came. Logs one
/// `[frames]` line per reply, in two parts: the send (its message rising,
/// the first 0.8 s) and the rest, the reply being written and followed. For
/// each: frames the main thread delivered late, as hitch time in ms per
/// second (Apple's hitch ratio; budget < 5 ms/s), and, while following, the
/// largest step between two frames (a line jumped shows as a step the height
/// of a line; a glide as several small ones).
@MainActor
final class FrameWatch {
    static let shared = FrameWatch()
    static let on = UserDefaults.standard.bool(forKey: "frameTrace")
    private struct Part {
        var frames = 0, late = 0
        var hitch = 0.0, seconds = 0.0
        var steps: [CGFloat] = []
        func line(_ name: String) -> String {
            let sorted = steps.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
            return String(format: "%@ %d frames over %.1f s, %d late, hitches %.0f ms (%.1f ms/s), largest step %.1f pt, p95 %.1f pt, %d over 15 pt",
                          name, frames, seconds, late, hitch, hitch / max(seconds, 0.001), sorted.last ?? 0, p95, sorted.filter { $0 > 15 }.count)
        }
    }
    private var link: CADisplayLink?
    /// Measuring a segment (the link runs all along: a link made at a
    /// send came late itself for its first frames).
    private var measuring = false
    private var label = ""
    private var began: CFTimeInterval = 0
    private var riseUntil: CFTimeInterval = 0
    private var last: CFTimeInterval?
    private var lastY: CGFloat?
    private var rise = Part()
    private var rest = Part()
    private var end = Part()
    /// When the reply was finished (its final message): the frames after
    /// count apart.
    private var endedAt: CFTimeInterval?
    var running: Bool { measuring }
    /// Following the end (only those frames' steps count).
    var following: () -> Bool = { true }

    /// `rising`: a send, whose first 0.8 s are counted apart.
    func start(_ label: String, rising: Bool) {
        guard Self.on else { return }
        if measuring { stop() }
        self.label = label
        began = CACurrentMediaTime()
        riseUntil = rising ? began + 0.8 : began
        (rise, rest, end, endedAt) = (Part(), Part(), Part(), nil)
        measuring = true
        if link == nil {
            let link = CADisplayLink(target: LinkTarget { [weak self] in self?.frame() }, selector: #selector(LinkTarget.fire))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// The reply is finished: what follows is its end, counted apart.
    func replyEnded() {
        guard measuring, endedAt == nil else { return }
        endedAt = CACurrentMediaTime()
    }

    func stop() {
        guard measuring else { return }
        measuring = false
        let now = CACurrentMediaTime()
        let ended = endedAt ?? now
        rise.seconds = max(0, min(ended, riseUntil) - began)
        rest.seconds = max(0, ended - max(began, riseUntil))
        end.seconds = max(0, now - ended)
        debugLog("[frames] \(label): " + (rise.frames > 0 ? rise.line("rising") + "; " : "") + rest.line("then") + "; " + end.line("ending"))
    }

    private func frame() {
        guard let link else { return }
        guard measuring else {
            last = link.timestamp
            lastY = ChatScroll.uiScrollView.map { $0.layer.presentation()?.bounds.origin.y ?? $0.contentOffset.y }
            return
        }
        let rising = link.timestamp < riseUntil
        let ending = endedAt.map { link.timestamp >= $0 } ?? false
        var part = ending ? end : rising ? rise : rest
        part.frames += 1
        if let last {
            let gap = link.timestamp - last
            if gap > link.duration * 1.5 {
                part.late += 1
                part.hitch += (gap - link.duration) * 1000
                if part.late <= 8 {
                    debugLog(String(format: "[frames] late: %.0f ms after the last, %.2f s in", gap * 1000, link.timestamp - began))
                }
            }
        }
        // Frames since the last callback (more than one when it came late:
        // an animation goes on meanwhile, so its move counts per frame).
        let frames = last.map { max(1, ((link.timestamp - $0) / link.duration).rounded()) } ?? 1
        last = link.timestamp
        if let sv = ChatScroll.uiScrollView {
            let y = sv.layer.presentation()?.bounds.origin.y ?? sv.contentOffset.y
            if let lastY, following(), !sv.isTracking, !sv.isDecelerating {
                let step = abs(y - lastY) / frames
                part.steps.append(step)
                if step > 15, !rising, !ending {
                    debugLog(String(format: "[frames] a step of %.0f pt, %.2f s in", step, link.timestamp - began))
                }
            }
            lastY = y
        }
        if ending { end = part } else if rising { rise = part } else { rest = part }
    }
}
#endif
