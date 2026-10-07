import Foundation
import Observation
import PaloAllyKit
import PaloAllyVoice

/// Hold-to-talk dictation, driven by bento's `VoiceSession` (ported in
/// PaloAllyVoice): Qwen realtime recognition through the relay by default —
/// far better for 中文 and 中英混说 than Apple's on-device model — with the
/// mic prewarmed on finger-down and opening words buffered while the socket
/// connects.
@MainActor
@Observable
final class SpeechDictation {
    private(set) var isRecording = false {
        // The orb in the title bar listens along.
        didSet { OrbInput.shared.voice(recording: isRecording, level: level) }
    }
    private(set) var transcript = ""
    var errorMessage: String?
    /// Recent input loudness, 0…1 (drives the level meter).
    private(set) var level: Float = 0 {
        didSet { OrbInput.shared.voice(recording: isRecording, level: level) }
    }

    @ObservationIgnored private let session = VoiceSession()

    /// Background text for the recognizer (names and terms from the
    /// conversation), read when a recording starts. See `VoiceContext`.
    @ObservationIgnored var contextProvider: (() -> String?)? {
        didSet {
            guard let provide = contextProvider else { session.contextProvider = nil; return }
            session.contextProvider = {
                let text = provide()
                // The size only: the context is conversation text.
                debugLog("voice context: \(text?.count ?? 0) chars")
                return text
            }
        }
    }
    /// Which recording callbacks belong to: a quick tap arms and cancels a
    /// recording, and its teardown must never show up as an error.
    @ObservationIgnored private var generation = VoiceGeneration()

    /// Finger down, before we know it's a hold: no mic indicator, just warm-up.
    func prewarm() { session.prewarm() }

    /// App left the foreground: let the audio session go (others get it back).
    func coolDown() { AudioCaptureService.setSessionWarm(false) }

    /// When this recording started (for the breadcrumbs).
    @ObservationIgnored private var startedAt = Date()

    func start() {
        breadcrumb("voice start")
        startedAt = Date()
        errorMessage = nil
        transcript = ""
        isRecording = true
        let token = generation.next()
        session.onLevel = { [weak self] l in self?.level = l }
        session.start(
            onPartial: { [weak self] text in
                guard let self, self.generation.isCurrent(token) else { return }
                self.transcript = text
            },
            onError: { [weak self] message in
                guard let self, self.generation.isCurrent(token) else {
                    debugLog("voice error from a cancelled recording ignored: \(message)")
                    return
                }
                debugLog("voice error: \(message)")
                breadcrumb("voice error \(Int(Date().timeIntervalSince(self.startedAt))) s in")
                self.errorMessage = Self.friendly(message)
            }
        )
    }

    /// Stops listening and returns the final text.
    func finish() async -> String {
        guard isRecording else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
        breadcrumb("voice finish after \(Int(Date().timeIntervalSince(startedAt))) s")
        let text = await session.finish(language: lang)
        breadcrumb("voice final: \(text.count) chars")
        isRecording = false
        level = 0
        if !text.isEmpty {
            transcript = text
            // A connection lost mid-recording was recovered from the clip.
            errorMessage = nil
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops and throws the text away.
    func cancel() {
        if isRecording { breadcrumb("voice cancel") }
        generation.invalidate()
        session.cancel()
        isRecording = false
        level = 0
        transcript = ""
    }

    private static func friendly(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("permission") { return "需要在「设置」里允许使用麦克风" }
        if m.contains("quota") { return "今天的语音额度用完了，明天再试" }
        return "语音识别没连上，再试一次"
    }
}
