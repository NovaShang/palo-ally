import Foundation

/// The words of a recording as they come in, kept on the device until the
/// recording ends: if the app ends first (a crash, 11-02), they go back into
/// the draft of the conversation they were for on the next launch
/// (DraftBox). No audio is kept, only the words (the owner's call, 11-03).
@MainActor
enum VoiceRecovery {
    /// The draft the next recording's words are for (DraftBox.persistKey),
    /// set by the composer that starts it; nil: not kept.
    static var target: String?

    private static let key = "voiceRecovery"

    /// The words so far (each update replaces the last).
    static func save(_ text: String) {
        guard let target, !text.isEmpty else { return }
        UserDefaults.standard.set(["target": target, "text": text], forKey: key)
    }

    /// The recording ended (its words went where they were going, or were dropped).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The words an unfinished recording left for this draft, once.
    static func take(for draft: String) -> String? {
        guard let kept = UserDefaults.standard.dictionary(forKey: key),
              kept["target"] as? String == draft,
              let text = kept["text"] as? String, !text.isEmpty else { return nil }
        clear()
        return text
    }
}
