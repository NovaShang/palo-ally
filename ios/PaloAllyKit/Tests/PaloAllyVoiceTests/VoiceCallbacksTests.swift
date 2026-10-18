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

    @Test func wordsNobodyHeardLiveMustBeConfirmed() {
        #expect(VoiceGuard.mustConfirm(heardLive: false))
        #expect(!VoiceGuard.mustConfirm(heardLive: true))
    }

    @Test func aWholeCorpusLineIsAnEcho() {
        let corpus = "明天下午三点开会，别忘了带电脑。\n把报销单发给财务\nhello world"
        #expect(VoiceGuard.echoesCorpus("把报销单发给财务。", corpus: corpus))
        #expect(VoiceGuard.echoesCorpus("明天下午三点开会，别忘了带电脑", corpus: corpus))
        #expect(!VoiceGuard.echoesCorpus("把报销单发给财务吧", corpus: corpus))
        #expect(!VoiceGuard.echoesCorpus("好", corpus: "好"))
    }
}
