import Foundation
import Observation
import PaloAllyKit

/// When the 「试试」 suggestions may show at the end of the conversation:
/// on first use, or once the chat has been quiet for a while — never while
/// the owner is engaged with the composer or the assistant is working.
///
/// The composer reports engagement here (it lives in a safe-area inset,
/// apart from the list that shows the suggestions); the list asks `shows`.
@MainActor
@Observable
final class SuggestionsGate {
    static let shared = SuggestionsGate()

    /// How long the chat stays quiet before suggestions come back.
    static let quietInterval: TimeInterval = 3 * 60

    /// Focused, typing, holding to talk, staging attachments, quoting…
    private(set) var composerEngaged = false
    /// The owner's last action in this session (typing, focusing, sending,
    /// recording) or the moment the last reply finished.
    private(set) var lastActivity: Date = .distantPast

    /// Starting or ending engagement counts as activity (the quiet period
    /// starts when the owner leaves the composer); the launch report doesn't.
    func composer(engaged: Bool) {
        guard engaged != composerEngaged else { return }
        composerEngaged = engaged
        touch()
    }

    func touch() { lastActivity = .now }

    /// Since when the chat has been quiet: this session's activity or the
    /// newest message, whichever is later (so reopening the app after a
    /// long gap counts as quiet).
    func quietSince(_ store: AppStore) -> Date {
        let newest = store.messages.last.map { Date(timeIntervalSince1970: TimeInterval($0.ts) / 1000) } ?? .distantPast
        return max(lastActivity, newest)
    }

    /// The owner has barely started: fewer than three messages of theirs, ever.
    func firstUse(_ store: AppStore) -> Bool {
        !store.hasOlderMessages && store.messages.lazy.filter { $0.role == .user }.count < 3
    }

    func shows(_ store: AppStore, now: Date) -> Bool {
        #if DEBUG
        if Self.forced { return !store.suggestions.isEmpty }
        #endif
        guard !store.suggestions.isEmpty, !composerEngaged,
              store.displayedConnection == .online, !store.viewingPast,
              !store.isBusy, store.pendingApprovals.isEmpty, store.pendingQuestions.isEmpty
        else { return false }
        if firstUse(store) { return true }
        return now.timeIntervalSince(quietSince(store)) >= Self.quietInterval
    }

    #if DEBUG
    /// `-suggestions show`: always on, for snapshots.
    static let forced = UserDefaults.standard.string(forKey: "suggestions") == "show"
    #endif
}
