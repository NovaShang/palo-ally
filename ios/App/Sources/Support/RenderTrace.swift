#if DEBUG
import Foundation
import PaloAllyKit

/// `-renderTrace YES`: counts view body evaluations by name while a reply is
/// written, and logs them when it ends (`[renders]`). Only the reply's own
/// text should show up; any other row, the list or ChatView means a change
/// leaked past the reply (design §3.3, step 4's gate).
@MainActor
enum RenderTrace {
    static let on = UserDefaults.standard.bool(forKey: "renderTrace")
    private static var counts: [String: Int] = [:]
    private static var active = false

    static func note(_ name: String) {
        guard on, active else { return }
        counts[name, default: 0] += 1
    }

    static func reset() {
        guard on else { return }
        counts = [:]
        active = true
    }

    /// Logs what rendered while `id` was written: its own text view, then
    /// the rest (rows, the list, ChatView) with their counts.
    static func report(while id: String) {
        guard on, active else { return }
        active = false
        let own = counts["text \(id)", default: 0]
        let rest = counts.filter { $0.key != "text \(id)" }.sorted { $0.value > $1.value }
        let others = rest.reduce(0) { $0 + $1.value }
        let detail = rest.prefix(12).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        debugLog("[renders] while \(id) was written: its text ×\(own); everything else \(others)\(detail.isEmpty ? "" : " (\(detail))")")
        counts = [:]
    }
}
#endif
