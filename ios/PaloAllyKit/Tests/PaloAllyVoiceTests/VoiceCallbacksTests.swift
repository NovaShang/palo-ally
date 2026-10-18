import Foundation
import Testing
@testable import PaloAllyVoice

@Suite("Voice callbacks")
struct VoiceCallbacksTests {
    @Test func cancelledRecordingCallbacksAreStale() {
        var g = VoiceGeneration()
        let first = g.next()
        #expect(g.isCurrent(first))
        g.invalidate() // quick tap: armed, then cancelled
        #expect(!g.isCurrent(first))
        let second = g.next() // the next press
        #expect(g.isCurrent(second))
        #expect(!g.isCurrent(first))
    }

    @Test func cancellationIsNotAnError() {
        #expect(VoiceErrors.isCancellation(CancellationError()))
        #expect(VoiceErrors.isCancellation(URLError(.cancelled)))
        #expect(VoiceErrors.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(VoiceErrors.isCancellation(NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED))))
        #expect(!VoiceErrors.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!VoiceErrors.isCancellation(URLError(.timedOut)))
    }
}

@Suite("Voice guard")
struct VoiceGuardTests {
    @Test func halfSecondWithNothingHeardIsAMisTap() {
        // 9376 bytes at 16 kHz is 0.29 s: the clip behind the phantom message.
        #expect(VoiceGuard.isMisTap(pcmBytes: 9376, sampleRate: 16000, heardLive: false))
        #expect(!VoiceGuard.isMisTap(pcmBytes: VoiceGuard.minClipBytes(sampleRate: 16000), sampleRate: 16000, heardLive: false))
        #expect(!VoiceGuard.isMisTap(pcmBytes: 9376, sampleRate: 16000, heardLive: true))
    }

    @Test func onlyBatchWordsNobodyHeardLiveMustBeConfirmed() {
        #expect(VoiceGuard.mustConfirm(heardLive: false, fromBatch: true))
        // Realtime's own final after the release: a real utterance, it sends.
        #expect(!VoiceGuard.mustConfirm(heardLive: false, fromBatch: false))
        #expect(!VoiceGuard.mustConfirm(heardLive: true, fromBatch: true))
        #expect(!VoiceGuard.mustConfirm(heardLive: true, fromBatch: false))
    }

    @Test func shortPressDropsWhateverPathAnswered() {
        // Realtime's own final after the release, 0.7 s press: made up.
        #expect(VoiceGuard.dropsResult(heardLive: false, pressSeconds: 0.7))
        // A full second or more: sent (or confirmed, for batch words).
        #expect(!VoiceGuard.dropsResult(heardLive: false, pressSeconds: 1.0))
        #expect(!VoiceGuard.dropsResult(heardLive: false, pressSeconds: 3))
        // Words heard live on a short press still send.
        #expect(!VoiceGuard.dropsResult(heardLive: true, pressSeconds: 0.7))
    }

    @Test func aWholeCorpusLineIsAnEcho() {
        let corpus = "明天下午三点开会，别忘了带电脑。\n把报销单发给财务\nhello world"
        #expect(VoiceGuard.echoesCorpus("把报销单发给财务。", corpus: corpus))
        #expect(VoiceGuard.echoesCorpus("明天下午三点开会，别忘了带电脑", corpus: corpus))
        #expect(!VoiceGuard.echoesCorpus("把报销单发给财务吧", corpus: corpus))
        #expect(!VoiceGuard.echoesCorpus("好", corpus: "好"))
    }
}
