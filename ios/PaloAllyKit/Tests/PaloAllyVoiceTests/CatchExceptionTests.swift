import Foundation
import PaloAllyObjC
import Testing

@Suite("Catching Objective-C exceptions")
struct CatchExceptionTests {
    @Test func returnsTheRaisedException() {
        let caught = PAOCatchException {
            NSException(name: .internalInconsistencyException, reason: "format mismatch", userInfo: nil).raise()
        }
        #expect(caught?.name == .internalInconsistencyException)
        #expect(caught?.reason == "format mismatch")
    }

    @Test func nilWhenNothingRaises() {
        var ran = false
        #expect(PAOCatchException { ran = true } == nil)
        #expect(ran)
    }
}
