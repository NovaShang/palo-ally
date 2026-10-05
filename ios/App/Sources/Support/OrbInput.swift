import Foundation
import Observation

/// What the owner is doing that the orb listens to: typing (a counter that
/// ticks with every edit) and speaking (recording, and the live mic level the
/// recording UI's waveform shows). One shared instance, because the Mac's
/// title-bar orb lives in the window toolbar, outside the SwiftUI hierarchy
/// that owns the composer.
@MainActor
@Observable
final class OrbInput {
    static let shared = OrbInput()

    /// Ticks once per edit in the composer.
    private(set) var typingPulse = 0
    /// Recording a voice message.
    private(set) var recording = false
    /// Input loudness while recording, 0…1.
    private(set) var level: Float = 0

    func typed() { typingPulse &+= 1 }

    func voice(recording: Bool, level: Float) {
        if self.recording != recording { self.recording = recording }
        let l = recording ? min(max(level, 0), 1) : 0
        if l != self.level { self.level = l }
    }

    #if DEBUG
    /// `-orbSine YES`: a synthetic waveform, so the orb's response to speech
    /// can be checked where there's no microphone to hold.
    func startSyntheticVoice() {
        Task { @MainActor in
            let start = Date()
            while true {
                let t = Date().timeIntervalSince(start)
                // syllable-like bursts over a slower phrase envelope
                let phrase = 0.5 + 0.5 * sin(t * 1.3)
                let syllable = max(0, sin(t * 11.0)) * (0.6 + 0.4 * sin(t * 3.7))
                voice(recording: true, level: Float(phrase * syllable))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
    #endif
}
