import PaloAllyKit
import SwiftUI

/// How much room the title bar's orb takes. While the owner reads it keeps
/// inside the bar; at rest it's about the bar's height; when it needs
/// presence (they're talking to it, it's thinking, something waits on them,
/// something just happened) it grows past the bar. Always a spring between
/// sizes, never a jump: the orb floats over the bar, so nothing reflows.
enum OrbPresence: String, Equatable {
    case compact, rest, present

    /// The drop's visible diameter on phones and iPads.
    var body: CGFloat {
        switch self {
        case .compact: 32
        case .rest: 44
        case .present: 58
        }
    }

    /// The highest that applies, in priority order: speaking > waiting on
    /// the owner > a fresh event > reading history > thinking > reading the
    /// live end > rest. Reading only outranks thinking while scrolled up.
    static func resolve(speaking: Bool, needsOwner: Bool, event: Bool,
                        scrolledUp: Bool, thinking: Bool, reading: Bool) -> OrbPresence {
        if speaking || needsOwner || event { return .present }
        if scrolledUp { return .compact }
        if thinking { return .present }
        if reading { return .compact }
        return .rest
    }
}

/// Works out the orb's presence from the conversation's scroll state, the
/// assistant's status and the owner's voice, and keeps `AppModel.orbPresence`
/// up to date — one place, so every orb (and the coming two-drop avatar)
/// reads the same thing.
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
                if let last = store.messages.last, last.role == .assistant, last.text.count > Self.longReply {
                    longReplyID = last.id
                }
            }
            .onChange(of: deliverables) { old, new in if new > old { event += 1 } }
            .onChange(of: store.connection.isOnline) { was, now in if !was && now { event += 1 } }
            .onChange(of: store.lastError) { _, error in if error != nil { event += 1 } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { event += 1 } }
            .onAppear { event += 1 } // the app opens on the conversation
    }

    private var presence: OrbPresence {
        #if DEBUG
        // `-orbPresence compact|rest|present` holds one size for screenshots.
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
