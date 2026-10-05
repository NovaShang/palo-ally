import Foundation
import Testing
@testable import PaloAllyKit

@MainActor
@Suite("Chat search")
struct ChatSearchTests {
    @Test func searchFindsNewestFirstAndRevealsLoadedMessage() async throws {
        let host = DemoHost(speed: 0, seeded: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let any = try #require(store.messages.first(where: { $0.seq > 0 && $0.text.count >= 2 }))
        let needle = String(any.text.prefix(2))
        let hits = try await store.searchConversation(needle)
        #expect(!hits.isEmpty)
        #expect(hits.map(\.seq) == hits.map(\.seq).sorted(by: >))
        #expect(hits.allSatisfy { $0.snippet.lowercased().contains(needle.lowercased()) })
        #expect(try await store.searchConversation("   ").isEmpty)
        // Already loaded: no jump into the past.
        let id = await store.revealMessage(seq: hits[0].seq)
        #expect(id == store.messages.first(where: { $0.seq == hits[0].seq })?.id)
        #expect(store.viewingPast == false)
    }

    @Test func farBackJumpShowsAWindowThenReturnsToLatest() async throws {
        let host = DemoHost(speed: 0, seeded: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let latest = store.lastSeq
        // Force the "far back" path for an unloaded seq by asking with no gap allowance.
        let id = await store.revealMessage(seq: 1, maxGap: 0)
        #expect(id != nil)
        await store.returnToLatest()
        #expect(store.viewingPast == false)
        #expect(store.messages.last(where: { $0.seq > 0 })?.seq == latest)
    }
}
