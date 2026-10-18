import Foundation

/// Decisions that keep a hold-to-talk from ever sending words the user didn't
/// say. Pure, so they can be tested without a microphone.
///
/// Why: a press that was really a mis-tap (about half a second of near-silence)
/// went to the batch fallback, and the model answered with a sentence from the
/// "参考对话内容" corpus it was given as background. The app then sent it.
public enum VoiceGuard {
    /// A hold with less captured audio than this is a mis-tap, not speech.
    public static let minClipSeconds: Double = 1.0

    /// Bytes of 16-bit mono PCM in `minClipSeconds` at `sampleRate`.
    public static func minClipBytes(sampleRate: Double) -> Int {
        Int(sampleRate * minClipSeconds) * 2
    }

    /// True when the clip is too short to be a message. Words heard live are
    /// proof someone spoke, so they are never dropped here.
    public static func isMisTap(pcmBytes: Int, sampleRate: Double, heardLive: Bool) -> Bool {
        !heardLive && pcmBytes < minClipBytes(sampleRate: sampleRate)
    }

    /// True when `text` is exactly a whole line or sentence of the background
    /// corpus: what a model returns when it has nothing to transcribe. Spaces
    /// and punctuation are ignored, so only an exact repeat counts.
    public static func echoesCorpus(_ text: String, corpus: String) -> Bool {
        let wanted = normalized(text)
        guard wanted.count >= 4 else { return false }
        let separators = CharacterSet(charactersIn: "\n\r。！？!?；;")
        return corpus.components(separatedBy: separators).contains { normalized($0) == wanted }
    }

    private static func normalized(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
    }

    /// Where a final transcript lands. Words that exist only because the
    /// batch fallback produced them (realtime heard nothing, even after the
    /// release) wait in the composer for the user to confirm. When realtime
    /// itself delivers the final after the release, the user really spoke:
    /// it sends as usual.
    public static func mustConfirm(heardLive: Bool, fromBatch: Bool) -> Bool { !heardLive && fromBatch }
}
