import Foundation
import PaloAllyKit
import SwiftUI

/// User-facing wording. Warm, simple, and free of technical words.
enum Copy {
    static func relative(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = ms.msDate
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return String(localized: "刚刚") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// 14:30 today, 「昨天 14:30」, else the month, day and time; the system's
    /// own order, 12 or 24 hour clock and month names.
    static func clock(_ ms: Int64) -> String {
        let date = ms.msDate
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return time }
        if cal.isDateInYesterday(date) { return String(localized: "昨天 \(time)") }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    static func taskStatus(_ s: TaskStatus) -> String {
        switch s {
        case .running: String(localized: "在办")
        case .needsInput: String(localized: "等你回话")
        case .done: String(localized: "办好了")
        case .failed: String(localized: "没办成")
        case .stopped: String(localized: "已停下")
        case .unknown: "—"
        }
    }

    static func taskSymbol(_ s: TaskStatus) -> (String, Color) {
        switch s {
        case .running: ("circle.dotted.circle", .accentColor)
        case .needsInput: ("hand.raised.fill", .orange)
        case .done: ("checkmark.circle.fill", .green)
        case .failed: ("exclamationmark.circle.fill", .red)
        case .stopped: ("stop.circle", .secondary)
        case .unknown: ("circle", .secondary)
        }
    }

    static func approvalStatus(_ s: ApprovalStatus) -> String {
        switch s {
        case .pending: String(localized: "等你决定")
        case .allowed: String(localized: "已允许")
        case .denied: String(localized: "已拒绝")
        case .expired: String(localized: "没来得及回，已自动拒绝")
        case .unknown: "—"
        }
    }

    /// Friendly names for tool identifiers ("用一个工具" when unknown).
    static func tool(_ raw: String?) -> String { Friendly.tool(raw) }

    /// Any error as a short plain sentence (no paths, codes or errno names).
    static func error(_ e: Error) -> String { Friendly.message(e) }

    /// 「每 5 分钟」: how often, the whole phrase (a plural in English).
    static func every(_ m: Int) -> String {
        if m % 60 == 0 { return String(localized: "每 \(m / 60) 小时") }
        if m > 60 { return String(localized: "每 \(m / 60) 小时 \(m % 60) 分钟") }
        return String(localized: "每 \(m) 分钟")
    }

    /// 「每 5 分钟做一次」 / 「每 5 分钟看一次」.
    static func everyDoing(_ m: Int, check: Bool) -> String {
        if m % 60 == 0 { return check ? String(localized: "每 \(m / 60) 小时看一次") : String(localized: "每 \(m / 60) 小时做一次") }
        if m > 60 { return check ? String(localized: "每 \(m / 60) 小时 \(m % 60) 分钟看一次") : String(localized: "每 \(m / 60) 小时 \(m % 60) 分钟做一次") }
        return check ? String(localized: "每 \(m) 分钟看一次") : String(localized: "每 \(m) 分钟做一次")
    }

    static func goalState(_ s: GoalState) -> String {
        switch s {
        case .waiting: String(localized: "需要你")
        case .done: String(localized: "办到了")
        case .paused: String(localized: "已暂停")
        case .tracking, .unknown: String(localized: "在帮你盯着")
        }
    }

    /// 「每月 1 号」「每月最后一天」, or nil for every day.
    static func monthDay(_ d: Int?) -> String? {
        guard let d, d != 0 else { return nil }
        return d == -1 ? String(localized: "每月最后一天") : String(localized: "每月 \(d) 号")
    }

    static func watchSchedule(_ w: Watch) -> String {
        switch w.kind {
        case .schedule:
            let times = ListFormatter.localizedString(byJoining: w.at ?? [])
            if !times.isEmpty { return "\(monthDay(w.dayOfMonth) ?? String(localized: "每天")) \(times)" }
            if let m = w.intervalMinutes, m > 0 { return everyDoing(m, check: false) }
            return String(localized: "到点做")
        case .check:
            guard let m = w.intervalMinutes, m > 0 else { return String(localized: "隔一阵看看") }
            return everyDoing(m, check: true)
        case .unknown:
            return ""
        }
    }

    static func connection(_ c: AppStore.Connection) -> String {
        switch c {
        case .idle: String(localized: "还没连上")
        case .connecting: String(localized: "正在连接…")
        case .syncing: String(localized: "正在同步…")
        case .online: String(localized: "在线")
        case .offline: String(localized: "连不上电脑，正在重试…")
        case .rejected: String(localized: "这台设备需要重新配对")
        }
    }

    /// The same states, short enough for the title capsule.
    static func connectionShort(_ c: AppStore.Connection) -> String {
        switch c {
        case .idle: String(localized: "未连接")
        case .connecting: String(localized: "连接中…")
        case .syncing: String(localized: "同步中…")
        case .online: String(localized: "在线")
        case .offline: String(localized: "连不上电脑")
        case .rejected: String(localized: "需要重新配对")
        }
    }

    static func byteSize(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

extension Artifact {
    var symbol: String {
        switch previewStyle {
        case .markdown: return "doc.richtext"
        case .html: return "globe"
        case .quickLook:
            switch mainExtension {
            case "pdf": return "doc.text"
            case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
            case "csv", "xlsx", "xls", "numbers": return "tablecells"
            case "key", "pptx": return "rectangle.on.rectangle"
            case "mp3", "m4a", "wav": return "waveform"
            case "mp4", "mov": return "film"
            default: return "doc"
            }
        }
    }
}
