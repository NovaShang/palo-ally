import Foundation

/// A slash command the assistant understands (Claude Code built-ins, skills,
/// plugins, plus PaloAlly's own). The UI never advertises these; typing "/"
/// reveals them.
public struct SlashCommand: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var argumentHint: String?
    public var id: String { name }

    public init(name: String, description: String = "", argumentHint: String? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        name = l.string("name", or: "")
        description = l.string("description", or: "")
        argumentHint = l.string("argumentHint")
    }

    /// Commands matching what the user typed after "/" — prefix matches first, then substring.
    public static func filter(_ all: [SlashCommand], typed: String, limit: Int = 8) -> [SlashCommand] {
        let q = typed.lowercased()
        if q.isEmpty { return Array(all.prefix(limit)) }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = all.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return Array((prefix + contains).prefix(limit))
    }
}

public struct CommandsResult: Decodable, Sendable {
    public var commands: [SlashCommand]
    public init(from decoder: Decoder) throws {
        commands = try Lenient(decoder).array(SlashCommand.self, "commands", or: [])
    }
}

/// One model the user can pick, with the thinking depths it supports.
public struct ModelOption: Codable, Sendable, Hashable, Identifiable {
    public var value: String
    public var displayName: String
    public var description: String
    public var efforts: [String]
    public var id: String { value }

    public init(value: String, displayName: String, description: String = "", efforts: [String] = []) {
        self.value = value; self.displayName = displayName; self.description = description; self.efforts = efforts
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        value = l.string("value", or: "")
        displayName = l.string("displayName", or: value)
        description = l.string("description", or: "")
        efforts = l.array(String.self, "efforts", or: [])
    }
}

public struct ModelInfo: Decodable, Sendable, Hashable {
    /// The model actually running, as the host reports it.
    public var model: String
    /// The saved choice; nil = default.
    public var setting: String?
    public var effort: String?
    public var models: [ModelOption]

    public init(model: String = "", setting: String? = nil, effort: String? = nil, models: [ModelOption] = []) {
        self.model = model; self.setting = setting; self.effort = effort; self.models = models
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        model = l.string("model", or: "")
        setting = l.string("setting")
        effort = l.string("effort")
        models = l.array(ModelOption.self, "models", or: [])
    }
}

/// Plain-language names for effort levels.
public enum EffortName {
    public static func label(_ e: String?) -> String {
        switch e {
        case "low": "浅"
        case "medium": "中"
        case "high": "深"
        case "xhigh": "很深"
        case "max": "最深"
        default: "默认"
        }
    }
}

/// A short display name for a model id ("claude-opus-5-5[1m]" → "Opus 5.5").
public enum ModelName {
    public static func short(_ id: String) -> String {
        let base = id.replacingOccurrences(of: #"\[.*\]$"#, with: "", options: .regularExpression)
        let parts = base.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return base.isEmpty ? "默认" : base }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).filter { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }
}
