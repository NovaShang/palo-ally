import CryptoKit
import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Multiple hosts")
struct MultiHostTests {
    func host(_ id: String, label: String = "Mac") -> PairedHost {
        PairedHost(relay: URL(string: "https://relay.test")!, daemonID: id, deviceID: "dev-\(id)",
                   hostKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                   hostLabel: label, hostFingerprint: "fp-\(id)")
    }

    @Test func migratesTheSinglePairedHostIntoTheList() throws {
        let secrets = InMemorySecretStore()
        let old = host("d-old", label: "家里 Mac")
        try old.save(to: secrets)

        let list = PairedHostList.load(from: secrets)
        #expect(list == [old])
        // Migrated once: the list is stored, the old item is gone.
        #expect(PairedHost.load(from: secrets) == nil)
        #expect(PairedHostList.load(from: secrets) == [old])
    }

    @Test func emptyListDoesNotRemigrate() throws {
        let secrets = InMemorySecretStore()
        try PairedHostList.save([], to: secrets)
        try host("d-stale").save(to: secrets) // a stray old item must not come back
        #expect(PairedHostList.load(from: secrets).isEmpty)
    }

    @Test func upsertAppendsNewAndReplacesSameComputerInPlace() {
        let a = host("a"), b = host("b")
        var list = PairedHostList.upsert(a, into: [])
        list = PairedHostList.upsert(b, into: list)
        #expect(list.map(\.id) == ["a", "b"])
        let a2 = host("a", label: "改过名的 Mac")
        list = PairedHostList.upsert(a2, into: list)
        #expect(list.map(\.id) == ["a", "b"])
        #expect(list[0].hostLabel == "改过名的 Mac")
    }

    @Test func unreadCountsOnlyWhatTheOwnerHasNotSeen() {
        let msgs = [
            ChatMessage(seq: 1, id: "1", role: .user, text: "hi", ts: 1),
            ChatMessage(seq: 2, id: "2", role: .assistant, text: "好", ts: 2),
            ChatMessage(seq: 3, id: "3", role: .user, text: "再问", ts: 3),
            ChatMessage(seq: 4, id: "4", role: .assistant, text: "答", ts: 4),
            ChatMessage(seq: 5, id: "5", role: .system, kind: .notice, text: "提醒", ts: 5),
            ChatMessage(seq: 0, id: "s", role: .assistant, text: "streaming", ts: 6), // not stored yet
        ]
        #expect(AppStore.unreadCount(msgs, after: 0) == 3)
        #expect(AppStore.unreadCount(msgs, after: 2) == 2)
        #expect(AppStore.unreadCount(msgs, after: 5) == 0)
    }

    @Test @MainActor func syncReportsLastSeqForBaselining() async throws {
        let demo = DemoHost(speed: 0, hostName: "云端")
        let store = AppStore(transport: demo.transport)
        var synced: [Int64] = []
        store.onSynced = { synced.append($0) }
        store.start()
        for _ in 0..<200 where synced.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(synced.first == store.lastSeq)
        #expect(store.hostName == "云端")
        store.shutdown()
    }
}
