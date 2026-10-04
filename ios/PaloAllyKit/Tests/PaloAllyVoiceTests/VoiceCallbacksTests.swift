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
