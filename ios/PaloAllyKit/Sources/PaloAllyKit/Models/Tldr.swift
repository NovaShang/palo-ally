import Foundation

/// 「TL;DR」: a small button under the latest long reply asks the agent
/// itself (the assistant, or a session) for the recent stretch of its
/// conversation in a few points, the owner's own words apart from what was
/// relayed. The app sends just the marker; the computer puts the
/// instruction behind it (one wording, host/src/tldr.ts) and keeps the
/// marker in front of it, so the ask comes back marked `tldr` and is shown
/// folded, after a reload too. Its answer is the agent's next reply.
public enum TldrAsk {
    /// What the app sends (host/src/tldr.ts TLDR_MARKER). Never shown.
    public static let marker = "<!-- paloally:tldr -->"
    /// A reply this long (characters, or lines of text) gets the button.
    public static let longChars = 800
    public static let longLines = 12

    /// Long enough to want its points: `longChars` characters or `longLines` lines.
    public static func isLong(_ text: String) -> Bool {
        if text.count >= longChars { return true }
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where !line.allSatisfy(\.isWhitespace) {
            lines += 1
            if lines >= longLines { return true }
        }
        return false
    }

    /// Words as they are shown: the marker never is.
    public static func shown(_ text: String) -> String {
        guard text.contains(marker) else { return text }
        return text.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatMessage {
    /// The owner's 「TL;DR」 ask: marked by the computer, or the marker the
    /// app just sent (its echo, before the computer's copy comes back).
    public var isTldrAsk: Bool {
        guard role == .user else { return false }
        return tldr == true || text.hasPrefix(TldrAsk.marker)
    }
}
