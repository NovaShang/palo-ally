import Foundation

/// What a web tab's address field does with what was typed.
public enum WebAddress {
    /// A page address, or a search for words that aren't one. Nil: nothing typed.
    public static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") || lower == "about:blank" {
            return URL(string: t)
        }
        if !t.contains(" ") {
            let host = String(t.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
            let isLocal = name == "localhost" || name.hasSuffix(".local")
                || name.split(separator: ".").count == 4 && name.split(separator: ".").allSatisfy { Int($0) != nil }
            if isLocal { return URL(string: "http://" + t) }
            if name.contains("."), !name.hasSuffix("."), let u = URL(string: "https://" + t) { return u }
        }
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: t)]
        return c?.url
    }

    /// A short name for a tab: the page's host, without `www.`.
    public static func label(for url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
