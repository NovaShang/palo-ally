import Foundation

/// 从历史记录继续…: one list of everything that can be picked up again.
public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        /// A session that ended, was put away, or ended in the terminal lately.
        case earlier(EarlierItem)
        /// A Claude Code session running in the terminal now (adopt).
        case live(CCSession)
    }
    public var source: Source
    public var id: String {
        switch source {
        case .earlier(let e): return e.key
        case .live(let s): return "live:\(s.id)"
        }
    }
    public var sessionId: String {
        switch source {
        case .earlier(let e): return e.sessionId
        case .live(let s): return s.id
        }
    }
    public var title: String {
        switch source {
        case .earlier(let e): return e.displayTitle
        case .live(let s): return s.displayName
        }
    }
    public var cwd: String {
        switch source {
        case .earlier(let e): return e.cwd
        case .live(let s): return s.cwd
        }
    }
    public var path: String { CCSession.shortPath(cwd) }
    /// Milliseconds.
    public var at: Int64 {
        switch source {
        case .earlier(let e): return e.at
        case .live(let s): return s.updatedAt
        }
    }
}

public struct HistoryGroup: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Hashable, CaseIterable { case ended, folded, live, older }
    public var kind: Kind
    public var entries: [HistoryEntry]
    public var id: Int { kind.rawValue }
}

public enum HistoryList {
    /// Sections in the order 刚结束的, 收起来的, 终端里正在跑的, 更早的, newest first
    /// in each; empty ones left out. A terminal conversation that is also running
    /// shows once, as running. A query keeps the entries whose title or folder
    /// has it (any case).
    public static func build(earlier: [EarlierItem], live: [CCSession], query: String = "") -> [HistoryGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let liveIds = Set(live.map(\.id))
        var all: [HistoryEntry] = earlier
            .filter { $0.kind != .unknown && !($0.kind == .recent && liveIds.contains($0.sessionId)) }
            .map { HistoryEntry(source: .earlier($0)) }
        all += live.filter { !$0.isHelper }.map { HistoryEntry(source: .live($0)) }
        if !q.isEmpty {
            all = all.filter { $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        }
        func kind(_ e: HistoryEntry) -> HistoryGroup.Kind {
            switch e.source {
            case .live: return .live
            case .earlier(let i):
                switch i.kind {
                case .ended: return .ended
                case .folded: return .folded
                default: return .older
                }
            }
        }
        return HistoryGroup.Kind.allCases.compactMap { k in
            let list = all.filter { kind($0) == k }.sorted { ($0.at, $0.id) > ($1.at, $1.id) }
            return list.isEmpty ? nil : HistoryGroup(kind: k, entries: list)
        }
    }
}
