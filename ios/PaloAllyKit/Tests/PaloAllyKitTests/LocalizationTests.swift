import Foundation
import Testing
@testable import PaloAllyKit

/// Every sentence the owner reads goes through a String Catalog (Chinese is the
/// development language, English the other). These tests keep it that way:
/// a scan of the Swift sources for Chinese string literals that skip
/// localization, and a check that both catalogs are whole.
struct LocalizationTests {
    /// ios/, found from this file's path.
    static let ios: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Files whose strings are still to be moved into the catalog, with how many
    /// Chinese literals each still has. A file here may only get fewer; one that
    /// isn't here must have none. Delete the entry when the file is done.
    static let pending: [String: Int] = [
        "App/Sources/Assistant/ModelRow.swift": 2,
        "App/Sources/Settings/SettingsView.swift": 7,
        "App/Sources/Home/ConversationList.swift": 4,
        "App/Sources/App/RootView.swift": 2,
        "App/Sources/Chat/ComposerIntake.swift": 1,
        "App/Sources/Chat/ComposerView.swift": 10,
        "App/Sources/Pals/RecentConversationsPage.swift": 10,
        "App/Sources/Pals/PalAdoptCard.swift": 7,
        "App/Sources/Pals/PalPage.swift": 16,
        "App/Sources/Pals/PalCopy.swift": 10,
        "App/Sources/Allies/AllyConversationView.swift": 10,
        "App/Sources/Devices/DevicesPage.swift": 21,
    ]

    // MARK: the scan

    static let cjk = try! NSRegularExpression(pattern: #"[一-鿿]"#)
    static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    /// A literal right after one of these is localized (or is a log line).
    static let localizedPrefix = try! NSRegularExpression(
        pattern: #"(?:String\(localized: |\bloc\(|LocalizedStringKey\(|LocalizedStringResource\(|LocalizationValue\(|debugLog\(|appLog\.\w+\(|print\(|assert\(|fatalError\(|verbatim: )$"#)
    /// SwiftUI takes a plain literal here as a LocalizedStringKey.
    static let viewPrefix = try! NSRegularExpression(
        pattern: #"(?:\bText\(|\bButton\(|\bLabel\(|\bSection\(|\bToggle\(|\bTextField\(|\bSecureField\(|\bPicker\(|\bContentUnavailableView\(|\bProgressView\(|\bDisclosureGroup\(|\.navigationTitle\(|\.accessibilityLabel\(|\.accessibilityHint\(|\.accessibilityValue\(|\.help\(|\.alert\(|\.confirmationDialog\(|\bLabeledContent\(|\bDatePicker\(|\bStepper\(|\bMenu\(|\bLink\(|\bNavigationLink\(|\bShareLink\(|prompt: )$"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 1-based line numbers (with the line) of Chinese literals that aren't localized.
    /// Skipped: comments, `#if DEBUG` code, lines marked `i18n-ok` (the host's own
    /// words, patterns), and demo/lab files (see `scanned`).
    static func unlocalized(in source: String) -> [(Int, String)] {
        var hits: [(Int, String)] = []
        var debugDepth = 0
        var inBlockComment = false
        for (i, line) in source.components(separatedBy: "\n").enumerated() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#if DEBUG") { debugDepth += 1 }
            if s.hasPrefix("#endif"), debugDepth > 0 { debugDepth -= 1 }
            if inBlockComment { if s.contains("*/") { inBlockComment = false }; continue }
            if s.hasPrefix("/*"), !s.contains("*/") { inBlockComment = true; continue }
            if debugDepth > 0 || s.hasPrefix("//") || s.hasPrefix("*") || s.contains("i18n-ok") || !matches(cjk, s) { continue }
            var code = line
            if let r = code.range(of: " // "), code[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0 {
                code = String(code[..<r.lowerBound])
            }
            let ns = code as NSString
            for m in literal.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: m.range(at: 1))
                guard matches(cjk, body) else { continue }
                let before = ns.substring(to: m.range.location)
                let after = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
                if matches(localizedPrefix, before) { continue }
                if matches(viewPrefix, before), after.hasPrefix(",") || after.hasPrefix(")") { continue }
                hits.append((i + 1, s))
                break
            }
        }
        return hits
    }

    /// The app's and the Kit's sources, without the demo host, previews and
    /// scroll/glass labs (their words are sample data for a developer).
    static func scanned() -> [URL] {
        var out: [URL] = []
        for dir in ["App/Sources", "PaloAllyKit/Sources"] {
            let root = ios.appendingPathComponent(dir)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let path = url.path
                if path.contains("/Demo/") || url.lastPathComponent.contains("Demo") || url.lastPathComponent.contains("Lab") { continue }
                out.append(url)
            }
        }
        return out
    }

    @Test func noChineseLiteralSkipsLocalization() throws {
        var problems: [String] = []
        for url in Self.scanned() {
            let rel = String(url.path.dropFirst(Self.ios.path.count + 1))
            let hits = Self.unlocalized(in: try String(contentsOf: url, encoding: .utf8))
            let allowed = Self.pending[rel] ?? 0
            if hits.count > allowed {
                for (n, line) in hits { problems.append("\(rel):\(n): \(line)") }
            }
        }
        #expect(problems.isEmpty, "Chinese text that skips localization (use Text(\"…\"), String(localized:), or `// i18n-ok: why`):\n\(problems.joined(separator: "\n"))")
    }

    @Test func theScannerSeesWhatItShould() {
        let hits = Self.unlocalized(in: """
        Text("好")
        let a = "坏"
        let b = String(localized: "好")
        Button("好", action: go)
        Text(flag ? "坏" : "坏")
        // let c = "注释"
        let d = "坏" // 注释
        let e = "豁免" // i18n-ok: the host's words
        """)
        #expect(hits.map(\.0) == [2, 5, 7])
    }

    // MARK: the catalogs

    static func catalog(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: ios.appendingPathComponent(path))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// printf-style specifiers in order ("%lld", "%@"), to compare a key with its translation.
    static func specifiers(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:l+d|@|f|lf|d|s)"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map {
            String(s[Range($0.range, in: s)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }
    }

    static func values(_ en: [String: Any]) -> [String] {
        if let unit = en["stringUnit"] as? [String: Any], let v = unit["value"] as? String { return [v] }
        if let variations = en["variations"] as? [String: Any] {
            return variations.values.flatMap { kind -> [String] in
                (kind as? [String: Any])?.values.flatMap { values($0 as? [String: Any] ?? [:]) } ?? []
            }
        }
        return []
    }

    @Test(arguments: ["App/Resources/Localizable.xcstrings", "PaloAllyKit/Sources/PaloAllyKit/Resources/Localizable.xcstrings",
                      "App/Resources/InfoPlist.xcstrings"])
    func everyKeyHasAnEnglishTranslationWithTheSameSlots(path: String) throws {
        let strings = try Self.catalog(path)["strings"] as! [String: [String: Any]]
        #expect(!strings.isEmpty)
        var problems: [String] = []
        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
            guard let loc = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any] else {
                problems.append("no English: \(key)"); continue
            }
            let vs = Self.values(loc)
            if vs.isEmpty || vs.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { problems.append("empty English: \(key)") }
            let slots = Set(Self.specifiers(key))
            for v in vs where !slots.isSuperset(of: Self.specifiers(v)) || (!Set(Self.specifiers(v)).isSuperset(of: slots) && (loc["variations"] == nil)) {
                problems.append("slots differ: \(key) -> \(v)")
            }
            if let unit = loc["stringUnit"] as? [String: Any], unit["state"] as? String != "translated" { problems.append("not translated: \(key)") }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}

/// What the host says about language is read when present and not needed when absent.
struct HostLanguageTests {
    @Test func helloAndSettingsCarryTheHostsLanguage() throws {
        let hello = try JSONDecoder().decode(HelloResult.self, from: Data(#"{"hostName":"Mac","version":"1","language":"en"}"#.utf8))
        #expect(hello.language == "en")
        let old = try JSONDecoder().decode(HelloResult.self, from: Data(#"{"hostName":"Mac","version":"1"}"#.utf8))
        #expect(old.language == nil)
        let s = try JSONDecoder().decode(HostSettings.self, from: Data(#"{"language":"zh"}"#.utf8))
        #expect(s.language == "zh")
        // Not sent back to a host that never said one.
        let sent = try JSONEncoder().encode(HostSettings())
        #expect(!String(decoding: sent, as: UTF8.self).contains("language"))
    }
}
