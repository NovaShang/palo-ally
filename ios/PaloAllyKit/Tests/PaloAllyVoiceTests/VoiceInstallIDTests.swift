import Foundation
import Testing
@testable import PaloAllyVoice

@Suite("Voice install id")
struct VoiceInstallIDTests {
    @Test func mintsAndSavesWhenNothingStored() {
        var saved: String?
        let id = VoiceInstallID.resolve(load: { nil }, save: { saved = $0 })
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())
        #expect(saved == id)
    }

    @Test func reusesAStoredId() {
        var saved = false
        let stored = "6F1C2B3A-1111-4222-8333-444455556666"
        let id = VoiceInstallID.resolve(load: { stored }, save: { _ in saved = true })
        #expect(id == stored.lowercased())
        #expect(!saved)
    }

    @Test func replacesAGarbledStoredValue() {
        var saved: String?
        let id = VoiceInstallID.resolve(load: { "not-a-uuid" }, save: { saved = $0 })
        #expect(UUID(uuidString: id) != nil)
        #expect(saved == id)
    }
}
