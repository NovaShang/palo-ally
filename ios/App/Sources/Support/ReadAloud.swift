import AVFoundation
import PaloAllyKit
import SwiftUI

/// 朗读: one reply read aloud at a time, in the system voice. Starting another
/// switches to it; dictation, the app going to the background and the end of
/// the text stop it. Audio is spoken-word, ducking whatever else plays, and
/// given back when it ends.
@MainActor
@Observable
final class ReadAloud: NSObject {
    static let shared = ReadAloud()

    /// The message being read, or nil.
    private(set) var speaking: String?

    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    /// `-speechSilent YES` (UI tests): the state flips, nothing is said.
    @ObservationIgnored private let silent = UserDefaults.standard.bool(forKey: "speechSilent")

    private override init() {
        super.init()
        synth.delegate = self
        #if os(iOS)
        // No background audio mode: the system would suspend the app and cut
        // the voice mid-sentence, so leaving the app stops it cleanly.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        #endif
    }

    func isReading(_ id: String) -> Bool { speaking == id }

    /// 朗读 / 停止朗读 on one reply.
    func toggle(id: String, markdown: String) {
        if speaking == id { stop(); return }
        stop()
        let language = SpeechText.language(of: markdown)
        let omitted: String = language == .chinese ? "代码略" : "code omitted"  // i18n-ok: said in the text's language
        let words = SpeechText.plain(markdown, codeOmitted: omitted)
        guard !words.isEmpty else { return }
        speaking = id
        if silent { return }
        activateSession()
        let u = AVSpeechUtterance(string: words)
        u.voice = Self.voice(for: language)
        synth.speak(u)
    }

    func stop() {
        guard speaking != nil else { return }
        speaking = nil
        if !silent { synth.stopSpeaking(at: .immediate) }
        releaseSession()
    }

    private func activateSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
        #endif
    }

    private func releaseSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The best installed voice for the language: the device's own region
    /// first (zh-CN, en-GB…), then quality (premium, enhanced, default).
    static func voice(for language: SpeechText.Language) -> AVSpeechSynthesisVoice? {
        let prefix: String
        switch language {
        case .chinese: prefix = "zh"
        case .english: prefix = "en"
        case .other(let code): prefix = String(code.prefix { $0 != "-" })
        }
        let region = Locale.current.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var r = v.quality.rawValue * 10
            if let region, v.language.hasSuffix("-" + region) { r += 100 }
            else if prefix == "zh", v.language == "zh-CN" { r += 50 }
            else if prefix == "en", v.language == "en-US" { r += 50 }
            return r
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: prefix == "zh" ? "zh-CN" : prefix)
    }
}

extension ReadAloud: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // A newer reply may already have taken over.
            guard !self.synth.isSpeaking else { return }
            self.speaking = nil
            self.releaseSession()
        }
    }
}
