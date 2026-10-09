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
/// It also owns what is laid out (design §3.4): a window of messages, every
/// one measured exactly, no lazy estimates. The newest `windowSize` while
/// following; reading up toward its top, it grows a few rows at a time,
/// older pages loading as needed; a search hit far back gets a window of its
/// own. The views lay out what `window(in:)` says.
///
/// Reading back in history, it keeps the message at the top where it is when
/// rows above it change size or arrive (a resize, the window growing above):
/// SwiftUI's scroll position by id doesn't (the scroll lab, design §8). It
/// watches where that row sits in the content, which changes only when the
/// layout does, and scrolls by its move. With every row laid out exactly, a
/// correction changes no row's place, so it can't feed itself (next to the
/// old lazy history it did, and held the main thread 12 s);
/// `correctionsPerSecond` stays as a backstop, and the scroll UI tests fail
/// if it ever trips.
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
    /// being kept: stop until the reader scrolls again. (The window growing
    /// above corrects once per step, at most ~20 a second.)
    static let correctionsPerSecond = 40
    /// A correction already on its way isn't asked for again (DEBUG
    /// `-holdDedupe NO` to compare).
    static let dedupesCorrections: Bool = {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "holdDedupe") != nil { return UserDefaults.standard.bool(forKey: "holdDedupe") }
        #endif
        return true
    }()

    /// Messages laid out while following the end (DEBUG `-windowSize`).
    /// Each costs memory while laid out (the long demo's answers about 3 MB
    /// each: 30 → 136 MB, 40 → 172, 60 → 228); 40 keeps the footprint where
    /// the lazy history had it (168 MB) and is still many screens.
    static let windowSize = debugInt("windowSize") ?? 40
    /// Laid out at first, so the conversation appears quickly; the rest of
    /// `windowSize` follows a few rows at a time (DEBUG `-windowInitial`).
    static let windowInitial = debugInt("windowInitial") ?? 20
    /// Rows added per step while the window grows (DEBUG `-windowBatch`).
    static let windowBatch = debugInt("windowBatch") ?? 6
    /// Between steps, so each is its own short main-thread turn.
    static let windowStep: Duration = .milliseconds(50)
    /// More rows each time 「看看更早的」 is tapped.
    static let windowChunk = 40
    /// Reading up, at most this many laid out; beyond, the far (newest) end
    /// is let go of while it's well off screen.
    static let windowMax = 100

    private static func debugInt(_ key: String) -> Int? {
        #if DEBUG
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : nil
        #else
        return nil
        #endif
    }

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
    /// only while the view is on the end, and not under a dragging finger).
    /// Off while reading back.
    private(set) var sticksToEnd = true
    /// The oldest message laid out; nil: the newest `windowInitial`.
    private(set) var windowLo: String?
    /// The newest one, when the window stops short of the live end (a search
    /// hit far back); nil: everything to the end.
    private(set) var windowHi: String?
    /// The message (its client id) the latest send from here began with:
    /// its turn gets the room below it, so it sits at the top of the view
    /// with the reply growing underneath (design §3.5). Kept until the next.
    private(set) var turnStart: String?
    /// Its room: what the reader could see when it was sent, between the
    /// bars and the composer (less the list's own padding).
    private(set) var turnRoom: CGFloat = 0

    @ObservationIgnored private var machine = ChatScrollMachine()
    @ObservationIgnored private var position: Binding<ScrollPosition>?
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var metrics: ChatScroll.Metrics?
    /// `scrollTo(y:)` counts from below the top inset; learned from where a
    /// correction actually lands.
    @ObservationIgnored private var yBias: CGFloat?
    /// The corrections of the last second (for `correctionsPerSecond`):
    /// when, by how much, and what asked (the held row's place changing, or
    /// the scroll geometry).
    @ObservationIgnored private var corrections: [(at: TimeInterval, by: CGFloat, fromRow: Bool)] = []
    /// A correction asked for and not yet seen in the geometry, and when.
    @ObservationIgnored private var pendingY: CGFloat?
    @ObservationIgnored private var pendingSince: TimeInterval = 0
    // The row being read (while detached).
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var topID: String?
    /// Where the held row sat below the top of the view when it was taken.
    @ObservationIgnored private var heldAt: CGFloat?
    /// Where the content's rows begin, below the list's own top padding.
    @ObservationIgnored private var contentTop: CGFloat = 0
    @ObservationIgnored private var rowY: [String: CGFloat] = [:]
    @ObservationIgnored private var landing: Task<Void, Never>?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var toEndPending = false
    /// Rows wanted above the window beyond `windowSize` (「看看更早的」).
    @ObservationIgnored private var extraAbove = 0
    /// The list's own move during a touch, if the finger can't be read.
    @ObservationIgnored private var fallbackDrag: CGFloat = 0
    /// Where the finger was when the list started following it (window points).
    @ObservationIgnored private var fingerStart: CGFloat?
    /// The UIKit scroll view under the SwiftUI one: only to read its pan
    /// gesture, the reader's finger (see `ChatScrollMachine.Event.finger`).
    @ObservationIgnored private weak var scrollView: UIScrollView?
    /// How fast the finger left the screen, from the pan gesture as it
    /// ended, and when. Read at SwiftUI's phase change instead, the gesture
    /// has often been reset already: a flick read as no speed at all, and a
    /// short one was taken for a short drag and pulled back to the end (her
    /// phone, step 3 build: "scroll ended near the end" 200–750 pt from it).
    @ObservationIgnored private var lift: (velocity: CGFloat, at: CFTimeInterval)?
    /// When this pan began and where the finger came down (window points).
    @ObservationIgnored private var panStart: (at: CFTimeInterval, y: CGFloat)?
    @ObservationIgnored private var panWatcher: PanWatcher?
    @ObservationIgnored private var widthSettle: Task<Void, Never>?
    @ObservationIgnored private var insetSettle: Task<Void, Never>?

    /// The UIKit scroll view, found from inside the content (`ScrollViewHook`).
    func attach(scrollView: UIScrollView) {
        if scrollView !== self.scrollView {
            if let old = self.scrollView, let w = panWatcher { old.panGestureRecognizer.removeTarget(w, action: nil) }
            let watcher = PanWatcher { [weak self] pan in
                guard let self else { return }
                let now = CACurrentMediaTime()
                switch pan.state {
                case .began:
                    lift = nil
                    panStart = (now, pan.location(in: nil).y - pan.translation(in: pan.view).y)
                case .ended, .cancelled:
                    // The speed at the end, or over the whole gesture if
                    // that's faster: with the main thread busy (a reply
                    // streaming in), the last touches come bunched and the
                    // end speed of a quick flick read 125 pt/s instead of
                    // 430, and it was taken back to the end as a short drag.
                    // A drag that stops before lifting averages low.
                    let end = pan.velocity(in: pan.view).y
                    var speed = end
                    if let start = panStart {
                        let average = (pan.location(in: nil).y - start.y) / max(now - start.at, 0.016)
                        if abs(average) > abs(end) { speed = average }
                    }
                    lift = (speed, now)
                    panStart = nil
                default: break
                }
            }
            scrollView.panGestureRecognizer.addTarget(watcher, action: #selector(PanWatcher.panned(_:)))
            panWatcher = watcher
        }
        self.scrollView = scrollView
        #if DEBUG
        ChatScroll.uiScrollView = scrollView
        #endif
    }

    func attach(position: Binding<ScrollPosition>, store: AppStore, contentTop: CGFloat) {
        self.position = position
        self.store = store
        store.willChangeTheEnd = { [weak self] in self?.settleOnTheEnd() }
        self.contentTop = contentTop
        pumpWindow()
    }

    // MARK: what the views want

    /// 「回到最新」.
    func jumpToLatest() {
        breadcrumb("jump to latest")
        let d = metrics?.distanceFromBottom ?? 0
        let screens = d / max(1, metrics?.viewport ?? 1)
        debugLog("[jump] tap: \(Int(d)) pt from the end, \(machine.mode.rawValue), button \(showsJump)")
        let signpost = ChatSignposts.chat.beginInterval("jump")
        if layOutTheEnd() {
            // A far stretch was laid out: the end first, then the jump.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                let d = metrics?.distanceFromBottom ?? 0
                send(.jump(viewingPast: store?.viewingPast ?? false, screens: d / max(1, metrics?.viewport ?? 1)))
            }
        } else {
            send(.jump(viewingPast: store?.viewingPast ?? false, screens: screens))
        }
        // Where it landed, and whether it stayed (persisted; the scroll UI
        // tests read these). Mid-glide (a reply streaming in) the view is a
        // line or two (or a message gliding in) short of the end, on its way
        // there: then also the closest it came in the last half second.
        func where_() -> String {
            let glide = machine.gliding ? " (gliding, closest \(Int(closestRecently())) in 0.5 s)" : ""
            return "\(Int(ChatScroll.lastDistance)) pt from the end\(glide), pinned \(machine.mode == .following)"
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            debugLog("[jump] +1.2 s: \(where_())")
            ChatSignposts.chat.endInterval("jump", signpost)
            try? await Task.sleep(for: .seconds(1.8))
            debugLog("[jump] +3 s: \(where_())")
            try? await Task.sleep(for: .seconds(2))
            debugLog("[jump] +5 s: \(where_())")
        }
    }

    /// Bring a message into view (search hit, notification, quote). `after`:
    /// let a slide back to the conversation land first.
    func reveal(_ id: String, after delay: Double = 0) {
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            // Not laid out yet: lay it out, and go there once it has its place.
            #if DEBUG
            if ChatScroll.pinTraceOn, let store {
                let w = window(in: store.messages)
                let i = store.messages.firstIndex { $0.id == id } ?? -1
                ChatScroll.pinTrace("reveal \(id) at \(i), window \(w.lowerBound)..<\(w.upperBound) of \(store.messages.count)")
            }
            #endif
            if layOut(id) { await awaitRow(id) }
            send(.reveal(id: id))
        }
    }

    /// About to send: the message and its room arrive in an animation (see
    /// `ChatMotion.send`), and the view glides up with them. `instant`: a
    /// spoken message, placed under the voice scrim where it stays, nothing
    /// animated (its words then fly into it, design §3.7); from reading back,
    /// the way to the end is a jump too.
    func willSend(instant: Bool = false) {
        measureRoom()
        let now = ProcessInfo.processInfo.systemUptime
        if instant {
            instantUntil = now + 0.6
            return
        }
        risingUntil = now + 0.8
        glide(for: 0.8)
    }

    /// Until when going to the end is a jump (a spoken send, `willSend`).
    @ObservationIgnored private var instantUntil: TimeInterval = 0

    /// The room a turn gets: the height the reader can see now.
    private func measureRoom() {
        guard let m = metrics else { return }
        let room = max(0, m.viewport - m.insetTop - m.bottomInset - 24)
        if abs(room - turnRoom) > 0.5 { turnRoom = room }
    }

    /// Something was sent from here (its echo is the last message).
    func sent(turnStart cid: String?) {
        if let cid, cid != turnStart { turnStart = cid }
        if turnRoom == 0 { measureRoom() }
        #if DEBUG
        turnProbe = nil
        FrameWatch.shared.following = { [weak self] in self?.machine.mode == .following }
        FrameWatch.shared.start("a send and its reply", rising: true)
        #endif
        send(.sent)
        #if DEBUG
        probeTurn()
        #endif
    }
    func grewBelow() { send(.grewBelow) }

    @ObservationIgnored private var followed: (reply: StreamingReply, token: Int)?
    /// The reply being written: each piece of it counts as growth below.
    func follow(_ reply: StreamingReply?) {
        #if DEBUG
        if reply == nil, followed != nil {
            FrameWatch.shared.replyEnded()
            // Written: the last of it settles, then the line.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if self.followed == nil { FrameWatch.shared.stop() }
            }
        }
        if reply != nil, followed == nil, !FrameWatch.shared.running {
            FrameWatch.shared.following = { [weak self] in self?.machine.mode == .following }
            FrameWatch.shared.start("a reply", rising: false)
        }
        #endif
        if let f = followed { f.reply.stopListening(f.token) }
        followed = reply.map { r in
            (r, r.listen { [weak self] _ in
                // Each tick's growth glides in (`ChatMotion.follow`).
                self?.glide(for: 0.3)
                self?.grewBelow()
            })
        }
    }

    /// Since when the view, following a glide, has been more than 30 pt off
    /// the end (nil: it isn't).
    @ObservationIgnored private var farSince: TimeInterval?
    /// Where it was at all, the same span (for `[jump]`).
    @ObservationIgnored private var recentDistances: [(at: TimeInterval, distance: CGFloat)] = []

    /// The closest the view came to the end in the last half second.
    private func closestRecently() -> CGFloat {
        let t = ProcessInfo.processInfo.systemUptime
        return recentDistances.filter { t - $0.at <= 0.5 }.map(\.distance).min() ?? ChatScroll.lastDistance
    }

    /// Until when the view is on a send's rise (`willSend`).
    @ObservationIgnored private var risingUntil: TimeInterval = 0

    /// Following a reply as it's written, the view glides onto the end and,
    /// between ticks, comes within a line of it. If in 0.4 s it never came
    /// within 30 pt, it isn't gliding but stranded: off the end (a
    /// scroll of ours that landed a little short while the reply grew), where
    /// the bottom anchor doesn't hold, so each tick left it further behind
    /// (24 pt, then 194 within a second). Onto the end, at once: from there
    /// the anchor carries it again. (A glide never ending while the reply
    /// goes on, the check at its end would come only with the reply's end.)
    /// Stranded, the view only moves when a tick lands, so it hears of it
    /// every 130–200 ms, not every frame: it counts from the first time it
    /// was that far off, not over a window a sample may not fall in.
    /// Not during a send's rise: from a screen away it takes longer than
    /// that to come within 30 pt, and its landing is checked by `.settleSend`.
    private func checkGlideKeepsUp(_ distance: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        recentDistances = recentDistances.filter { now - $0.at < 0.6 } + [(now, distance)]
        guard machine.gliding, machine.mode == .following, !machine.phase.isUser, now >= risingUntil,
              distance > 30 else {
            farSince = nil
            return
        }
        guard let since = farSince else { farSince = now; return }
        guard now - since >= 0.4 else { return }
        farSince = nil
        ChatScroll.log("following: fell behind the end")
        toEnd(animated: false)
    }

    /// A change is about to land at the end (see `AppStore.willChangeTheEnd`):
    /// mid-glide, onto the end at once, through UIKit so it's there before
    /// the change is laid out (the rest of the glide, a line or two, is cut
    /// short). Then the bottom anchor holds the view through the change.
    func settleOnTheEnd() {
        guard machine.gliding, machine.mode == .following, !machine.phase.isUser, let sv = scrollView else { return }
        let end = sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height
        guard end > sv.contentOffset.y + 0.5 else { return }
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: end), animated: false)
    }

    @ObservationIgnored private var glideEnd: Task<Void, Never>?
    /// Growth on the end is gliding in for about `seconds`: on the way, the
    /// view being off the end is the anchor's doing (`.gliding`).
    private func glide(for seconds: Double) {
        if !machine.gliding { send(.gliding(true)) }
        glideEnd?.cancel()
        glideEnd = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            send(.gliding(false))
            pumpWindow()
        }
    }
    func layoutChanged() { send(.layoutChanged) }

    /// While the app is away: the rows that were off screen when it left,
    /// and the appearance they keep until it's back. The system lays the
    /// window out again for each of its app-switcher snapshots, in the dark
    /// appearance and the light, and each row laid out (40 long answers)
    /// resolved and measured all its text again for every switch; only
    /// what's on screen can show in a snapshot.
    private(set) var heldAppearance: (scheme: ColorScheme, rows: Set<String>)?

    func background() {
        send(.background)
        if let style = scrollView?.traitCollection.userInterfaceStyle, style != .unspecified {
            let rows = rowsOffScreen()
            if !rows.isEmpty { heldAppearance = (style == .dark ? .dark : .light, rows) }
        }
        LaunchMetrics.logFootprint("going to the background, \(rowY.count) rows laid out so far, \(heldAppearance?.rows.count ?? 0) off screen")
    }

    /// No longer in the background: every row follows the window again.
    func leftBackground() {
        if heldAppearance != nil { heldAppearance = nil }
    }

    /// The laid-out rows wholly outside what the scroll view shows (bars,
    /// composer and keyboard included: content shows through them), with
    /// some room to spare. A row whose place isn't known counts as on screen.
    private func rowsOffScreen() -> Set<String> {
        guard let store, let m = metrics else { return [] }
        let messages = store.messages
        let ids = window(in: messages).map { messages[$0].id }
        // In the rows' own space, which begins `contentTop` into the content.
        let margin: CGFloat = 100
        let top = m.offsetY - contentTop - margin
        let bottom = m.offsetY + m.viewport - contentTop + margin
        var off = Set<String>()
        for (k, id) in ids.enumerated() {
            guard let y = rowY[id] else { continue }
            // It ends where the next row begins (the last, at the content's end).
            let next = k + 1 < ids.count ? rowY[ids[k + 1]] : m.contentHeight - contentTop
            guard let end = next else { continue }
            if end < top || y > bottom { off.insert(id) }
        }
        return off
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
    func detach(at id: String) { reveal(id) }

    /// `-demoScrollTour YES`: every message at the top in turn, then the end.
    func tour(_ ids: [String]) async {
        let laidOut = store.map { s in Set(s.messages[window(in: s.messages)].map(\.id)) } ?? []
        for id in ids.reversed() where laidOut.contains(id) {
            position?.wrappedValue.scrollTo(id: id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(40))
        }
        send(.sent)
    }
    #endif

    // MARK: the laid-out window

    /// The messages to lay out, as indices into `messages`.
    func window(in messages: [ChatMessage]) -> Range<Int> {
        let n = messages.count
        var hi = n
        if let id = windowHi, let i = messages.firstIndex(where: { $0.id == id }) { hi = i + 1 }
        var lo = max(0, hi - Self.windowInitial)
        if let id = windowLo, let i = messages.firstIndex(where: { $0.id == id }) { lo = i }
        return min(lo, hi)..<hi
    }

    /// 「看看更早的」: a chunk more above (older pages load as needed).
    func revealOlder() {
        extraAbove += Self.windowChunk
        if let store, window(in: store.messages).lowerBound == 0 { Task { await loadOlder() } }
        pumpWindow()
    }

    /// Messages arrived, went, or were replaced.
    func messagesChanged() { pumpWindow() }

    /// Rows that left the window: their places are stale.
    func forget(_ id: String) {
        rowY[id] = nil
        if id == topID { topID = nil }
    }

    private func loadOlder() async {
        guard let store, store.hasOlderMessages, !store.isLoadingOlder else { return }
        await store.loadOlder()
        pumpWindow()
    }

    /// Steps the window toward what the moment wants, one short step per
    /// turn, until there is nothing left to do.
    private func pumpWindow() {
        guard windowTask == nil else { return }
        windowTask = Task { @MainActor in
            defer { windowTask = nil }
            while !Task.isCancelled, stepWindow() {
                if let store {
                    let w = window(in: store.messages)
                    breadcrumb("window \(w.lowerBound)..<\(w.upperBound) of \(store.messages.count)")
                }
                #if DEBUG
                if ChatScroll.pinTraceOn, let store {
                    let w = window(in: store.messages)
                    ChatScroll.pinTrace("window \(w.lowerBound)..<\(w.upperBound) of \(store.messages.count), \(machine.mode.rawValue)")
                }
                #endif
                try? await Task.sleep(for: Self.windowStep)
            }
        }
    }

    /// One step; false when there is nothing to do now (a later event pumps again).
    private func stepWindow() -> Bool {
        guard let store, !machine.phase.isUser else { return false }
        let messages = store.messages
        let n = messages.count
        let w = window(in: messages)
        guard n > 0 else { return false }
        func setLo(_ i: Int) { windowLo = messages[max(0, min(i, n - 1))].id }
        func setHi(_ i: Int) { windowHi = i >= n ? nil : messages[max(0, i - 1)].id }
        if machine.mode != .detached {
            extraAbove = 0
            if windowHi != nil {
                // Back to the live end (a jump or a send from a far stretch).
                windowHi = nil
                setLo(n - Self.windowSize)
                return true
            }
            // Fill up to the window above the end (invisible: the bottom
            // anchor keeps the end in place), or let go of what's beyond it.
            // Not while growth glides in or a scroll of ours runs: rows
            // arriving above then threw the view a screen or more off the
            // end (the anchor mid-animation doesn't make up for them). The
            // glide's end pumps again.
            if machine.gliding || machine.phase == .animating { return false }
            if w.count < Self.windowSize, w.lowerBound > 0 {
                setLo(max(n - Self.windowSize, w.lowerBound - Self.windowBatch))
                return true
            }
            if w.count > Self.windowSize + 10 {
                setLo(n - Self.windowSize)
                return true
            }
            return false
        }
        // Reading back: only with the row at the top held (else rows added
        // above would push the text being read down).
        guard holding, topID != nil, let m = metrics else { return false }
        let visibleTop = m.offsetY + m.insetTop
        let nearTop = visibleTop < 1.5 * m.viewport
        let nearBottom = m.distanceFromBottom < 1.5 * m.viewport
        if nearTop || w.count < Self.windowSize + extraAbove {
            if w.lowerBound > 0 {
                setLo(w.lowerBound - Self.windowBatch)
                return true
            }
            if nearTop, store.hasOlderMessages, !store.isLoadingOlder { Task { await loadOlder() } }
        }
        if nearBottom, w.upperBound < n {
            setHi(w.upperBound + Self.windowBatch)
            return true
        }
        // Very long: let go of the far end while it's well off screen.
        if w.count > Self.windowMax, m.distanceFromBottom > 3 * m.viewport {
            setHi(w.lowerBound + Self.windowMax)
            return true
        }
        return false
    }

    /// Makes sure `id` is laid out; true if the window had to change (then
    /// scroll to it once it has its place: `awaitRow`).
    private func layOut(_ id: String) -> Bool {
        guard let store, let i = store.messages.firstIndex(where: { $0.id == id }) else { return false }
        let messages = store.messages
        let n = messages.count
        let w = window(in: messages)
        guard !w.contains(i) else { return false }
        if i < w.lowerBound, w.lowerBound - i <= Self.windowBatch * 2 {
            windowLo = messages[max(0, i - 3)].id
        } else if i >= w.upperBound, i - w.upperBound < Self.windowBatch * 2 {
            let hi = min(n, i + 4)
            windowHi = hi >= n ? nil : messages[hi - 1].id
        } else {
            // Farther: a small window of its own around it (it grows as the
            // reader moves; 回到最新 lays the end out again).
            windowLo = messages[max(0, i - 3)].id
            let hi = min(n, max(0, i - 3) + Self.windowInitial)
            windowHi = hi >= n ? nil : messages[hi - 1].id
        }
        return true
    }

    /// Waits (up to a second) until `id` has reported its place after a
    /// window change, so a scroll to it lands.
    private func awaitRow(_ id: String) async {
        rowY[id] = nil
        for _ in 0..<60 {
            if rowY[id] != nil { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(16))
    }

    /// The window back at the live end, if it isn't; true if it changed.
    private func layOutTheEnd() -> Bool {
        guard windowHi != nil, let store else { return false }
        let n = store.messages.count
        windowHi = nil
        // A few screens' worth; the rest fills in above, out of sight.
        if n > 0 { windowLo = store.messages[max(0, n - Self.windowInitial)].id }
        return true
    }

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
            // (This touch's: a new pan clears it, and SwiftUI reports the
            // change well within a second even when the app is busy.)
            let ended = lift.flatMap { CACurrentMediaTime() - $0.at < 1 ? $0.velocity : nil }
            #if DEBUG
            ChatScroll.pinTrace("lifted: \(ended.map { "\(Int($0)) pt/s at the gesture's end" } ?? "\(Int(sv.panGestureRecognizer.velocity(in: sv).y)) pt/s now (\(lift.map { "ended \(Int((CACurrentMediaTime() - $0.at) * 1000)) ms ago" } ?? "no end seen"))")")
            #endif
            lift = nil
            send(.lifted(velocity: ended ?? sv.panGestureRecognizer.velocity(in: sv).y))
        }
        send(.phase(mapped))
        #if DEBUG
        ChatScroll.pinTrace("phase \(p), \(machine.mode.rawValue), dragged \(Int(machine.dragged))")
        #endif
        // The scroll (or an animation of ours) stopped: the row at the top
        // now. Reading back again after holding was stopped: hold again.
        if was != .idle && mapped == .idle {
            if was.isUser, machine.mode == .detached, Self.holdsTopRow { holding = true }
            if holding { takeHeldRow() }
            pumpWindow()
        }
    }

    func geometry(_ old: ChatScroll.Metrics, _ new: ChatScroll.Metrics) {
        metrics = new
        ChatScroll.lastDistance = new.distanceFromBottom
        if !LaunchMetrics.conversationLogged, new.contentHeight > new.viewport, let store {
            LaunchMetrics.conversationLaidOut(messages: store.messages.count, laidOut: window(in: store.messages).count)
        }
        #if DEBUG
        defer { probeHeldRow(); probeTurn() }
        #endif
        if let want = pendingY, abs(new.offsetY - old.offsetY) > 0.5 {
            // Learn how `scrollTo(y:)` maps to the offset (a sane answer only).
            if abs(want - new.offsetY - new.insetTop) < 200 { yBias = want - new.offsetY }
            pendingY = nil
        }
        // Following, SwiftUI's bottom anchor moves its offset to keep the end
        // in view, but while a finger rests on the list (UIKit tracking) the
        // move never reaches the UIScrollView: the two drift apart, the end
        // slides down under the finger, and the next touch makes SwiftUI
        // take UIKit's offset back (the view seemed thrown). Hand UIKit the
        // anchor's offset; only under a resting finger, never while it drags
        // or a fling coasts. (Without a finger SwiftUI moves UIKit itself,
        // just after this callback: setting it here too had every new line
        // of a reply scroll the list twice.)
        if machine.mode == .following, let sv = scrollView, sv.isTracking, !sv.isDragging, !sv.isDecelerating,
           new.offsetY > sv.contentOffset.y + 0.5 {
            #if DEBUG
            ChatScroll.pinTrace("UIKit at \(Int(sv.contentOffset.y)), the anchor at \(Int(new.offsetY)): handed over")
            #endif
            sv.contentOffset.y = new.offsetY
        }
        send(.scrolled(distance: new.distanceFromBottom))
        checkGlideKeepsUp(new.distanceFromBottom)
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
        // Anything moving the list while it rests (a rotation, insets
        // changing): the held row back where it belongs.
        if holding, !machine.phase.isUser { holdRow(fromRow: false) }
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
                // A rotation or a resize: the room fits what's seen now.
                if turnStart != nil { measureRoom() }
                send(.layoutChanged)
            }
        }
    }

    /// The laid-out row under the top of the view (only those report their
    /// place), and its place in the conversation.
    private func topRowNow() -> (id: String, index: Int)? {
        guard let m = metrics, let store else { return nil }
        let line = m.offsetY + m.insetTop - contentTop + 1
        // Only rows laid out now (`rowY` remembers rows that have left).
        let messages = store.messages
        let w = window(in: messages)
        var best: (index: Int, y: CGFloat)?
        for i in w {
            guard let y = rowY[messages[i].id], y <= line else { continue }
            if y > (best?.y ?? -.infinity) { best = (i, y) }
        }
        return best.map { (messages[$0.index].id, $0.index) }
    }

    /// A row's place in the content changed (only layout does that, not scrolling).
    func rowMoved(_ id: String, to y: CGFloat) {
        rowY[id] = y
        #if DEBUG
        defer { probeHeldRow(); probeTurn() }
        #endif
        if id == topID { holdRow(fromRow: true) }
    }

    /// Where `id` sits below the top of the view.
    private func onScreen(_ id: String, _ m: ChatScroll.Metrics) -> CGFloat? {
        rowY[id].map { $0 + contentTop - (m.offsetY + m.insetTop) }
    }

    /// Takes the row under the top of the view, and where it is, as the one
    /// to hold.
    private func takeHeldRow() {
        topID = topRowNow()?.id
        heldAt = topID.flatMap { id in metrics.flatMap { onScreen(id, $0) } }
        #if DEBUG
        probeHeldRow()
        #endif
    }

    /// Puts the held row back where it was taken, if anything moved it: rows
    /// above it changing size or arriving, a rotation, the system adjusting
    /// the offset. The target is absolute (where the row is now, minus where
    /// it belongs), so corrections can't add up on top of other changes.
    private func holdRow(fromRow: Bool) {
        guard holding, !machine.phase.isUser, let id = topID, let held = heldAt, let m = metrics,
              let position, let now = onScreen(id, m), m.contentHeight > m.viewport else { return }
        guard abs(now - held) > 0.5 else { return }
        let offset = m.offsetY + (now - held)
        let target = offset + (yBias ?? m.insetTop)
        let t = ProcessInfo.processInfo.systemUptime
        // The same correction is already on its way (a row moving reports
        // both its new place and the new geometry in one frame, before the
        // first scroll lands): once is enough. Twice per change had window
        // growth above the reader alone reach the breaker's rate.
        if Self.dedupesCorrections, let p = pendingY, abs(p - target) < 0.5, t - pendingSince < 0.1 { return }
        corrections = corrections.filter { t - $0.at < 1 } + [(t, now - held, fromRow)]
        if corrections.count > Self.correctionsPerSecond {
            // What it saw, for the next time it happens (numbers only).
            let sizes = corrections.map { abs($0.by) }.sorted()
            let rows = corrections.filter(\.fromRow).count
            holding = false
            corrections = []
            ChatScroll.log("stopped holding the top row: corrections kept coming (a loop): \(sizes.count) in a second, \(rows) as its row moved, \(sizes.count - rows) as the geometry changed, by \(Int(sizes[sizes.count / 2])) pt typically, \(Int(sizes.last ?? 0)) at most, scroll \(machine.phase.rawValue), window growing \(windowTask != nil)")
            return
        }
        pendingY = target
        pendingSince = t
        position.wrappedValue.scrollTo(y: target)
        #if DEBUG
        if ChatScroll.pinTraceOn {
            ChatScroll.pinTrace("holding \(id): \(Int(now)) pt below the top, belongs at \(Int(held)), scrolled by \(Int(now - held))")
        }
        #endif
    }

    #if DEBUG
    /// `-turnTrace YES`: where the latest sent message sits below the top of
    /// the view, each time that changes by a point or more (the push-to-top
    /// UI tests: it rises to the top, then stays while a short reply grows).
    @ObservationIgnored private var turnProbe: Int?
    private static let turnTraceOn = UserDefaults.standard.bool(forKey: "turnTrace")
    private func probeTurn() {
        guard Self.turnTraceOn, let cid = turnStart, let m = metrics,
              let id = store?.messages.last(where: { $0.clientMsgId == cid })?.id, let y = rowY[id] else { return }
        let onScreen = Int((y + contentTop - (m.offsetY + m.insetTop)).rounded())
        if let p = turnProbe, abs(p - onScreen) < 1 { return }
        turnProbe = onScreen
        debugLog("[turn] \(onScreen) pt below the top, \(Int(m.distanceFromBottom)) pt from the end, \(machine.mode.rawValue)")
    }

    @ObservationIgnored private var heldProbe: (id: String, y: Int)?
    /// `-pinTrace YES`: where the held row sits below the top of the view,
    /// each time that changes by more than a point while the list rests
    /// (ChatScrollUITests checks it stays put through rotations).
    private func probeHeldRow() {
        guard ChatScroll.pinTraceOn, holding, machine.phase == .idle, let id = topID, let y = rowY[id], let m = metrics else { return }
        let onScreen = Int((y + contentTop - (m.offsetY + m.insetTop)).rounded())
        if let p = heldProbe, p.id == id, abs(p.y - onScreen) <= 1 { return }
        heldProbe = (id, onScreen)
        debugLog("[hold] \(id) at \(onScreen) pt below the top")
    }
    #endif

    // MARK: running the machine

    private func send(_ event: ChatScrollMachine.Event) {
        let was = machine.mode
        for effect in machine.reduce(event) { run(effect) }
        mirror()
        if machine.mode != was { pumpWindow() }
    }

    private func run(_ effect: ChatScrollMachine.Effect) {
        switch effect {
        case .log(let what):
            ChatScroll.log(what)
        case .toEnd(let animated):
            toEnd(animated: animated)
        case .nearEndThenAnimate:
            // Every row is laid out exactly, so a screen above the end is
            // exactly there; then the rest of the way animated.
            guard let m = metrics, let position, windowHi == nil else { return toEnd(animated: false) }
            let end = m.contentHeight + m.bottomInset - m.viewport
            release()
            position.wrappedValue.scrollTo(y: max(0, end - m.viewport) + (yBias ?? m.insetTop))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(32))
                guard machine.mode == .returning, !machine.phase.isUser else { return }
                withAnimation(.snappy(duration: 0.3)) { position.wrappedValue.scrollTo(edge: .bottom) }
            }
        case .loadLatestThenEnd:
            Task { @MainActor in
                await store?.returnToLatest()
                position?.wrappedValue.scrollTo(edge: .bottom)
            }
        case .center(let id):
            Task { @MainActor in
                // Not laid out: lay it out first (a scroll to a row that
                // isn't there goes nowhere).
                if layOut(id) { await awaitRow(id) }
                release()
                withAnimation(.snappy) { position?.wrappedValue.scrollTo(id: id, anchor: .center) }
            }
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
                    still = now == last && !machine.phase.isUser ? still + 1 : 0
                    last = now
                    if still >= 2 {
                        takeHeldRow()
                        pumpWindow()
                        return
                    }
                }
            }
        case .settleSend:
            // The sent message rises with the bottom anchor; if the view
            // wasn't quite on the end, or a touch got in the way, it may
            // stop short: once the rise is over, onto the end.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1000))
                guard machine.mode == .following, !machine.phase.isUser, !machine.gliding,
                      let d = metrics?.distanceFromBottom, d > ChatScrollMachine.atEnd else { return }
                ChatScroll.log("following: a send's rise stopped short")
                toEnd(animated: true)
            }
        case .checkLanding:
            landing?.cancel()
            landing = Task { @MainActor in
                // The animation takes 0.3 s; with a reply growing, SwiftUI
                // keeps retargeting it to the moving end and may never say
                // it ended: once it's near the end (or the time is up), land.
                try? await Task.sleep(for: .milliseconds(350))
                for i in 0..<20 {
                    guard !Task.isCancelled, machine.mode == .returning else { return }
                    let d = metrics?.distanceFromBottom ?? 0
                    if !machine.phase.isUser, machine.phase == .idle || d <= ChatScrollMachine.reattachDistance || i >= 5 {
                        send(.landed(distance: d))
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
        if layOutTheEnd() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                toEnd(animated: false)
            }
            return
        }
        let animated = animated && ProcessInfo.processInfo.systemUptime >= instantUntil
        let go = {
            if animated {
                withAnimation(.snappy) { position.wrappedValue.scrollTo(edge: .bottom) }
            } else {
                position.wrappedValue.scrollTo(edge: .bottom)
            }
        }
        guard position.wrappedValue.edge == .bottom else { return go() }
        // One at a time (a reply growing sends many).
        guard !toEndPending else { return }
        toEndPending = true
        release()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(17))
            toEndPending = false
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
        let sticks = machine.mode != .detached
        if sticksToEnd != sticks { sticksToEnd = sticks }
    }
}

/// The target of the scroll view's pan gesture (UIKit keeps targets weakly).
@MainActor
private final class PanWatcher: NSObject {
    let changed: (UIPanGestureRecognizer) -> Void
    init(_ changed: @escaping (UIPanGestureRecognizer) -> Void) { self.changed = changed }
    @objc func panned(_ pan: UIPanGestureRecognizer) { changed(pan) }
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
