import PaloAllyKit
import SwiftUI

/// How much room the title bar's orb takes. While the owner reads it keeps
/// (about) inside the bar; at rest it's already a little bigger than the bar;
/// when it needs presence (it's thinking, something waits on the owner,
/// something just happened) it grows well past the bar; and while the owner
/// talks to it, it drops out of the bar, very large, listening. Always a
/// spring between sizes, never a jump: the orb floats over the bar, so
/// nothing reflows.
enum OrbPresence: String, Equatable {
    case compact, rest, present, voice

    /// The drop's visible diameter on phones and iPads. `.voice` is the
    /// nominal size; the real one follows the column (`voiceDiameter`).
    var body: CGFloat {
        switch self {
        case .compact: 40
        case .rest: 56
        case .present: 72
        case .voice: 150
        }
    }

    /// Listening: very large, but at most 40% of the column — 150 pt on a
    /// phone, up to 200 pt in an iPad or Mac column.
    static func voiceDiameter(width: CGFloat) -> CGFloat {
        let cap: CGFloat = width < 500 ? 150 : 200
        return max(Self.present.body, min(cap, width * 0.4))
    }

    /// The highest that applies, in priority order: speaking > waiting on
    /// the owner > a fresh event > reading history > thinking > reading the
    /// live end > rest. Reading only outranks thinking while scrolled up.
    static func resolve(speaking: Bool, needsOwner: Bool, event: Bool,
                        scrolledUp: Bool, thinking: Bool, reading: Bool) -> OrbPresence {
        if speaking { return .voice }
        if needsOwner || event { return .present }
        if scrolledUp { return .compact }
        if thinking { return .present }
        if reading { return .compact }
        return .rest
    }
}

/// Works out the orb's presence from the conversation's scroll state, the
/// assistant's status and the owner's voice, and keeps `AppModel.orbPresence`
/// up to date — one place, so every orb reads the same thing. It also feeds
/// the two-drop avatar (AvatarSignals): the assistant's state, and the
/// events it acts out (the owner sends, a reply lands, something's handed
/// over, an approval is answered, an error, reconnecting, the app opening).
struct OrbPresenceTracking: ViewModifier {
    /// Detached from the live bottom, or looking at an older stretch.
    let scrolledUp: Bool
    /// The owner's finger (or its fling) is moving the list.
    let scrolling: Bool
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// Bumps on each event that should briefly grow the orb.
    @State private var event = 0
    @State private var eventActive = false
    /// Stays set a moment after scrolling stops: they're still reading.
    @State private var scrollSettling = false
    /// A long reply that just finished: give it a few quiet seconds.
    @State private var longReplyID: String?
    @State private var freshLongReply = false

    /// Ticks each minute, so quiet hours start and end on time.
    @State private var minute = 0
    /// A drop was shown (not just the quick reconnect on returning to the app).
    @State private var wasOffline = false
    /// Right after switching assistants the new store's state arrives all at
    /// once — not events to act out.
    @State private var settledAt = Date.distantPast

    /// Replies longer than this get read before the orb grows back.
    private static let longReply = 280

    func body(content: Content) -> some View {
        content
            .onChange(of: presence, initial: true) { _, new in
                if model.orbPresence != new { model.orbPresence = new }
            }
            .onChange(of: scrolling) { _, now in if now { scrollSettling = true } }
            .task(id: scrolling) {
                guard !scrolling, scrollSettling else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { scrollSettling = false }
            }
            .task(id: event) {
                guard event > 0 else { return }
                eventActive = true
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { eventActive = false }
            }
            .task(id: longReplyID) {
                guard longReplyID != nil else { return }
                freshLongReply = true
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { freshLongReply = false }
            }
            // The events.
            .onChange(of: store.isBusy) { was, now in
                guard was, !now else { return }
                event += 1 // reply done
                act(.done)
                if let last = store.messages.last, last.role == .assistant, last.text.count > Self.longReply {
                    longReplyID = last.id
                }
            }
            .onChange(of: deliverables) { old, new in if new > old { event += 1; act(.deliverable) } }
            // Back after a drop the owner was shown — not the silent
            // reconnect every return to the app starts with.
            .onChange(of: store.connection.isOnline) { was, now in
                guard !was, now, wasOffline else { return }
                event += 1
                act(.reconnect)
                wasOffline = false
            }
            .onChange(of: lost) { _, now in if now { wasOffline = true } }
            .onChange(of: store.lastError) { _, error in if error != nil { event += 1; act(.error) } }
            .onChange(of: scenePhase) { old, phase in
                guard phase == .active else { return }
                event += 1
                if old == .background { act(.appOpen) }
            }
            .onAppear { event += 1; act(.appOpen) } // the app opens on the conversation
            // The avatar's own: the owner sends, a reply streams in, an approval is answered.
            .onChange(of: store.awaitingReply) { was, now in if !was && now { act(.send) } }
            .onChange(of: streamedLength) { old, new in if new > old { act(.chunk) } }
            .onChange(of: lastAllowedAt) { _, at in if Self.justNow(at) { act(.approve) } }
            .onChange(of: lastDeniedAt) { _, at in if Self.justNow(at) { act(.reject) } }
            .onChange(of: model.activeHostID) { settledAt = Date() }
            .onChange(of: avatarInputs, initial: true) { _, inputs in AvatarSignals.shared.inputs = inputs }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    minute &+= 1
                }
            }
    }

    /// Hands an event to the avatar — unless the assistant was only just
    /// switched (the new one's state arriving isn't news).
    private func act(_ e: TwoDropsState.Event) {
        guard Date().timeIntervalSince(settledAt) > 1.5 else { return }
        AvatarSignals.shared.emit(e)
    }

    /// The assistant's state, as the avatar's inputs (typing and speaking
    /// are added per frame from OrbInput).
    private var avatarInputs: TwoDropsState.Inputs {
        _ = minute
        var i = TwoDropsState.Inputs()
        let streaming = store.messages.contains(where: \.isStreaming)
        let working = store.connection.isOnline && (store.awaitingReply || store.status?.busy == true)
        let running = store.tasks.filter { $0.status == .running }.count
        i.offline = lost
        i.approval = !store.pendingApprovals.isEmpty
        i.streaming = streaming
        i.thinking = working && !streaming
        i.background = running > 0 && !store.isBusy
        i.busyness = min(1, 0.4 + 0.15 * Float(running))
        i.quiet = store.settings?.quietHours.map { Self.within($0, timezone: store.settings?.timezone) } ?? false
        return i
    }

    /// Cut off from the computer, as the owner is shown it: a drop that has
    /// lasted (see AppStore.displayedConnection), or a refusal.
    private var lost: Bool { store.connectionTrouble }

    /// The streaming reply's length: grows with each chunk.
    private var streamedLength: Int { store.messages.last(where: \.isStreaming)?.text.count ?? 0 }

    private var lastAllowedAt: Int64 { store.approvals.filter { $0.status == .allowed }.compactMap(\.decidedAt).max() ?? 0 }
    private var lastDeniedAt: Int64 { store.approvals.filter { $0.status == .denied }.compactMap(\.decidedAt).max() ?? 0 }

    /// Decided in the last few seconds (not an old decision arriving with a sync).
    private static func justNow(_ millis: Int64) -> Bool {
        millis > 0 && abs(Date().timeIntervalSince1970 - Double(millis) / 1000) < 10
    }

    /// Now falls in the quiet window ("23:00"–"08:00" may wrap midnight),
    /// read in the host's time zone.
    static func within(_ q: QuietHours, timezone: String?, now: Date = Date()) -> Bool {
        func minutes(_ s: String) -> Int? {
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : nil
        }
        guard let a = minutes(q.start), let b = minutes(q.end), a != b else { return false }
        var cal = Calendar(identifier: .gregorian)
        if let tz = timezone.flatMap(TimeZone.init(identifier:)) { cal.timeZone = tz }
        let c = cal.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return a < b ? (m >= a && m < b) : (m >= a || m < b)
    }

    private var presence: OrbPresence {
        #if DEBUG
        // `-orbPresence compact|rest|present|voice` holds one size for screenshots.
        if let forced = UserDefaults.standard.string(forKey: "orbPresence").flatMap(OrbPresence.init(rawValue:)) {
            return forced
        }
        #endif
        let streaming = store.messages.contains(where: \.isStreaming)
        let working = store.connection.isOnline && (store.awaitingReply || store.status?.busy == true)
        return OrbPresence.resolve(
            speaking: OrbInput.shared.recording,
            needsOwner: !store.pendingApprovals.isEmpty,
            event: eventActive,
            scrolledUp: scrolledUp,
            thinking: working && !streaming,
            reading: scrolling || scrollSettling || streaming || freshLongReply
        )
    }

    /// Things it handed over: files, images, cards.
    private var deliverables: Int {
        store.messages.reduce(0) { n, m in
            n + (m.role == .assistant && (!(m.attachments ?? []).isEmpty || m.card != nil) ? 1 : 0)
        }
    }
}
