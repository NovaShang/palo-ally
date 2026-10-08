import CoreGraphics

/// The chat's scroll states and what moves the list between them (design
/// §3.5). Pure, so every row of the transition table is a unit test; the
/// app's `ChatScrollCoordinator` feeds it what the scroll view reports and
/// carries out the effects it returns. Nothing else moves the list.
///
/// Following the live end is the system's own bottom size-change anchor:
/// it keeps the end in view as the content grows, but only while the view
/// sits exactly on the end (the scroll lab, design §8). So the machine never
/// scrolls for growth; it puts the view back on the end whenever following
/// starts again, or the view slipped off it while following.
public struct ChatScrollMachine: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// On the live end, which the bottom anchor keeps in view.
        case following
        /// Reading back in history: nothing moves the text being read.
        case detached
        /// 「回到最新」 on its way down (a moment).
        case returning
    }

    /// `ScrollPhase`, without SwiftUI.
    public enum Phase: String, Sendable {
        case idle, tracking, interacting, decelerating, animating

        /// The reader's finger, or the fling it left behind.
        public var isUser: Bool { self == .tracking || self == .interacting || self == .decelerating }
    }

    public enum Event: Equatable, Sendable {
        case phase(Phase)
        /// The scroll geometry changed: `distance` from the end now.
        case scrolled(distance: CGFloat)
        /// How far the reader's finger has moved since it came down, on the
        /// screen (positive: down, which pulls older messages into view).
        /// The finger, not the list: the list also moves when rows above
        /// re-measure, a catch-up lands, or a reply grows under a finger that
        /// is only resting, and the geometry can't tell those apart (a fling
        /// across the lazy history even reports its height shrinking as fast
        /// as its offset, so it seems to stay on the end).
        case finger(CGFloat)
        /// The finger left the screen moving at this speed (points a second,
        /// positive: down, flinging older messages into view).
        case lifted(velocity: CGFloat)
        /// A message, or more of one, arrived at the end.
        case grewBelow
        /// The keyboard (or a taller composer) took room at the bottom.
        case bottomInsetGrew
        /// The width changed (rotation, a window resize, a sidebar, a layout switch).
        case layoutChanged
        /// The owner sent something (typed, or let go of hold-to-talk).
        case sent
        /// 「回到最新」: `screens` is the distance from the end in viewport heights.
        case jump(viewingPast: Bool, screens: CGFloat)
        /// Bring a message into view: a search hit, an approval or a question
        /// from a notification, a quote.
        case reveal(id: String)
        /// The way down after 「回到最新」 is over (its animation ended, or its
        /// time ran out); `distance` from the end now.
        case landed(distance: CGFloat)
        case background
        /// Back in the foreground, caught up.
        case foreground
        /// Growth on the end is being animated (a reveal tick, a send): the
        /// bottom anchor glides the view along, and on the way the view is
        /// a little off the end. Off: the glide is over.
        case gliding(Bool)
    }

    public enum Effect: Equatable, Sendable {
        /// `ScrollPosition.scrollTo(edge: .bottom)`.
        case toEnd(animated: Bool)
        /// Far away: straight to a screen above the end, then animate the rest.
        case nearEndThenAnimate
        /// An older stretch is showing: load the live end, then go there.
        case loadLatestThenEnd
        /// Scroll the message to the middle of the view.
        case center(id: String)
        /// Keep the message at the top where it is when rows change size or
        /// arrive above it (only while detached).
        case holdTopRow(Bool)
        /// Report where the view is once it has stopped (sends `.landed`).
        case checkLanding
        /// After a send: once its message has risen, onto the end if the view
        /// stopped short of it.
        case settleSend
        /// A `[scroll]` line: a change of state, and why.
        case log(String)
    }

    /// A reader's scroll this far toward older messages lets go of the end.
    public static let detachDrag: CGFloat = 8
    /// A reader's scroll that ends this close to the end follows it again,
    /// and the jump button only shows beyond it.
    public static let reattachDistance: CGFloat = 56
    /// On the end, as far as the bottom anchor is concerned.
    public static let atEnd: CGFloat = 1
    /// A finger leaving this fast toward older messages is a fling up.
    public static let flingSpeed: CGFloat = 300
    /// Back to the end animated only from this close; farther, at once.
    public static let animatedReturn: CGFloat = 1000
    /// As far off the end as a glide can leave the view (a burst revealing a
    /// few paragraphs in one tick); beyond, something else threw it off.
    public static let glideReach: CGFloat = 1000

    public private(set) var mode: Mode = .following
    public private(set) var phase: Phase = .idle
    public private(set) var distance: CGFloat = 0
    /// How far the reader's finger has moved toward older messages.
    public private(set) var dragged: CGFloat = 0
    /// This touch let go of the end, whether it flung, and how far from the
    /// end it began.
    private var detachedThisTouch = false
    private var flung = false
    private var distanceAtTouch: CGFloat = 0
    /// Something arrived below since the reader scrolled up: the button's dot.
    public private(set) var unseenBelow = false
    /// The bottom anchor is gliding the view onto the end (see `.gliding`).
    public private(set) var gliding = false
    /// Off the end because a glide is on its way, not because something
    /// threw the view off it.
    private var midGlide: Bool { gliding && distance <= Self.glideReach }

    public init() {}

    public var nearEnd: Bool { distance <= Self.reattachDistance }
    /// 「回到最新」 shows (besides while an older stretch is loaded).
    public var showsJump: Bool { mode == .detached && !nearEnd }

    public mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case .phase(let p):
            let was = phase
            phase = p
            if p.isUser && !was.isUser {
                dragged = 0
                detachedThisTouch = false
                flung = false
                // Mid-glide the view is a line or two short of the end on its
                // way there: a touch then starts from the end.
                distanceAtTouch = midGlide && mode == .following ? 0 : distance
            }
            if was.isUser && !p.isUser { return scrollEnded() }
            // The way down ended: following from here, exactly on the end
            // (a reply growing during the animation leaves it a little short,
            // and the bottom anchor only holds on the very end).
            if was == .animating && p == .idle && mode == .returning {
                mode = .following
                var fx: [Effect] = [.log("returning → following (landed)")]
                if distance > Self.atEnd { fx.append(.toEnd(animated: false)) }
                return fx
            }
            // A scroll of ours to the end that came to rest somewhere else
            // (the lazy history can throw it to where the laid-out end
            // begins, 13 000 pt short): straight there.
            if was == .animating && p == .idle && mode == .following && !midGlide && distance > Self.reattachDistance {
                return [.log("following: a scroll to the end stopped short"), .toEnd(animated: false)]
            }
            return []

        case .scrolled(let d):
            let before = distance
            distance = d
            // Following, nobody scrolling, and the view is thrown off the end
            // in one step (rows moving between the lazy history and the laid
            // out end, a load landing): following means on the end, so back.
            // Not while growth glides in: that's the anchor on its way.
            if mode == .following, phase == .idle, !midGlide, before <= Self.reattachDistance, d > Self.reattachDistance {
                return [.log("following: thrown off the end by layout"), .toEnd(animated: false)]
            }
            return []

        case .finger(let t):
            dragged = t
            guard phase.isUser, mode != .detached, t >= Self.detachDrag else { return [] }
            detachedThisTouch = true
            return detach("drag")

        case .lifted(let v):
            if v >= Self.flingSpeed { flung = true }
            guard mode != .detached, v >= Self.flingSpeed else { return [] }
            detachedThisTouch = true
            return detach("fling")

        case .grewBelow:
            if mode == .detached, !nearEnd, !unseenBelow { unseenBelow = true }
            // Following but a little off the end (a landing that fell short):
            // the bottom anchor won't hold there, so each growth would push
            // the end further down. Back onto it. (Not mid-glide: off the
            // end is where a glide is on its way.)
            if mode == .following, phase == .idle, !midGlide, distance > Self.atEnd { return [.toEnd(animated: false)] }
            return []

        case .gliding(let on):
            gliding = on
            // Over, and it didn't end on the end: onto it.
            if !on, mode == .following, !phase.isUser, distance > Self.atEnd {
                return [.toEnd(animated: true)]
            }
            return []

        case .bottomInsetGrew:
            return mode == .following && distance > Self.atEnd && !phase.isUser ? [.toEnd(animated: true)] : []

        case .layoutChanged, .foreground:
            return mode == .following && distance > Self.atEnd && !phase.isUser ? [.toEnd(animated: false)] : []

        case .sent:
            // On the end, the bottom anchor carries the sent message up to
            // the top (its turn's room arrives with it, in the same
            // animation): nothing to scroll. Anywhere else, to the end.
            let was = mode
            mode = .following
            unseenBelow = false
            var fx: [Effect] = was == .following ? [] : [.log("\(was.rawValue) → following (sent)"), .holdTopRow(false)]
            if was != .following || distance > Self.atEnd || phase.isUser { fx.append(.toEnd(animated: true)) }
            fx.append(.settleSend)
            return fx

        case .jump(let viewingPast, let screens):
            let was = mode
            mode = .returning
            unseenBelow = false
            // Far away: straight to a screen above the end (every row there
            // is laid out exactly, so that lands where it says), then the
            // rest animated.
            let how: Effect = viewingPast ? .loadLatestThenEnd : screens > 2 ? .nearEndThenAnimate : .toEnd(animated: true)
            return [.log("\(was.rawValue) → returning (jump)"), .holdTopRow(false), how, .checkLanding]

        case .reveal(let id):
            let was = mode
            mode = .detached
            var fx: [Effect] = was == .detached ? [] : [.log("\(was.rawValue) → detached (reveal)"), .holdTopRow(true)]
            fx.append(.center(id: id))
            return fx

        case .landed(let d):
            distance = d
            guard mode == .returning, !phase.isUser else { return [] }
            mode = .following
            var fx: [Effect] = [.log("returning → following (landed)")]
            if d > Self.atEnd { fx.append(.toEnd(animated: false)) }
            return fx

        case .background:
            return [.log("background: \(mode.rawValue)")]
        }
    }

    private mutating func detach(_ why: String) -> [Effect] {
        let was = mode
        mode = .detached
        return [.log("\(was.rawValue) → detached (\(why))"), .holdTopRow(true)]
    }

    /// The reader's finger is off and the list has stopped.
    private mutating func scrollEnded() -> [Effect] {
        switch mode {
        case .following:
            // A drag too short to let go (or a touch that stopped the list
            // short of the end, or the layout throwing it under the finger):
            // back onto the end, where the anchor holds. Far off, at once:
            // a long animated trip crosses the lazy history.
            guard distance > Self.atEnd else { return [] }
            return [.toEnd(animated: distance <= Self.animatedReturn)]
        case .detached:
            // Near the end, or this touch let go with a short drag (not a
            // fling): the end may have moved further away while the finger
            // was down (a reply growing), but what the reader did is what
            // counts.
            let shortDrag = detachedThisTouch && !flung && distanceAtTouch <= Self.reattachDistance
                && dragged < Self.reattachDistance
            guard nearEnd || shortDrag else { return [] }
            mode = .following
            unseenBelow = false
            return [.log("detached → following (scroll ended near the end)"), .holdTopRow(false), .toEnd(animated: true)]
        case .returning:
            // A touch stopped the way down without dragging up: finish it,
            // at once (another touch could stop an animation again).
            mode = .following
            return [.log("returning → following (touched on the way)"), .toEnd(animated: false)]
        }
    }
}
