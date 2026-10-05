import Foundation

/// 「试试」: something the owner could ask the assistant to do, written by the
/// assistant from what it knows about the owner. The chip is short; tapping
/// it sends `prompt`.
public struct Suggestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var chip: String
    public var prompt: String
    public var category: String?
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey { case id, chip, prompt, category, createdAt }

    public init(id: String, chip: String, prompt: String, category: String? = nil, createdAt: Int64 = 0) {
        self.id = id; self.chip = chip; self.prompt = prompt; self.category = category; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        chip = l.string("chip", or: "")
        prompt = l.string("prompt", or: "")
        category = l.string("category")
        createdAt = l.millis("createdAt", or: 0)
    }
}

/// `suggestions.list` result and the `suggestions.updated` event payload.
public struct SuggestionsResult: Decodable, Sendable {
    public var suggestions: [Suggestion]
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        suggestions = l.decode([Suggestion].self, "suggestions", or: [])
    }
}

public struct SuggestionIDParams: Codable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}
