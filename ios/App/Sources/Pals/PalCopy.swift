import PaloAllyKit
import SwiftUI

/// Pals' wording: states, the list's second line, a page's subtitle.
extension Copy {
    /// 在忙 / 空闲 / 等你 / 正在启动 / 已停 / 睡着.
    static func palStatus(_ s: PalStatus) -> String {
        switch s {
        // the dot's words (StatusDotKind.word) where the two say the same
        case .busy: StatusDotKind.working.word
        case .idle: StatusDotKind.idle.word
        case .waiting: StatusDotKind.waiting.word
        case .starting: String(localized: "正在启动")
        case .stopped: String(localized: "已停")
        case .asleep: String(localized: "睡着")
        case .unknown: String(localized: "不清楚")
        }
    }

    /// The row's second line: what it's doing or said last (「列表页做完了…」,
    /// 「今天的花费到上限了」); the state's icon beside it already says the
    /// state, so its word shows only when there's nothing else (11-17).
    static func palLine(_ p: Pal) -> String {
        let line = oneLine(p.status == .stopped ? (p.note ?? p.lastLine) : (p.status == .busy ? (p.activity ?? p.lastLine) : p.lastLine))
        return line.isEmpty ? palStatus(p.status) : line
    }

    /// A Pal page's subtitle: 「在忙 · ~/code/site」; stopped, why; being woken, so.
    static func palSubtitle(_ p: Pal, waking: Bool = false) -> String {
        if waking { return String(localized: "正在叫醒…") }
        let second: String
        switch p.status {
        case .stopped: second = oneLine(p.note).nonEmpty ?? p.shortCwd
        default: second = p.shortCwd
        }
        return [palStatus(p.status), second].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func oneLine(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 「Palo 说」: over the assistant's words in a Pal's conversation.
    static func assistantSays(_ name: String) -> String {
        let who = name.isEmpty ? String(localized: "助理") : name
        return spaced(String(localized: "\(who)发来"))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
