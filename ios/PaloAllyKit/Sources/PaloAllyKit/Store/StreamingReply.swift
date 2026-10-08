import Foundation
import Observation

/// A reply being written: its text so far. The store changes `messages` only
/// when the reply starts and when it ends; in between, each piece goes here.
/// The view showing it subscribes (`listen`) and updates its text directly,
/// so not even SwiftUI is involved per piece (design §3.3); `text` is also
/// observable, for anything that wants it the SwiftUI way.
@MainActor
@Observable
public final class StreamingReply {
    public let id: String
    public private(set) var text: String
    /// The same text, read without subscribing (a view that gets the pieces
    /// through `listen` reads it once without taking every update).
    @ObservationIgnored public private(set) var current: String
    @ObservationIgnored private var listeners: [Int: @MainActor (String) -> Void] = [:]
    @ObservationIgnored private var nextListener = 0

    init(id: String, text: String) {
        self.id = id
        self.text = text
        current = text
    }

    /// Calls `change` with the whole text after each update. Keep the token
    /// to stop (`stopListening`).
    public func listen(_ change: @escaping @MainActor (String) -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = change
        return nextListener
    }

    public func stopListening(_ token: Int) { listeners[token] = nil }

    func append(_ more: String) {
        guard !more.isEmpty else { return }
        current += more
        text = current
        notify()
    }

    func replace(with whole: String) {
        guard whole != current else { return }
        current = whole
        text = whole
        notify()
    }

    private func notify() {
        for l in listeners.values { l(current) }
    }
}
