import PaloAllyKit
import PaloAllyVoice
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
///
/// While the field is being edited the same recognizer sits on the text field
/// itself, beside its own selection gestures: `shouldCommit` decides at the
/// threshold (nothing records before), a pointer must stay within
/// `pointerSlop`, and committing cancels the text view's gestures for this
/// press (`cancelsOthersOnCommit`) so the hold doesn't also select text.
@MainActor
final class ComposerPressRecognizer: UIGestureRecognizer {
    var holdThreshold: TimeInterval = 0.22
    var slop: CGFloat = 12
    /// A mouse or trackpad pointer's slop (it holds still far better than a finger); nil = `slop`.
    var pointerSlop: CGFloat?
    /// Asked when the threshold passes: false = not a hold for voice, the touch stays the text view's.
    var shouldCommit: (() -> Bool)?
    var cancelsOthersOnCommit = false
    /// The touch's own timestamp (system uptime) is passed along so the delay
    /// before we heard about it can be measured.
    var onTouchDown: ((TimeInterval) -> Bool)?
    var onTap: (() -> Void)?
    var onAbandon: (() -> Void)?

    private var touch: UITouch?
    private var start: CGPoint = .zero
    private var timer: Timer?
    private var activeSlop: CGFloat = 12

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
        let pointer = t.type == .indirectPointer || ProcessInfo.processInfo.isMacCatalystApp
        activeSlop = pointer ? (pointerSlop ?? slop) : slop
        guard onTouchDown?(t.timestamp) ?? true else {
            state = .failed
            return
        }
        let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .possible, self.touch != nil else { return }
                if let shouldCommit = self.shouldCommit, !shouldCommit() {
                    self.timer = nil
                    self.state = .failed
                    return
                }
                if self.cancelsOthersOnCommit { self.cancelTextGestures() }
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
            if hypot(p.x - start.x, p.y - start.y) > activeSlop { abandon() }
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

    /// The text view under the press drops what its own gestures were doing
    /// with it (selecting, the loupe): toggling `isEnabled` cancels a
    /// recognizer, and the touch already down never reaches it again. Only
    /// the text view and the views inside it, never SwiftUI's host.
    private func cancelTextGestures() {
        var chain: [UIView] = []
        var v = touch?.view
        while let current = v, current !== view {
            chain.append(current)
            if current is UITextView { break }
            v = current.superview
        }
        guard chain.last is UITextView else {
            debugLog("[hold] no text view under the press: its gestures are left alone")
            return
        }
        var n = 0
        for current in chain {
            for g in current.gestureRecognizers ?? [] where g !== self && g.isEnabled {
                g.isEnabled = false
                g.isEnabled = true
                n += 1
            }
        }
        debugLog("[hold] the text view's \(n) gestures let go of the press")
    }
}

/// SwiftUI wrapper. `onHold` gets `.began` / `.changed` / `.ended` /
/// `.cancelled` after the hold commits, with the finger in `space`.
struct ComposerPressGesture: UIGestureRecognizerRepresentable {
    var holdThreshold: TimeInterval
    var space: NamedCoordinateSpace
    var pointerSlop: CGFloat? = nil
    var shouldCommit: (() -> Bool)? = nil
    var cancelsOthersOnCommit = false
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

    func apply(_ r: ComposerPressRecognizer) {
        r.holdThreshold = holdThreshold
        r.pointerSlop = pointerSlop
        r.shouldCommit = shouldCommit
        r.cancelsOthersOnCommit = cancelsOthersOnCommit
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

#if targetEnvironment(macCatalyst)
/// The Mac's way of putting the press on the composer: the same recognizer on
/// a real UIKit view. A SwiftUI gesture representable stays in the hover
/// table after its view has gone, and the next hover update aborts in
/// AttributeGraph reading it (seven quits on one Mac, 10-20 to 11-19, as a
/// page went or the field let the keyboard go).
private struct ComposerPressCatcher: UIViewRepresentable {
    let press: ComposerPressGesture
    /// Where the field's touches go: the catcher itself (over an idle
    /// field), or the text view in front of it (the field being edited).
    let onTextView: Bool
    /// The catcher's corner in `press.space`.
    let origin: CGPoint

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = !onTextView
        v.onTextView = onTextView
        let r = v.press
        r.delegate = context.coordinator
        r.addTarget(context.coordinator, action: #selector(Coordinator.acted(_:)))
        context.coordinator.catcher = v
        update(v, context)
        return v
    }

    func updateUIView(_ v: CatcherView, context: Context) { update(v, context) }

    private func update(_ v: CatcherView, _ context: Context) {
        press.apply(v.press)
        context.coordinator.origin = origin
        context.coordinator.onHold = press.onHold
    }

    static func dismantleUIView(_ v: CatcherView, coordinator: Coordinator) {
        coordinator.onHold = nil
        v.detach()
    }

    final class CatcherView: UIView {
        let press = ComposerPressRecognizer()
        var onTextView = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return detach() }
            guard onTextView else {
                if press.view !== self { addGestureRecognizer(press) }
                return
            }
            // The hosting view holding both this and the text view.
            var v = superview
            while let current = v, !NSStringFromClass(type(of: current)).contains("HostingView") { v = current.superview }
            let host = v ?? window
            if press.view !== host {
                detach()
                host?.addGestureRecognizer(press)
            }
        }

        func detach() { press.view?.removeGestureRecognizer(press) }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var catcher: CatcherView?
        var origin: CGPoint = .zero
        var onHold: ((UIGestureRecognizer.State, CGPoint) -> Void)?

        @objc func acted(_ r: UIGestureRecognizer) {
            guard let catcher else { return }
            switch r.state {
            case .began, .changed, .ended, .cancelled:
                let p = r.location(in: catcher)
                onHold?(r.state, CGPoint(x: p.x + origin.x, y: p.y + origin.y))
            default:
                break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let catcher, catcher.onTextView else { return true }
            // A press on this field's own text, not elsewhere in the page.
            guard catcher.bounds.contains(touch.location(in: catcher)) else { return false }
            var v = touch.view
            while let current = v, current !== g.view {
                if let text = current as? UITextView { return text.isEditable }
                v = current.superview
            }
            return false
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

private struct ComposerPressOnMac: ViewModifier {
    let press: ComposerPressGesture
    let onTextView: Bool
    @State private var origin: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: press.space).origin } action: { origin = $0 }
            .background {
                if onTextView { ComposerPressCatcher(press: press, onTextView: true, origin: origin) }
            }
            .overlay {
                if !onTextView { ComposerPressCatcher(press: press, onTextView: false, origin: origin) }
            }
    }
}
#endif

extension View {
    /// Hold-to-talk on this view (`onTextView`: beside the gestures of the
    /// text view it is).
    @ViewBuilder
    func composerPress(_ press: ComposerPressGesture, onTextView: Bool = false) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(ComposerPressOnMac(press: press, onTextView: onTextView))
        #else
        gesture(press)
        #endif
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
        voiceTouchUptime = origin
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
