#if DEBUG
import Foundation

/// A voice drill for reproducing hangs without a person or a mic (DEBUG):
///   -voiceDrillAudio YES      a synthetic voice instead of the microphone
///   -voiceDrillFailAfter 44   drop the realtime socket that many seconds in
/// The app's `-voiceDrill <seconds>` holds to talk on its own (ComposerView).
public enum VoiceDrill {
    public static var syntheticAudio: Bool { UserDefaults.standard.bool(forKey: "voiceDrillAudio") }
    public static var failAfter: Double { UserDefaults.standard.double(forKey: "voiceDrillFailAfter") }

    /// Feeds 100 ms chunks of 16-bit mono PCM, roughly the rhythm of speech
    /// (a voiced tone in syllable-length bursts, loud enough to open the
    /// speech gate), the way the mic would, until cancelled.
    static func feed(sampleRate: Double, into sink: (@Sendable (Data) -> Void)?) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let n = Int(sampleRate / 10)
            var t = 0
            while !Task.isCancelled {
                var chunk = Data(count: n * 2)
                chunk.withUnsafeMutableBytes { raw in
                    let out = raw.bindMemory(to: Int16.self)
                    for i in 0..<n {
                        let s = Double(t + i) / sampleRate
                        // ~4 syllables a second, a short pause every 2 s.
                        let syllable = max(0, sin(2 * .pi * 4 * s))
                        let phrase = s.truncatingRemainder(dividingBy: 2) < 1.7 ? 1.0 : 0.0
                        let pitch = 140 + 30 * sin(2 * .pi * 0.5 * s)
                        let v = 9000 * syllable * phrase * (sin(2 * .pi * pitch * s) + 0.4 * sin(2 * .pi * 2 * pitch * s))
                        out[i] = Int16(max(-32767, min(32767, v))).littleEndian
                    }
                }
                t += n
                sink?(chunk)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
#endif
