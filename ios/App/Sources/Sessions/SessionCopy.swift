import PaloAllyKit
import SwiftUI

/// Sessions' wording: states, kinds, context size, and who's asking on a card.
extension Copy {
    /// 在忙 / 空闲 / 等你 / 已停.
    static func sessionStatus(_ s: CCSessionStatus) -> String {
        switch s {
        case .busy: String(localized: "在忙")
        case .idle: String(localized: "空闲")
        case .waiting: String(localized: "等你")
        case .stopped: String(localized: "已停")
        case .unknown: String(localized: "不清楚")
        }
    }

    /// The status dot's color: green while working, orange while it waits on
    /// the owner, gray otherwise. Not the theme color (that's for actions).
    static func sessionStatusColor(_ s: CCSessionStatus) -> Color {
        switch s {
        case .busy: .green
        case .waiting: .orange
        case .idle: Color(.systemGray3)
        case .stopped, .unknown: .clear
        }
    }

    /// 帮手 / 终端 / 后台.
    static func sessionKind(_ k: CCSessionKind) -> String {
        switch k {
        case .helper: String(localized: "帮手")
        case .terminal: String(localized: "终端")
        case .background: String(localized: "后台")
        case .unknown: String(localized: "会话")
        }
    }

    /// Context in use, the way the language writes big numbers (「18万」,
    /// 「180K」). Nil when unknown or tiny.
    static func contextSize(_ tokens: Int?) -> String? {
        guard let t = tokens, t >= 1000 else { return nil }
        return t.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// The row's second line: what it waits for, else the last thing said.
    static func sessionLine(_ s: CCSession) -> String {
        let waiting = s.status == .waiting ? s.waitingFor?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let line = (waiting?.isEmpty == false ? waiting : s.lastLine)?
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
        return line
    }

    /// 「在忙 · 上下文 18 万」 and the like, for a session page's subtitle.
    static func sessionSubtitle(_ s: CCSession) -> String {
        var parts = [sessionStatus(s.status)]
        if let size = contextSize(s.contextTokens) { parts.append(String(localized: "上下文 \(size)")) }
        return parts.joined(separator: " · ")
    }

    /// Who's asking on a session's approval card: 「网站帮手 想运行」 for a
    /// command, 「网站帮手 想改文件」 and so on for other tools.
    static func sessionAsks(_ a: Approval) -> String? {
        guard let source = a.source, source.isSession else { return nil }
        let name = source.name.isEmpty ? String(localized: "一个会话") : source.name
        let tool = Friendly.tool(a.tool)
        let verb = Friendly.runsCommand(a.tool) || tool.isEmpty ? String(localized: "运行")
            : (tool == Friendly.unknownToolLabel ? String(localized: "用工具") : tool)
        return spaced(String(localized: "\(name) 想\(verb)"))
    }

    /// 「数据清洗 问你」.
    static func sessionQuestion(_ q: Question) -> String? {
        guard let source = q.source, source.isSession else { return nil }
        let name = source.name.isEmpty ? String(localized: "一个会话") : source.name
        return spaced(String(localized: "\(name) 问你"))
    }

    /// An expired session card: the host's note, else 「在电脑上等你」.
    static func waitsAtComputer(_ note: String?) -> String {
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? String(localized: "在电脑上等你") : n
    }

    /// A daily limit in dollars: 「每天最多 5 美元」.
    static func dailyLimit(_ usd: Double?) -> String? {
        guard let usd, usd > 0 else { return nil }
        let amount = usd == usd.rounded() ? "\(Int(usd))" : String(format: "%.2f", usd)
        return String(localized: "每天最多 \(amount) 美元")
    }
}
