import Foundation
import os

// The pieces of bento's BentoFoundation that the voice files (ported from
// bento's modules/BentoVoiceKit at github.com/NovaShang/bento, kept close to the original) rely on.

private let log = Logger(subsystem: "com.novashang.paloally", category: "voice")

/// Mirrors voice logs into the app's exportable debug log (bento's
/// `coreDlogFileSink`). Set once at launch.
public nonisolated(unsafe) var voiceLogSink: (@Sendable (String) -> Void)?

/// The current press's touch-down time (ProcessInfo.systemUptime, the same
/// mach-absolute base as AVAudioTime host time), set by the app so the voice
/// logs can say when the first sample was actually captured. 0 = unknown.
public nonisolated(unsafe) var voiceTouchUptime: TimeInterval = 0

/// Debug log (bento's `dlog`).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    voiceLogSink?(s)
}

/// bento's relay — PaloAlly uses the same worker, which also proxies Qwen ASR
/// with the key held server-side (zero-config for the client).
enum BentoEndpoints {
    static let relayBaseURL = "https://relay.bentoai.dev"
    static var relayWebSocketBase: String {
        relayBaseURL.replacingOccurrences(of: "https://", with: "wss://")
                    .replacingOccurrences(of: "http://", with: "ws://")
    }
}
