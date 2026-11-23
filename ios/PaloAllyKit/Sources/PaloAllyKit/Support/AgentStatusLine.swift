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
    ///   - pendingQuestions: choice cards waiting on the owner's answer.
    ///   - pendingDrafts: messages to Allies waiting for 发送.
    ///   - pendingProposals: helper proposals waiting for 开吧 / 不用.
    ///   - busy: the main turn is running.
    ///   - activity: what the main turn is doing (host Status.activity).
    ///   - tasks: all tasks; running ones and ones waiting on the owner count.
    public static func make(offlineText: String?, pendingApprovals: Int, pendingQuestions: Int = 0, pendingDrafts: Int = 0,
                            pendingProposals: Int = 0,
                            busy: Bool, activity: String?, tasks: [AllyTask]) -> AgentStatusLine {
        let waiting = tasks.filter { $0.status == .needsInput }.count
        return make(offlineText: offlineText, approvals: pendingApprovals, questions: pendingQuestions, drafts: pendingDrafts,
                    proposals: pendingProposals, other: waiting, busy: busy, activity: activity, tasks: tasks)
    }

    /// The same, with what waits on the owner read from 等你的事: `waiting`
    /// is the conversation's open items, and every one of them counts, so
    /// the line says the number the badge and the 等你 tab say (6fcb2ad).
    /// Its kinds only choose the words: all questions 「N 个问题等你回答」,
    /// all prompts 「N 件等你确认」, else 「N 件事等你」.
    public static func make(offlineText: String?, waiting items: [PendingItem],
                            busy: Bool, activity: String?, tasks: [AllyTask]) -> AgentStatusLine {
        let holding = items.filter(\.isOpen)
        let questions = holding.filter { $0.questionId != nil }.count
        let approvals = holding.filter { $0.approvalId != nil }.count
        let drafts = holding.filter { $0.link?.kind == .allyDraft }.count
        let proposals = holding.filter { $0.link?.kind == .proposal }.count
        return make(offlineText: offlineText, approvals: approvals, questions: questions, drafts: drafts, proposals: proposals,
                    other: holding.count - questions - approvals - drafts - proposals, busy: busy, activity: activity, tasks: tasks)
    }

    private static func make(offlineText: String?, approvals pendingApprovals: Int, questions pendingQuestions: Int,
                             drafts pendingDrafts: Int, proposals pendingProposals: Int, other waiting: Int,
                             busy: Bool, activity: String?, tasks: [AllyTask]) -> AgentStatusLine {
        if let offlineText { return AgentStatusLine(kind: .offline, text: offlineText) }

        let needs = pendingApprovals + waiting + pendingQuestions + pendingDrafts + pendingProposals
        if needs > 0 {
            let text: String
            if pendingQuestions == needs { text = needs == 1 ? loc("等你回答") : loc("\(needs) 个问题等你回答") }
            else if pendingDrafts == needs { text = needs == 1 ? loc("等你点发送") : loc("\(needs) 条等你点发送") }
            else if pendingProposals == needs { text = needs == 1 ? loc("等你点头") : loc("\(needs) 个提议等你点头") }
            else if waiting == 0 && pendingQuestions == 0 && pendingDrafts == 0 && pendingProposals == 0 { text = loc("\(needs) 件等你确认") }
            else { text = loc("\(needs) 件事等你") }
            return AgentStatusLine(kind: .needsYou, text: text)
        }

        let running = tasks.filter { $0.status == .running }.sorted { $0.updatedAt > $1.updatedAt }
        if busy {
            var text = Self.doing(activity)
            if !running.isEmpty { text += loc(" · 另有 \(running.count) 件事") }
            return AgentStatusLine(kind: .working, text: text)
        }
        if let latest = running.first {
            let line = Self.latestLine(latest)
            if running.count == 1 { return AgentStatusLine(kind: .tasks, text: line) }
            return AgentStatusLine(kind: .tasks, text: loc("\(running.count) 件事在做 · \(line)"))
        }
        return AgentStatusLine(kind: .idle, text: loc("空闲"))
    }

    /// The dot beside the line.
    public var dot: StatusDotKind {
        switch kind {
        case .needsYou: .waiting
        case .working, .tasks: .working
        case .offline, .idle: .idle
        }
    }

    /// An agent's line, as the assistant's: what it is doing while it works,
    /// else its state in words (why, when it stopped).
    public static func of(_ pal: Pal) -> AgentStatusLine {
        let dot = pal.dot
        let kind: Kind = switch dot {
        case .waiting: .needsYou
        case .working: pal.status == .busy ? .working : .tasks
        case .done, .idle: .idle
        }
        if pal.status == .busy { return AgentStatusLine(kind: kind, text: doing(pal.activity)) }
        if pal.openInTerminal { return AgentStatusLine(kind: kind, text: loc("终端里开着")) }
        if pal.status == .stopped, let note = pal.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return AgentStatusLine(kind: kind, text: note)
        }
        if dot == .working, pal.tasksRunning > 0 { return AgentStatusLine(kind: kind, text: loc("\(pal.tasksRunning) 件事在做")) }
        if dot == .idle, pal.status == .asleep { return AgentStatusLine(kind: kind, text: loc("睡着")) }
        return AgentStatusLine(kind: kind, text: dot.word)
    }

    /// 「在看网页…」, or 「在想…」 when the host didn't say.
    static func doing(_ activity: String?) -> String {
        let a = (activity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
        return (a.isEmpty ? loc("在想") : a) + "…"
    }

    /// A running task's latest progress line (the harness' own summary), or
    /// its title while there's none yet.
    static func latestLine(_ t: AllyTask) -> String {
        let s = t.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? loc("在做：\(t.title)") : s
    }
}
