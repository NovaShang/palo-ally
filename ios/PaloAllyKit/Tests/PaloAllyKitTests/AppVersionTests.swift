import Testing
@testable import PaloAllyKit

struct AppVersionTests {
    @Test func parsesPlainVersionsOnly() {
        #expect(AppVersion.parse("0.1.9") == [0, 1, 9])
        #expect(AppVersion.parse("v1.20.3") == [1, 20, 3])
        for odd in ["", "0.1", "0.1.9+4", "0.1.9-dev", "0.1.0-demo", "1.2.3.4", "a.b.c", "1..3", "0.1.-1"] {
            #expect(AppVersion.parse(odd) == nil, "\(odd)")
        }
    }

    @Test func comparesNumerically() {
        #expect(AppVersion.isNewer("0.1.10", than: "0.1.9"))
        #expect(AppVersion.isNewer("0.2.0", than: "0.1.99"))
        #expect(AppVersion.isNewer("1.0.0", than: "0.9.9"))
        #expect(!AppVersion.isNewer("0.1.9", than: "0.1.9"))
        #expect(!AppVersion.isNewer("0.1.8", than: "0.1.9"))
        #expect(!AppVersion.isNewer("0.1.9+4", than: "0.1.8"))
        #expect(!AppVersion.isNewer("0.1.9", than: "dev"))
    }

    @Test func hintOnlyWhenBehindAndNotDismissed() {
        #expect(AppVersion.updateHint(app: "0.1.8", host: "0.1.9") == "0.1.9")
        #expect(AppVersion.updateHint(app: "0.1.8", host: "v0.1.9") == "0.1.9")
        #expect(AppVersion.updateHint(app: "0.1.9", host: "0.1.9") == nil)
        #expect(AppVersion.updateHint(app: "0.1.9", host: "0.1.8") == nil)
        #expect(AppVersion.updateHint(app: "0.1.8", host: "0.1.9+3") == nil)
        #expect(AppVersion.updateHint(app: "0.1.8", host: "") == nil)
        // Closed for 0.1.9: stays closed, comes back for 0.1.10.
        #expect(AppVersion.updateHint(app: "0.1.8", host: "0.1.9", dismissed: "0.1.9") == nil)
        #expect(AppVersion.updateHint(app: "0.1.8", host: "0.1.10", dismissed: "0.1.9") == "0.1.10")
        #expect(AppVersion.updateHint(app: "0.1.8", host: "0.1.9", dismissed: "garbage") == "0.1.9")
    }
}
