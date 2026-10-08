import os
import PaloAllyKit
import SwiftUI
import UIKit

/// The one owner of the conversation's scroll position (design §3.6). The
/// views only say what happened or what they want (the reader scrolled,
/// something was sent, 「回到最新」, show this message); the reducer
/// (`ChatScrollMachine`) decides, and this carries it out through the scroll
/// view's `ScrollPosition`. Following the live end is the system's own
/// bottom anchor, which holds only while the view sits exactly on the end;
/// this puts it back there whenever following starts again.
///
/// Reading back in history, it can also keep the message at the top where it
/// is when rows above it change size or arrive (a resize, older history
/// loading): SwiftUI's scroll position by id doesn't (the scroll lab, design
/// §8). It watches where that row sits in the content, which changes only
/// when the layout does, and scrolls by its move. Next to the lazy history a
/// correction can make the history re-estimate the rows near the view, which
/// moves the row again (in the stress demo that loop held the main thread for
/// 12 s): more than `correctionsPerSecond` and it stops until the reader
/// scrolls again. The exactly laid-out window (design step 3) removes the
/// cause.
@MainActor
@Observable
final class ChatScrollCoordinator {
    /// The content's coordinate space: rows report their place in it.
    static let contentSpace = "chatContent"
    /// Hold the row being read in place (see above). DEBUG `-holdTopRow NO`
    /// turns it off to compare.
    static let holdsTopRow: Bool = {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "holdTopRow") != nil { return UserDefaults.standard.bool(forKey: "holdTopRow") }
        #endif
        return true
    }()
    /// More corrections than this in a second is a loop, not a reader's place
    /// being kept: stop until the reader scrolls again.
    static let correctionsPerSecond = 8

    // What the views read; each changes only when it really changes.
    /// Following the live end (or on the way back to it).
    private(set) var following = true
    /// 「回到最新」 (besides while an older stretch is loaded).
    private(set) var showsJump = false
    /// Something arrived below since the reader scrolled up: the button's dot.
    private(set) var unseenBelow = false
    /// The reader's finger, or its fling, is moving the list.
    private(set) var userScrolling = false
    /// Growth keeps the end in view (the system's bottom anchor, which holds
    /// only while the view is on the end). Not while the reader's finger or
    /// fling moves the list: the lazy history re-estimating its rows as they
    /// come near changes the content height every other frame, and the
    /// anchor would turn each change into a move back to the end, eating the
    /// fling (the reported height shrank as fast as the offset).
    private(set) var sticksToEnd = true

    @ObservationIgnored private var machine = ChatScrollMachine()
    @ObservationIgnored private var position: Binding<ScrollPosition>?
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var metrics: ChatScroll.Metrics?
    /// `scrollTo(y:)` counts from below the top inset; learned from where a
    /// correction actually lands.
    @ObservationIgnored private var yBias: CGFloat?
    /// When the last corrections were made (for `correctionsPerSecond`).
    @ObservationIgnored private var corrections: [TimeInterval] = []
    /// A correction asked for and not yet seen in the geometry, and when.
    @ObservationIgnored private var pendingY: CGFloat?
    @ObservationIgnored private var pendingSince: TimeInterval = 0
    // The row being read (while detached).
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var topID: String?
    /// Where the content's rows begin, below the list's own top padding.
    @ObservationIgnored private var contentTop: CGFloat = 0
    @ObservationIgnored private var rowY: [String: CGFloat] = [:]
    @ObservationIgnored private var landing: Task<Void, Never>?
    /// The list's own move during a touch, if the finger can't be read.
    @ObservationIgnored private var fallbackDrag: CGFloat = 0
    /// Where the finger was when the list started following it (window points).
    @ObservationIgnored private var fingerStart: CGFloat?
    /// The UIKit scroll view under the SwiftUI one: only to read its pan
    /// gesture, the reader's finger (see `ChatScrollMachine.Event.finger`).
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var widthSettle: Task<Void, Never>?
    @ObservationIgnored private var insetSettle: Task<Void, Never>?

    /// The UIKit scroll view, found from inside the content (`ScrollViewHook`).
    func attach(scrollView: UIScrollView) { self.scrollView = scrollView }

    func attach(position: Binding<ScrollPosition>, store: AppStore, contentTop: CGFloat) {
        self.position = position
        self.store = store
        self.contentTop = contentTop
    }

    // MARK: what the views want

    /// 「回到最新」.
    func jumpToLatest() {
        breadcrumb("jump to latest")
        let d = metrics?.distanceFromBottom ?? 0
        let screens = d / max(1, metrics?.viewport ?? 1)
        debugLog("[jump] tap: \(Int(d)) pt from the end, \(machine.mode.rawValue), button \(showsJump)")
        let signpost = ChatSignposts.chat.beginInterval("jump")
        send(.jump(viewingPast: store?.viewingPast ?? false, screens: screens))
        // Where it landed, and whether it stayed (persisted; the scroll UI tests read these).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            debugLog("[jump] +1.2 s: \(Int(ChatScroll.lastDistance)) pt from the end, pinned \(machine.mode == .following)")
            ChatSignposts.chat.endInterval("jump", signpost)
            try? await Task.sleep(for: .seconds(1.8))
            debugLog("[jump] +3 s: \(Int(ChatScroll.lastDistance)) pt from the end, pinned \(machine.mode == .following)")
            try? await Task.sleep(for: .seconds(2))
            debugLog("[jump] +5 s: \(Int(ChatScroll.lastDistance)) pt from the end, pinned \(machine.mode == .following)")
        }
    }

    /// Bring a message into view (search hit, notification, quote). `after`:
    /// let a slide back to the conversation land first.
    func reveal(_ id: String, after delay: Double = 0) {
        guard delay > 0 else { return send(.reveal(id: id)) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            send(.reveal(id: id))
        }
    }

    func sent() { send(.sent) }
    func grewBelow() { send(.grewBelow) }
    func layoutChanged() { send(.layoutChanged) }
    func background() {
        send(.background)
        LaunchMetrics.logFootprint("going to the background, \(rowY.count) rows laid out so far")
    }

    /// Back in the foreground, caught up: says where the view is once any
    /// move back onto the end has landed.
    func foreground() {
        send(.foreground)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            ChatScroll.log("foreground: \(machine.mode.rawValue)")
        }
    }

    #if DEBUG
    /// `-demoDetach YES`: read from this message.
    func detach(at id: String) { send(.reveal(id: id)) }

    /// `-demoScrollTour YES`: every message at the top in turn, then the end.
    func tour(_ ids: [String]) async {
        for id in ids.reversed() {
            position?.wrappedValue.scrollTo(id: id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(40))
        }
        send(.sent)
    }
    #endif

    // MARK: what the scroll view reports

    func phase(_ p: ScrollPhase) {
        let mapped: ChatScrollMachine.Phase = switch p {
        case .tracking: .tracking
        case .interacting: .interacting
        case .decelerating: .decelerating
        case .animating: .animating
        default: .idle
        }
        let was = machine.phase
        breadcrumb("scroll \(p)")
        // The reader takes over: let go of the last command. A scroll
        // position still saying "the end" is applied again whenever the
        // content changes size, and the lazy history changes it all through
        // a fling: the fling was pulled back to the end and eaten.
        if mapped.isUser, !was.isUser {
            release()
            fingerStart = nil
            fallbackDrag = 0
        }
        // The finger left the screen: how fast it was moving.
        if was == .interacting || was == .tracking, mapped != .interacting, mapped != .tracking, let sv = scrollView {
            send(.lifted(velocity: sv.panGestureRecognizer.velocity(in: sv).y))
        }
        send(.phase(mapped))
        #if DEBUG
        ChatScroll.pinTrace("phase \(p), \(machine.mode.rawValue), dragged \(Int(machine.dragged))")
        #endif
        // The scroll (or an animation of ours) stopped: the row at the top
        // now. Reading back again after holding was stopped: hold again.
        if was != .idle && mapped == .idle {
            if was.isUser, machine.mode == .detached, Self.holdsTopRow { holding = true }
            if holding { topID = topRowNow()?.id }
        }
    }

    func geometry(_ old: ChatScroll.Metrics, _ new: ChatScroll.Metrics) {
        metrics = new
        ChatScroll.lastDistance = new.distanceFromBottom
        if new.contentHeight > new.viewport, let store {
            let n = store.messages.count
            LaunchMetrics.conversationLaidOut(messages: n, laidOut: n - ChatView.split(n))
        }
        if let want = pendingY, abs(new.offsetY - old.offsetY) > 0.5 {
            // Learn how `scrollTo(y:)` maps to the offset (a sane answer only).
            if abs(want - new.offsetY - new.insetTop) < 200 { yBias = want - new.offsetY }
            pendingY = nil
        }
        send(.scrolled(distance: new.distanceFromBottom))
        // The reader's finger: how far it has moved on the screen. Without
        // the UIKit view (it should always be there), the list's own move.
        if machine.phase == .tracking || machine.phase == .interacting {
            if let sv = scrollView {
                // Where the finger is on the screen, from where it started:
                // the pan's own translation gets adjusted when the list is
                // moved under it.
                let pan = sv.panGestureRecognizer
                if pan.state == .began || pan.state == .changed {
                    let y = pan.location(in: nil).y
                    if fingerStart == nil { fingerStart = y - pan.translation(in: sv).y }
                    send(.finger(y - (fingerStart ?? y)))
                }
            } else {
                fallbackDrag -= new.offsetY - old.offsetY
                send(.finger(fallbackDrag))
            }
        } else {
            fallbackDrag = 0
            fingerStart = nil
        }
        #if DEBUG
        if ChatScroll.pinTraceOn, machine.phase.isUser, UserDefaults.standard.bool(forKey: "pinTraceFrames") {
            ChatScroll.pinTrace("frame dy \(String(format: "%.1f", new.offsetY - old.offsetY)) dh \(String(format: "%.1f", new.contentHeight - old.contentHeight)) finger \(Int(machine.dragged))")
        }
        #endif
        // The keyboard rising (not the composer's first layout): once it has
        // risen. Its animation, or the hold-to-talk capsule, change the inset
        // every frame, and a scroll to the end per frame piled up animations
        // until the main thread stalled for seconds.
        if old.bottomInset > 0.5, new.bottomInset > old.bottomInset + 1 {
            insetSettle?.cancel()
            insetSettle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                send(.bottomInsetGrew)
            }
        }
        if abs(new.width - old.width) > 0.5 {
            // A resize comes as many small steps: settle once it rests.
            widthSettle?.cancel()
            widthSettle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                send(.layoutChanged)
            }
        }
    }

    /// The laid-out row under the top of the view (only those report their
    /// place), and its place in the conversation.
    private func topRowNow() -> (id: String, index: Int)? {
        guard let m = metrics, let store else { return nil }
        let line = m.offsetY + m.insetTop - contentTop + 1
        var best: (id: String, y: CGFloat)?
        for (id, y) in rowY where y <= line && y > (best?.y ?? -.infinity) { best = (id, y) }
        guard let best, let index = store.messages.firstIndex(where: { $0.id == best.id }) else { return nil }
        return (best.id, index)
    }

    /// A row's place in the content changed (only layout does that, not scrolling).
    func rowMoved(_ id: String, to y: CGFloat) {
        let old = rowY.updateValue(y, forKey: id)
        guard holding, id == topID, machine.phase == .idle, let old, let m = metrics, let position else { return }
        // One correction at a time. One that never moves the list means the
        // row moves with it (nothing to hold): stop rather than chase it.
        if pendingY != nil {
            if ProcessInfo.processInfo.systemUptime - pendingSince > 0.2 {
                pendingY = nil
                holding = false
                ChatScroll.log("stopped holding the top row: scrolling didn't move it back")
            }
            return
        }
        let d = y - old
        // Content shorter than the view has nowhere to scroll (and its top
        // inset holds the alignment's padding, not the bars).
        guard abs(d) > 0.5, m.contentHeight > m.viewport else { return }
        let now = ProcessInfo.processInfo.systemUptime
        corrections = corrections.filter { now - $0 < 1 } + [now]
        if corrections.count > Self.correctionsPerSecond {
            holding = false
            corrections = []
            ChatScroll.log("stopped holding the top row: corrections kept coming")
            return
        }
        let target = m.offsetY + (yBias ?? m.insetTop) + d
        pendingY = target
        pendingSince = now
        position.wrappedValue.scrollTo(y: target)
        #if DEBUG
        if ChatScroll.pinTraceOn {
            ChatScroll.pinTrace("holding \(id): moved \(String(format: "%.1f", d)) pt (y \(Int(y)), offset \(Int(m.offsetY)), height \(Int(m.contentHeight)), bias \(Int(yBias ?? -1))), scrolled with it")
        }
        #endif
    }

    // MARK: running the machine

    private func send(_ event: ChatScrollMachine.Event) {
        for effect in machine.reduce(event) { run(effect) }
        mirror()
    }

    private func run(_ effect: ChatScrollMachine.Effect) {
        switch effect {
        case .log(let what):
            ChatScroll.log(what)
        case .toEnd(let animated):
            toEnd(animated: animated)
        case .loadLatestThenEnd:
            Task { @MainActor in
                await store?.returnToLatest()
                position?.wrappedValue.scrollTo(edge: .bottom)
            }
        case .center(let id):
            withAnimation(.snappy) { position?.wrappedValue.scrollTo(id: id, anchor: .center) }
        case .holdTopRow(let on):
            holding = on && Self.holdsTopRow
            // The row is taken once the list rests (the reader's scroll, or
            // ours to a revealed message, still moving it now): see `phase`.
            topID = nil
            guard on else { return }
            // An animated scroll of ours doesn't always report its phase:
            // wait until the offset has stopped changing.
            Task { @MainActor in
                var last = metrics?.offsetY
                var still = 0
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard holding, topID == nil else { return }
                    let now = metrics?.offsetY
                    still = now == last && machine.phase == .idle ? still + 1 : 0
                    last = now
                    if still >= 2 {
                        topID = topRowNow()?.id
                        return
                    }
                }
            }
        case .checkLanding:
            landing?.cancel()
            landing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                for _ in 0..<20 {
                    guard !Task.isCancelled, machine.mode == .returning else { return }
                    if machine.phase == .idle {
                        send(.landed(distance: metrics?.distanceFromBottom ?? 0))
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    /// `ScrollPosition.scrollTo(edge: .bottom)`. Asking for the position it
    /// already holds changes nothing, and the scroll view doesn't move: a
    /// second "to the end" after the view slipped away was lost. So it first
    /// lets go of the old one and asks for the end a frame later.
    private func toEnd(animated: Bool) {
        guard let position else { return }
        let go = {
            if animated {
                withAnimation(.snappy) { position.wrappedValue.scrollTo(edge: .bottom) }
            } else {
                position.wrappedValue.scrollTo(edge: .bottom)
            }
        }
        guard position.wrappedValue.edge == .bottom else { return go() }
        release()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(17))
            go()
        }
    }

    /// The scroll position without a target: nothing for the scroll view to
    /// hold on to or apply again.
    private func release() {
        guard let position, position.wrappedValue.edge != nil || position.wrappedValue.point != nil
            || position.wrappedValue.viewID != nil else { return }
        position.wrappedValue = ScrollPosition(idType: String.self)
    }

    /// Copies what the views read, only when it changed.
    private func mirror() {
        let f = machine.mode != .detached
        if following != f { following = f }
        if showsJump != machine.showsJump { showsJump = machine.showsJump }
        if unseenBelow != machine.unseenBelow { unseenBelow = machine.unseenBelow }
        if userScrolling != machine.phase.isUser { userScrolling = machine.phase.isUser }
        let sticks = machine.mode != .detached && !machine.phase.isUser
        if sticksToEnd != sticks { sticksToEnd = sticks }
    }
}

/// Finds the UIKit scroll view a SwiftUI ScrollView is backed by, from a view
/// inside its content, and hands it over once (to read its pan gesture).
struct ScrollViewHook: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> HookView { HookView(found: found) }
    func updateUIView(_ uiView: HookView, context: Context) {}

    final class HookView: UIView {
        let found: (UIScrollView) -> Void
        init(found: @escaping (UIScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var v = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            if let s = v as? UIScrollView { found(s) }
        }
    }
}
