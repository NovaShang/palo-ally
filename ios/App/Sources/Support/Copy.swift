import Foundation
import PaloAllyKit
import SwiftUI

/// User-facing wording. Warm, simple, and free of technical words.
enum Copy {
    static let zh = Locale(identifier: "zh_CN")

    static func relative(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = ms.msDate
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        let f = RelativeDateTimeFormatter()
        f.locale = zh
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func clock(_ ms: Int64) -> String {
        let date = ms.msDate
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = zh
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            f.dateFormat = "昨天 HH:mm"
        } else {
            f.dateFormat = "M月d日 HH:mm"
        }
        return f.string(from: date)
    }

    static func taskStatus(_ s: TaskStatus) -> String {
        switch s {
        case .running: "在办"
        case .needsInput: "等你回话"
        case .done: "办好了"
        case .failed: "没办成"
        case .stopped: "已停下"
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
        case .pending: "等你决定"
        case .allowed: "已允许"
        case .denied: "已拒绝"
        case .expired: "没来得及回，已自动拒绝"
        case .unknown: "—"
        }
    }

    /// Friendly names for common tool identifiers.
    static func tool(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let lower = raw.lowercased()
        let table: [(String, String)] = [
            ("send_email", "发邮件"), ("email", "邮件"), ("bash", "运行命令"), ("read", "读文件"),
            ("write", "写文件"), ("edit", "改文件"), ("webfetch", "看网页"), ("websearch", "上网搜索"),
            ("grep", "找文件"), ("glob", "找文件"), ("navigate", "打开网页"), ("browser", "操作浏览器"),
            ("click", "点网页"), ("task", "分派小帮手"), ("agent", "分派小帮手"), ("notify", "提醒你"),
            ("wechat", "微信"), ("pay", "付款"), ("delete", "删除"), ("remove", "删除"), ("post", "发出去"),
        ]
        for (k, v) in table where lower.contains(k) { return v }
        return raw
    }

    static func watchSchedule(_ w: Watch) -> String {
        switch w.kind {
        case .schedule:
            let times = (w.at ?? []).joined(separator: "、")
            return times.isEmpty ? "到点做" : "每天 \(times)"
        case .check:
            guard let m = w.intervalMinutes, m > 0 else { return "隔一阵看看" }
            if m % 60 == 0 { return "每 \(m / 60) 小时看一次" }
            return "每 \(m) 分钟看一次"
        case .unknown:
            return ""
        }
    }

    static func connection(_ c: AppStore.Connection) -> String {
        switch c {
        case .idle: "还没连上"
        case .connecting: "正在连接…"
        case .syncing: "正在同步…"
        case .online: "在线"
        case .offline: "连不上电脑，正在重试…"
        case .rejected: "这台设备需要重新配对"
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
