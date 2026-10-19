import Foundation

// The pure rules behind the round session indicator (indicator-design):
// which color class a model belongs to, what the effort label says and
// when the context arc warns.

/// The model families the indicator tells apart by the effort label's color,
/// cool to warm: the stronger the model, the warmer the color.
public enum IndicatorModelClass: String, Sendable, CaseIterable {
    case haiku, sonnet, opus, fable, other

    /// Maps a model id or display name ("claude-opus-5-5", "default",
    /// "Sonnet 4.5", "opus[1m]") to its class. Anything unknown is `.other`.
    public init(modelId: String?) {
        let s = (modelId ?? "").lowercased()
        if s.contains("haiku") { self = .haiku }
        else if s.contains("sonnet") { self = .sonnet }
        else if s.contains("opus") { self = .opus }
        else if s.contains("fable") { self = .fable }
        else { self = .other }
    }

    /// The label color as 0xRRGGBB.
    public var rgb: UInt32 {
        switch self {
        case .haiku: 0x8FD5E8
        case .sonnet: 0xA6B6F7
        case .opus: 0xD6A6EE
        case .fable: 0xF4A7A0
        case .other: 0xC7C7CC
        }
    }
}

public enum IndicatorRules {
    /// Below this the indicator is the state glyph alone.
    public static let ringMinSize: Double = 26
    public static let warnFraction = 0.8
    public static let dangerFraction = 0.95

    public enum ArcTone: Sendable, Equatable { case normal, warn, danger }

    /// White normally, orange from 80%, red from 95%.
    public static func arcTone(fraction: Double) -> ArcTone {
        if fraction >= dangerFraction { return .danger }
        if fraction >= warnFraction { return .warn }
        return .normal
    }

    /// 0...1 from a 0...100 percentage; nil means unknown (an empty arc).
    public static func fraction(pct: Int?) -> Double {
        guard let pct else { return 0 }
        return min(1, max(0, Double(pct) / 100))
    }

    /// low / med / hi / xhi / max. Unknown or missing efforts show nothing.
    public static func effortLabel(_ effort: String?) -> String? {
        switch (effort ?? "").lowercased() {
        case "low": "low"
        case "medium", "med": "med"
        case "high", "hi": "hi"
        case "xhigh", "xhi": "xhi"
        case "max": "max"
        default: nil
        }
    }

    public static func showsRing(size: Double) -> Bool { size >= ringMinSize }
}
