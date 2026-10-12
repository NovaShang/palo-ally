import PaloAllyKit
import SwiftUI

/// Pals' wording: states, the list's second line, a page's subtitle.
extension Copy {
    /// 在忙 / 空闲 / 等你 / 正在启动 / 已停.
    static func palStatus(_ s: PalStatus) -> String {
        switch s {
        case .busy: "在忙"
        case .idle: "空闲"
        case .waiting: "等你"
        case .starting: "正在启动"
        case .stopped: "已停"
        case .unknown: "不清楚"
        }
    }

    /// The state's dot: green while working, orange while it waits on the
    /// owner, gray otherwise; none when it's stopped. Not the theme color.
    static func palStatusColor(_ s: PalStatus) -> Color? {
        switch s {
        case .busy, .starting: .green
        case .waiting: .orange
        case .idle: Color(.systemGray3)
        case .stopped, .unknown: nil
        }
    }

    /// The row's second line: 「等你 · 列表页做完了…」, or just its last words.
    static func palLine(_ p: Pal) -> String {
        let line = (p.lastLine ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        switch p.status {
        case .idle where !line.isEmpty: return line
        default: return line.isEmpty ? palStatus(p.status) : "\(palStatus(p.status)) · \(line)"
        }
    }

    /// A Pal page's subtitle: 「在忙 · ~/code/site」.
    static func palSubtitle(_ p: Pal) -> String {
        [palStatus(p.status), p.shortCwd].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 「Palo 说」: over the assistant's words in a Pal's conversation.
    static func assistantSays(_ name: String) -> String {
        spaced("\(name.isEmpty ? "助理" : name)说")
    }
}
