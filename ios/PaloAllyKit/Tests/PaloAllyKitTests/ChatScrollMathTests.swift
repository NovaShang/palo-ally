import CoreGraphics
import Testing
@testable import PaloAllyKit

/// Numbers logged from the simulator (demo chat, iPhone 17 Pro).
@Suite struct ChatScrollMathTests {
    @Test func restingAtTheBottomIsNearZero() {
        // off=-39 size=1389 cont=662 inT=753(stale) inB=96 visibleRect=-39..1472
        let d = ChatScrollMath.distanceFromBottom(contentHeight: 1389, visibleMaxY: 1472, bottomInset: 96)
        #expect(d < 20) // only the list's own bottom padding
    }

    @Test func scrolledToTheTopIsFarFromTheBottom() {
        // off=-104 size=1234 cont=662 inT=116 inB=96 visibleRect=-104..770
        let d = ChatScrollMath.distanceFromBottom(contentHeight: 1234, visibleMaxY: 770, bottomInset: 96)
        #expect(d == 560)
    }

    @Test func overscrollPastTheEndClampsToZero() {
        #expect(ChatScrollMath.distanceFromBottom(contentHeight: 500, visibleMaxY: 700, bottomInset: 96) == 0)
    }
}
