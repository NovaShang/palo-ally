import PaloAllyKit
import SwiftUI

/// How 用量 says things (docs/workbench-design/usage.html).
enum UsageText {
    /// `Copy.spaced`, and a time's words run on in Chinese (「周四上午9:16」, 「按平均速度下午6:12 左右」).
    static func tidy(_ text: String) -> String {
        Copy.spaced(text).replacingOccurrences(of: #"(\p{Han}) +(?=\p{Han})"#, with: "$1", options: .regularExpression)
    }

    /// 「5 小时」, 「本周」, 「本周 Opus」; a kind this app doesn't know by what it's for, or its own name.
    static func name(_ l: UsageLimit) -> String {
        switch (l.group, l.scope) {
        case ("session", nil): String(localized: "5 小时")
        case ("weekly", nil): String(localized: "本周")
        case ("weekly", let scope?): String(localized: "本周 \(scope)")
        default: l.scope ?? l.kind
        }
    }

    /// When a limit resets: 18:40 today, 「明天 22:00」, 「周四 09:00」 within the week, else the date; the system's clock.
    static func when(_ ms: Int64, now: Date = Date()) -> String {
        let date = ms.msDate, cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) {
            return tidy(String(localized: "明天 \(date.formatted(.dateTime.hour().minute()))"))
        }
        if date.timeIntervalSince(now) < 6.5 * 86_400 { return tidy(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    /// The row's line for one limit: 「本周剩 43%」, 「5 小时用完，18:40 恢复」.
    static func line(_ l: UsageLimit, now: Date = Date()) -> String {
        if !l.isUsedUp {
            let left = "\(l.left)%"
            return Copy.spaced(String(localized: "\(name(l))剩 \(left)"))
        }
        guard let at = l.resetsAt else { return Copy.spaced(String(localized: "\(name(l))用完了")) }
        return Copy.spaced(String(localized: "\(name(l))用完，\(when(at, now: now)) 恢复"))
    }

    /// The page's name for it: 「本周 · Opus」.
    static func title(_ l: UsageLimit) -> String {
        if l.group == "weekly", let scope = l.scope { return String(localized: "本周 · \(scope)") }
        return name(l)
    }

    /// 「18:40 重置，还有 1 小时 52 分」; `left`: with how long that is.
    static func reset(_ l: UsageLimit, now: Date, left: Bool) -> String? {
        guard let at = l.resetsAt, !l.hasReset(now) else { return nil }
        let when = when(at, now: now)
        guard left else { return String(localized: "\(when) 重置") }
        return String(localized: "\(when) 重置，还有 \(span(at.msDate.timeIntervalSince(now)))")
    }

    /// 「2 天 16 小时」, 「1 小时 52 分」, 「36 分钟」.
    static func span(_ seconds: TimeInterval) -> String {
        let m = max(1, Int(seconds / 60)), h = m / 60, d = h / 24
        if d > 0 { return h % 24 > 0 ? String(localized: "\(d) 天 \(h % 24) 小时") : String(localized: "\(d) 天") }
        if h > 0 { return m % 60 > 0 ? String(localized: "\(h) 小时 \(m % 60) 分") : String(localized: "\(h) 小时") }
        return String(localized: "\(m) 分钟")
    }

    /// Whether it lasts, at the window's average pace so far.
    static func pace(_ l: UsageLimit, now: Date) -> String? {
        switch l.pace(now) {
        case .lasts: String(localized: "按平均速度够用到重置")
        case .runsOut(let at): tidy(String(localized: "按平均速度 \(when(at.epochMillis, now: now)) 左右用完"))
        case nil: nil
        }
    }

    /// A login with no plan limits, by what it is.
    static func keyed(_ a: LoginAccount?) -> String {
        switch a?.provider {
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case let p?: p
        case nil: String(localized: "API 密钥")
        }
    }

    /// The indicator's arc colors; nil while there's room.
    static func tint(_ l: UsageLimit) -> Color? {
        switch l.tone {
        case .normal: nil
        case .warn: Color(rgb: 0xFF9F0A)
        case .danger: Color(rgb: 0xFF453A)
        }
    }
}
