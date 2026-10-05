import Foundation

/// What the title capsule says about the agent right now, in priority order:
/// something needs the owner > the main turn is working > background tasks >
/// idle. Offline states win over everything (nothing else is trustworthy then).
public struct AgentStatusLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case offline
        case needsYou
        case working
        case tasks
        case idle
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// - Parameters:
    ///   - offlineText: a short connection state when not online (nil = online).
    ///   - pendingApprovals: approvals waiting on the owner.
    ///   - busy: the main turn is running.
    ///   - activity: what the main turn is doing (host Status.activity).
    ///   - tasks: all tasks; running ones and ones waiting on the owner count.
    public static func make(offlineText: String?, pendingApprovals: Int, busy: Bool, activity: String?,
                            tasks: [AllyTask]) -> AgentStatusLine {
        if let offlineText { return AgentStatusLine(kind: .offline, text: offlineText) }

        let waiting = tasks.filter { $0.status == .needsInput }.count
        let needs = pendingApprovals + waiting
        if needs > 0 {
            return AgentStatusLine(kind: .needsYou, text: waiting == 0 ? "\(needs) 件等你确认" : "\(needs) 件事等你")
        }

        let running = tasks.filter { $0.status == .running }.sorted { $0.updatedAt > $1.updatedAt }
        if busy {
            var text = Self.doing(activity)
            if !running.isEmpty { text += " · 另有 \(running.count) 件事" }
            return AgentStatusLine(kind: .working, text: text)
        }
        if let latest = running.first {
            let line = Self.latestLine(latest)
            if running.count == 1 { return AgentStatusLine(kind: .tasks, text: line) }
            return AgentStatusLine(kind: .tasks, text: "\(running.count) 件事在做 · \(line)")
        }
        return AgentStatusLine(kind: .idle, text: "空闲")
    }

    /// 「在看网页…」, or 「在想…」 when the host didn't say.
    static func doing(_ activity: String?) -> String {
        let a = (activity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
        return (a.isEmpty ? "在想" : a) + "…"
    }

    /// A running task's latest progress line (the harness' own summary), or
    /// its title while there's none yet.
    static func latestLine(_ t: AllyTask) -> String {
        let s = t.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "在做：\(t.title)" : s
    }
}
