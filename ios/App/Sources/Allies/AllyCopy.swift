import CoreImage
import CoreImage.CIFilterBuiltins
import PaloAllyKit
import SwiftUI
import UIKit

/// Allies' wording: tags, exchange states, presence and proposed times.
extension Copy {
    /// Chinese text with names in it: a space between a Chinese character
    /// and Latin letters, either way (「告诉 Palo 就行」, 「告诉小云就行」);
    /// none after punctuation (「加好以后，Palo 和」).
    static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: #"(\p{Han})([A-Za-z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z])(\p{Han})"#, with: "$1 $2", options: .regularExpression)
    }

    /// The tag the owner gave an Ally.
    static func allyKind(_ k: AllyKind) -> String { k == .mine ? String(localized: "我的") : String(localized: "家人朋友") }

    /// An exchange's state as the owner reads it; nil when there's nothing to
    /// say (what came in).
    static func allyStatus(_ e: AllyEntry) -> String? {
        if e.dir == .incoming { return nil }
        switch e.status {
        case .draft: return String(localized: "等你点发送")
        case .queued: return String(localized: "排队中")
        case .sent: return String(localized: "已发出")
        case .delivered: return String(localized: "已送到")
        case .seen: return String(localized: "对方已看到")
        case .rejected:
            let note = e.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return note.isEmpty ? String(localized: "没发") : note
        case .unknown: return nil
        }
    }

    /// 「在线」, 「3小时前在线」, or 「还没联系上」.
    static func allyPresence(_ a: AllyInfo) -> String {
        if a.online { return String(localized: "在线") }
        guard a.lastSeen > 0 else { return String(localized: "还没联系上") }
        return String(localized: "\(relative(a.lastSeen))在线")
    }

    /// The list's last line: what was said last, and by whom when it was
    /// this side (the owner, or their assistant for them).
    static func allyLastLine(_ a: AllyInfo, assistant: String = "") -> String {
        guard let e = a.lastEntry else { return a.online ? String(localized: "在线，还没有来往") : String(localized: "还没有来往") }
        let text = e.text.replacingOccurrences(of: "\n", with: " ")
        if e.dir == .incoming { return text }
        switch e.status {
        case .draft: return String(localized: "草稿：\(text)")
        case .rejected: return String(localized: "没发：\(text)")
        default:
            if e.author == .assistant, !assistant.isEmpty { return spaced("\(assistant)：\(text)") }
            return String(localized: "你：\(text)")
        }
    }

    /// 「Palo 代你说」: over the assistant's words to an Ally for the owner.
    static func saysForYou(_ assistant: String) -> String {
        let name = assistant.isEmpty ? String(localized: "助理") : assistant
        return spaced(String(localized: "\(name)代你说"))
    }

    /// The two trust levels (§11.1).
    static func allyTrust(_ t: AllyTrust) -> String { t == .converse ? String(localized: "能对话") : String(localized: "每句要你看") }

    /// What a trust level means, in a line.
    static func allyTrustNote(_ t: AllyTrust, assistant: String, ally: String) -> String {
        let a = assistant.isEmpty ? String(localized: "助理") : assistant
        return t == .converse
            ? spaced(String(localized: "\(a)直接回\(ally)，每句都留着记录。"))
            : spaced(String(localized: "\(a)回\(ally)的每句话，都先给你看。"))
    }

    /// A proposed time in this device's time zone: 「10月17日 周六 14:00 到 16:00」,
    /// 「明天 9:30 到 10:00」. The raw text if it can't be read.
    static func allySlot(_ slot: AllySlot, now: Date = Date()) -> String {
        guard let start = slot.startDate else { return [slot.start, slot.end].filter { !$0.isEmpty }.joined(separator: String(localized: " 到 ")) }
        let cal = Calendar.current
        func clock(_ d: Date) -> String { d.formatted(.dateTime.hour().minute()) }
        func day(_ d: Date) -> String {
            if cal.isDate(d, inSameDayAs: now) { return String(localized: "今天") }
            if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return String(localized: "明天") }
            if let t = cal.date(byAdding: .day, value: 2, to: now), cal.isDate(d, inSameDayAs: t) { return String(localized: "后天") }
            return cal.isDate(d, equalTo: now, toGranularity: .year)
                ? d.formatted(.dateTime.month().day().weekday(.abbreviated))
                : d.formatted(.dateTime.year().month().day().weekday(.abbreviated))
        }
        let from = "\(day(start)) \(clock(start))"
        guard let end = slot.endDate, end > start else { return from }
        let to = cal.isDate(start, inSameDayAs: end) ? clock(end) : "\(day(end)) \(clock(end))"
        return String(localized: "\(from) 到 \(to)")
    }
}

extension AllyInfo {
    /// The first character, for the round initial standing in for a photo.
    var initial: String { String(displayName.prefix(1)) }
}

/// A QR code made on the device (CoreImage): black on white, sharp at any size.
enum QRCode {
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
