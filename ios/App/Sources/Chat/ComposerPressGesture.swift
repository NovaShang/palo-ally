import PaloAllyKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Hold-to-talk on the composer field, ported from bento's `VoicePressGesture`
/// (single finger here: the field is not a scrolling surface).
///
/// Why UIKit instead of SwiftUI's `DragGesture(minimumDistance: 0)`: a UIKit
/// recognizer sees `touchesBegan` the instant the finger lands, whatever the
/// scroll view or the text field underneath do with the touch, so recording
/// and the arming motion start in the same frame. One recognizer owns the
/// whole press → hold → drag → release lifecycle:
/// - `onTouchDown` — finger landed (return false to ignore this touch);
/// - lifted before `holdThreshold` without moving → `onTap`;
/// - moved past `slop` / cancelled before it → `onAbandon` (a scroll);
/// - held past it → `.began`, then `.changed` while dragging, `.ended` on release.
@MainActor
final class ComposerPressRecognizer: UIGestureRecognizer {
    var holdThreshold: TimeInterval = 0.22
    var slop: CGFloat = 12
    /// The touch's own timestamp (system uptime) is passed along so the delay
    /// before we heard about it can be measured.
    var onTouchDown: ((TimeInterval) -> Bool)?
    var onTap: (() -> Void)?
    var onAbandon: (() -> Void)?

    private var touch: UITouch?
    private var start: CGPoint = .zero
    private var timer: Timer?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        timer?.invalidate()
        timer = nil
        touch = nil
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        if touch != nil {
            // A second finger before the hold committed: some other gesture.
            abandon()
            return
        }
        guard touches.count == 1, let t = touches.first, let view else {
            state = .failed
            return
        }
        touch = t
        start = t.location(in: view)
        guard onTouchDown?(t.timestamp) ?? true else {
            state = .failed
            return
        }
        let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .possible, self.touch != nil else { return }
                // Committed: from here the touch belongs to voice.
                self.cancelsTouchesInView = true
                self.state = .began
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch), let view else { return }
        switch state {
        case .possible:
            let p = touch.location(in: view)
            if hypot(p.x - start.x, p.y - start.y) > slop { abandon() }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        switch state {
        case .possible:
            timer?.invalidate()
            onTap?()
            state = .failed
        case .began, .changed:
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        if state == .began || state == .changed {
            state = .cancelled
        } else if state == .possible {
            abandon()
        }
    }

    private func abandon() {
        timer?.invalidate()
        onAbandon?()
        state = .failed
    }
}

/// SwiftUI wrapper. `onHold` gets `.began` / `.changed` / `.ended` /
/// `.cancelled` after the hold commits, with the finger in `space`.
struct ComposerPressGesture: UIGestureRecognizerRepresentable {
    var holdThreshold: TimeInterval
    var space: NamedCoordinateSpace
    var onTouchDown: (TimeInterval) -> Bool
    var onTap: () -> Void
    var onAbandon: () -> Void
    var onHold: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> ComposerPressRecognizer {
        let r = ComposerPressRecognizer()
        r.delegate = context.coordinator
        apply(r)
        return r
    }

    func updateUIGestureRecognizer(_ recognizer: ComposerPressRecognizer, context: Context) {
        apply(recognizer)
    }

    func handleUIGestureRecognizerAction(_ recognizer: ComposerPressRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed, .ended, .cancelled:
            onHold(recognizer.state, context.converter.location(in: space))
        default:
            break
        }
    }

    private func apply(_ r: ComposerPressRecognizer) {
        r.holdThreshold = holdThreshold
        r.onTouchDown = onTouchDown
        r.onTap = onTap
        r.onAbandon = onAbandon
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // Never wait on (or block) anything else: the scroll view keeps
        // scrolling, and we still hear the touch the moment it lands.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Timing from the finger landing to the mic being live, written to the
/// exportable debug log so a device's log shows where the time goes.
enum VoiceTiming {
    nonisolated(unsafe) private static var origin: TimeInterval = 0

    /// `touchTime` is the touch's timestamp (system uptime); nil = now.
    static func begin(_ what: String, touchTime: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        origin = touchTime ?? now
        debugLog("[voice-timing] \(what), heard \(Int((now - origin) * 1000))ms after the touch")
    }

    static func mark(_ what: String) {
        guard origin > 0 else { return }
        debugLog("[voice-timing] \(what)\(suffix)")
    }

    /// " (+123ms)" while a press is recent; voice-package logs get it appended.
    static var suffix: String {
        guard origin > 0 else { return "" }
        let dt = ProcessInfo.processInfo.systemUptime - origin
        return dt < 15 ? " (+\(Int(dt * 1000))ms)" : ""
    }
}
