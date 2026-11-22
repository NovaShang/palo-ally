import PaloAllyKit
import SwiftUI

/// Sessions' wording: states, kinds, context size, and who's asking on a card.
extension Copy {
    /// 在忙 / 空闲 / 等你 / 已停: the dot's words (StatusDotKind.word) where
    /// the two say the same, as a Pal's (`palStatus`).
    static func sessionStatus(_ s: CCSessionStatus) -> String {
        switch s {
        case .busy: StatusDotKind.working.word
        case .idle: StatusDotKind.idle.word
        case .waiting: StatusDotKind.waiting.word
        case .stopped: String(localized: "已停")
        case .unknown: String(localized: "不清楚")
        }
    }

    /// Palo 开的 / 终端 / 后台.
    static func sessionKind(_ k: CCSessionKind) -> String {
        switch k {
        case .helper: String(localized: "助理开的")
        case .terminal: String(localized: "终端")
        case .background: String(localized: "后台")
        case .unknown: String(localized: "其他")
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

    /// An expired session card: the host's note, else 「在电脑上等你」.
    static func waitsAtComputer(_ note: String?) -> String {
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? String(localized: "在主机上等你") : n
    }
}
