import Foundation

/// Plain-language wording for things that come off the wire with technical
/// names: tool identifiers and error messages.
public enum Friendly {
    // MARK: tools

    /// Word-level rules, checked in order. A rule matches when all its words
    /// appear as whole tokens of the tool name (so "thread" never matches
    /// "read", and "credit" never matches "edit").
    static let toolRules: [([String], String)] = [
        (["send", "email"], "发邮件"), (["send", "mail"], "发邮件"), (["send", "message"], "发消息"),
        (["wechat"], "微信"), (["weixin"], "微信"),
        (["email"], "邮件"), (["gmail"], "邮件"), (["mail"], "邮件"),
        (["calendar"], "日历"),
        (["bash"], "运行命令"), (["shell"], "运行命令"), (["exec"], "运行命令"),
        (["webfetch"], "看网页"), (["fetch"], "看网页"), (["websearch"], "上网搜索"), (["search"], "搜索"),
        (["read"], "读文件"), (["notebookread"], "读文件"),
        (["write"], "写文件"), (["notebookedit"], "改文件"), (["multiedit"], "改文件"), (["edit"], "改文件"),
        (["grep"], "找文件"), (["glob"], "找文件"), (["ls"], "看文件夹"),
        (["navigate"], "打开网页"), (["browser"], "操作浏览器"), (["chrome"], "操作浏览器"),
        (["playwright"], "操作浏览器"), (["click"], "点网页"), (["screenshot"], "截图"),
        (["task"], "分派小帮手"), (["agent"], "分派小帮手"), (["todowrite"], "记待办"),
        (["notify"], "提醒你"), (["remind"], "提醒你"),
        (["pay"], "付款"), (["payment"], "付款"), (["purchase"], "付款"),
        (["delete"], "删除"), (["remove"], "删除"), (["trash"], "删除"),
        (["post"], "发出去"), (["publish"], "发出去"), (["tweet"], "发出去"),
    ]

    /// Splits "mcp__gmail__send_email", "WebFetch", "send-email" into
    /// lowercase word tokens (keeping the joined form too, e.g. "webfetch").
    static func toolTokens(_ raw: String) -> Set<String> {
        var tokens: Set<String> = []
        for part in raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let p = String(part)
            tokens.insert(p.lowercased())
            // camelCase / PascalCase pieces.
            var word = ""
            for ch in p {
                if ch.isUppercase, !word.isEmpty, !(word.last?.isUppercase ?? false) {
                    tokens.insert(word.lowercased()); word = ""
                }
                word.append(ch)
            }
            if !word.isEmpty { tokens.insert(word.lowercased()) }
        }
        return tokens
    }

    /// A friendly label for a tool name; "用一个工具" when unknown.
    public static func tool(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let tokens = toolTokens(raw)
        for (words, label) in toolRules where words.allSatisfy(tokens.contains) { return label }
        return "用一个工具"
    }

    // MARK: errors

    /// A short Chinese sentence for any error. Never shows raw errno codes,
    /// file paths or framework error numbers.
    public static func message(_ error: Error) -> String {
        if let e = error as? RPCError {
            switch e {
            case .remote(let m): return remote(m)
            default: return e.errorDescription ?? "出了点问题"
            }
        }
        if error is KeychainError { return "这台设备没法安全保存配对信息" }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "网络太慢了，稍后再试"
            case .notConnectedToInternet, .networkConnectionLost: return "网络好像断了"
            default: return "网络好像不太通，稍后再试"
            }
        }
        if error is DecodingError { return "收到的回复看不懂" }
        if error is CancellationError { return "已取消" }
        if let l = error as? LocalizedError, let d = l.errorDescription, containsCJK(d), !looksTechnical(d) { return d }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "这台设备空间不够了"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "找不到这个文件"
            default: return "存文件时出了点问题"
            }
        }
        return "出了点问题，稍后再试"
    }

    /// Host-side error text. Chinese sentences from the host pass through;
    /// technical text is mapped to plain words.
    public static func remote(_ m: String) -> String {
        let lower = m.lowercased()
        if lower.contains("enoent") || lower.contains("no such file") || lower.contains("not found") { return "找不到这个文件" }
        if lower.contains("eacces") || lower.contains("eperm") || lower.contains("permission denied") { return "电脑那边没有权限做这个" }
        if lower.contains("enospc") { return "电脑的空间不够了" }
        if lower.contains("eisdir") { return "这是个文件夹，不是文件" }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("etimedout") { return "等太久了，稍后再试" }
        if lower.contains("too large") || lower.contains("e2big") { return "文件太大了" }
        if lower.contains("unknown method") { return "电脑上的 PaloAlly 版本太旧，需要更新一下" }
        if containsCJK(m) && !looksTechnical(m) { return m }
        return "电脑那边出了点问题，稍后再试"
    }

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// Paths, errno names, "error -34018" style codes, stack-ish text.
    static func looksTechnical(_ s: String) -> Bool {
        if s.range(of: #"(^|[\s:(（'"])(/|~/)[^\s]+"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"\bE[A-Z]{3,}\b"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"-\d{3,}"#, options: .regularExpression) != nil { return true }
        if s.contains("Error:") || s.contains("at ") && s.contains(".js:") { return true }
        return false
    }
}

/// Reads `aps-environment` out of an embedded provisioning profile
/// (`embedded.mobileprovision` / `embedded.provisionprofile`). The file is a
/// CMS-signed blob with the plist in the clear inside it.
public enum ProvisioningProfile {
    public static func apsEnvironment(from data: Data) -> String? {
        guard let plist = plistData(in: data),
              let obj = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let ent = obj["Entitlements"] as? [String: Any] else { return nil }
        return (ent["aps-environment"] as? String) ?? (ent["com.apple.developer.aps-environment"] as? String)
    }

    static func plistData(in data: Data) -> Data? {
        let start = data.range(of: Data("<?xml".utf8)) ?? data.range(of: Data("<plist".utf8))
        guard let start, let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    /// "development" → sandbox, "production" → production, else nil.
    public static func pushEnvironment(from data: Data) -> PushEnvironment? {
        switch apsEnvironment(from: data) {
        case "development": .sandbox
        case "production": .production
        default: nil
        }
    }
}
