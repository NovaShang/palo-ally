import Foundation

/// Long words one agent sent another fold on a Pal's page (pals-prd §4):
/// the assistant's (「Palo 说」) and another session's. They show their first
/// lines, faded, with 展开全部; the owner's own words and the Pal's replies
/// never fold. A message folds when it takes more than `wholeLines` lines,
/// or more than `foldedLines` when it's over `maxCharacters` long.
public enum MessageFold {
    /// Lines a folded message shows.
    public static let foldedLines = 4
    /// Taller than this folds.
    public static let maxLines = 6
    /// Longer than this folds as soon as it's taller than `foldedLines`.
    public static let maxCharacters = 280

    /// The most lines `text` may take and still show whole.
    public static func wholeLines(_ text: String) -> Int {
        text.count > maxCharacters ? foldedLines : maxLines
    }
}

extension AppStore {
    /// Folds when long: words another agent sent this Pal (the assistant's
    /// or another session's), not the owner's and not the Pal's own.
    public func folds(_ m: ChatMessage) -> Bool {
        guard scope != .palo, m.role == .user, m.kind != .ally else { return false }
        return !(m.from ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 展开全部 (true) or 收起 (false) on a long message.
    public func setUnfolded(_ id: String, _ open: Bool) {
        if open { unfolded.insert(id) } else { unfolded.remove(id) }
    }
}
