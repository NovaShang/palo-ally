import Foundation
import os

// The pieces of bento's BentoFoundation that the voice files (ported from
// ~/code/bento/modules/BentoVoiceKit, kept close to the original) rely on.

private let log = Logger(subsystem: "com.novashang.paloally", category: "voice")

/// Debug log (bento's `dlog`).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
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
