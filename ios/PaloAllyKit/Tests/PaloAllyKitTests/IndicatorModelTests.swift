import Testing
@testable import PaloAllyKit

@Suite("Session indicator rules")
struct IndicatorModelTests {
    @Test func modelIdsMapToTheirClass() {
        #expect(IndicatorModelClass(modelId: "claude-opus-5-5") == .opus)
        #expect(IndicatorModelClass(modelId: "claude-sonnet-4-5") == .sonnet)
        #expect(IndicatorModelClass(modelId: "Haiku 4.5") == .haiku)
        #expect(IndicatorModelClass(modelId: "claude-fable-1") == .fable)
        #expect(IndicatorModelClass(modelId: "opus[1m]") == .opus)
        #expect(IndicatorModelClass(modelId: "default") == .other)
        #expect(IndicatorModelClass(modelId: nil) == .other)
        #expect(IndicatorModelClass(modelId: "") == .other)
    }

    @Test func classColorsAreTheDesignedOnes() {
        #expect(IndicatorModelClass.haiku.rgb == 0x8FD5E8)
        #expect(IndicatorModelClass.sonnet.rgb == 0xA6B6F7)
        #expect(IndicatorModelClass.opus.rgb == 0xD6A6EE)
        #expect(IndicatorModelClass.fable.rgb == 0xF4A7A0)
        #expect(IndicatorModelClass.other.rgb == 0xC7C7CC)
        #expect(IndicatorModelClass.haiku.lightRGB == 0x2A97B5)
        #expect(IndicatorModelClass.sonnet.lightRGB == 0x5468D9)
        #expect(IndicatorModelClass.opus.lightRGB == 0x9A55C4)
        #expect(IndicatorModelClass.fable.lightRGB == 0xD45F57)
        #expect(IndicatorModelClass.other.lightRGB == 0x8E8E93)
    }

    @Test func arcWarnsFrom80AndAlarmsFrom95() {
        #expect(IndicatorRules.arcTone(fraction: 0.79) == .normal)
        #expect(IndicatorRules.arcTone(fraction: 0.80) == .warn)
        #expect(IndicatorRules.arcTone(fraction: 0.94) == .warn)
        #expect(IndicatorRules.arcTone(fraction: 0.95) == .danger)
    }

    @Test func fractionClamps() {
        #expect(IndicatorRules.fraction(pct: nil) == 0)
        #expect(IndicatorRules.fraction(pct: 41) == 0.41)
        #expect(IndicatorRules.fraction(pct: 140) == 1)
        #expect(IndicatorRules.fraction(pct: -5) == 0)
    }

    @Test func effortLabels() {
        #expect(IndicatorRules.effortLabel("low") == "low")
        #expect(IndicatorRules.effortLabel("medium") == "med")
        #expect(IndicatorRules.effortLabel("high") == "hi")
        #expect(IndicatorRules.effortLabel("xhigh") == "xhi")
        #expect(IndicatorRules.effortLabel("max") == "max")
        #expect(IndicatorRules.effortLabel(nil) == nil)
        #expect(IndicatorRules.effortLabel("???") == nil)
    }

    @Test func theRingNeedsRoom() {
        #expect(!IndicatorRules.showsRing(size: 25.9))
        #expect(IndicatorRules.showsRing(size: 26))
    }
}
