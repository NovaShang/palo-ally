import PaloAllyKit
import SwiftUI

/// Pals' wording: states, the list's second line, a page's subtitle.
extension Copy {
    /// 在忙 / 空闲 / 等你 / 正在启动 / 已停 / 睡着.
    static func palStatus(_ s: PalStatus) -> String {
        switch s {
        case .busy: String(localized: "在忙")
        case .idle: String(localized: "空闲")
        case .waiting: String(localized: "等你")
        case .starting: String(localized: "正在启动")
        case .stopped: String(localized: "已停")
        case .asleep: String(localized: "睡着")
        case .unknown: String(localized: "不清楚")
        }
    }

    /// The row's second line: 「等你 · 列表页做完了…」, 「已停 · 今天的花费到上限了」,
    /// or just its last words.
    static func palLine(_ p: Pal) -> String {
        let line = oneLine(p.status == .stopped ? (p.note ?? p.lastLine) : (p.status == .busy ? (p.activity ?? p.lastLine) : p.lastLine))
        switch p.status {
        case .idle where !line.isEmpty: return line
        default: return line.isEmpty ? palStatus(p.status) : "\(palStatus(p.status)) · \(line)"
        }
    }

    /// A Pal page's subtitle: 「在忙 · ~/code/site」; stopped, why; asleep,
    /// what waking it cost last time when that's known; being woken, so.
    static func palSubtitle(_ p: Pal, waking: Bool = false) -> String {
        if waking { return String(localized: "正在叫醒…") }
        let second: String
        switch p.status {
        case .stopped: second = oneLine(p.note).nonEmpty ?? p.shortCwd
        case .asleep: second = p.lastWakeUsd.map(wakeCost) ?? p.shortCwd
        default: second = p.shortCwd
        }
        return [palStatus(p.status), second].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 「上次叫醒约 $0.04」: a cold start costs more than a turn (§12).
    static func wakeCost(_ usd: Double) -> String {
        usd < 0.01 ? String(localized: "上次叫醒不到 $0.01") : String(localized: "上次叫醒约 $\(String(format: "%.2f", usd))")
    }

    private static func oneLine(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 「Palo 说」: over the assistant's words in a Pal's conversation.
    static func assistantSays(_ name: String) -> String {
        let who = name.isEmpty ? String(localized: "助理") : name
        return spaced(String(localized: "\(who)说"))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
