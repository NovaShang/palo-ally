import PaloAllyKit
import SwiftUI

/// How 用量 says things (docs/workbench-design/usage.html).
enum UsageText {
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
            return String(localized: "明天 \(date.formatted(.dateTime.hour().minute()))")
        }
        if date.timeIntervalSince(now) < 6.5 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
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
