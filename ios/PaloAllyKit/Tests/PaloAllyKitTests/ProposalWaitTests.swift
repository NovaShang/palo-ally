import Foundation
import Testing
@testable import PaloAllyKit

/// The orange 「等你点头」 clears when the card stops waiting, even for an
/// app that was away when it changed; a card that can't be answered never
/// counts; the line leads to the card.
@MainActor
@Suite("Proposal cards waiting on the owner")
struct ProposalWaitTests {
    private func helperCard(seq: Int64, id: String, status: HelperProposalStatus = .pending, updatedSeq: Int64? = nil) -> ChatMessage {
        var m = ChatMessage(seq: seq, id: "m\(seq)", role: .assistant, kind: .helper, text: "开一个会话「网站」？", channel: .system, ts: seq)
        m.proposal = HelperProposal(id: id, name: "网站", cwd: "/a", duty: "做网站", status: status)
        m.updatedSeq = updatedSeq
        return m
    }

    private func text(_ seq: Int64) -> ChatMessage {
        ChatMessage(seq: seq, id: "t\(seq)", role: .assistant, text: "好", ts: seq)
    }

    private func store() -> AppStore {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.applySync(SyncResult(seq: 3, messages: [text(1), helperCard(seq: 2, id: "hp1"), text(3)]), since: nil)
        return store
    }

    @Test func aCardThatChangedWhileAwayComesBackOnSync() {
        let store = store()
        #expect(store.pendingProposalCount == 1)
        // Expired while the app was away: the next sync gives it again (its place unchanged).
        store.applySync(SyncResult(seq: 5, messages: [helperCard(seq: 2, id: "hp1", status: .expired, updatedSeq: 4), text(5)]), since: 3)
        #expect(store.pendingProposalCount == 0)
        #expect(store.messages.map(\.id) == ["t1", "m2", "t3", "t5"])
        #expect(store.lastSeq == 5)
    }

    @Test func aChangeToACardNotInTheListIsNotSplicedIn() {
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.applySync(SyncResult(seq: 3, messages: [text(3)]), since: nil)
        store.applySync(SyncResult(seq: 4, messages: [helperCard(seq: 2, id: "hp1", status: .expired, updatedSeq: 4)]), since: 3)
        #expect(store.messages.map(\.id) == ["t3"])
        #expect(store.lastSeq == 4)
        // Live too, and the count carries on from the change's seq.
        store.receive(helperCard(seq: 1, id: "hp0", status: .expired, updatedSeq: 5))
        #expect(store.messages.map(\.id) == ["t3"])
        #expect(store.lastSeq == 5)
        store.receive(text(6))
        #expect(store.lastSeq == 6)
    }

    @Test func aLiveChangeReplacesTheCardInPlace() {
        let store = store()
        store.receive(helperCard(seq: 2, id: "hp1", status: .discarded, updatedSeq: 4))
        #expect(store.pendingProposalCount == 0)
        #expect(store.messages.map(\.id) == ["t1", "m2", "t3"])
        #expect(store.lastSeq == 4)
    }

    @Test func aCardThatCantBeAnsweredDoesntWait() throws {
        // No id to answer with, no folder: not on offer.
        let helper = try JSONDecoder().decode(ChatMessage.self, from: Data("""
        {"seq":1,"id":"m1","role":"assistant","kind":"helper","text":"x","channel":"system","ts":1,"proposal":{"name":"网站","cwd":"/a","duty":"d"}}
        """.utf8))
        #expect(helper.proposal?.status == .unknown)
        let noFolder = try JSONDecoder().decode(ChatMessage.self, from: Data("""
        {"seq":2,"id":"m2","role":"assistant","kind":"helper","text":"x","channel":"system","ts":2,"proposal":{"id":"hp2","name":"网站","duty":"d"}}
        """.utf8))
        #expect(noFolder.proposal?.status == .unknown)
        let adopt = try JSONDecoder().decode(ChatMessage.self, from: Data("""
        {"seq":3,"id":"m3","role":"assistant","kind":"pal_adopt","text":"x","channel":"system","ts":3,"proposal":{"id":"pa1","cwd":"/a","title":"t"}}
        """.utf8))
        #expect(adopt.adoption?.status == .unknown)
        let expired = try JSONDecoder().decode(ChatMessage.self, from: Data("""
        {"seq":4,"id":"m4","role":"assistant","kind":"pal_adopt","text":"x","channel":"system","ts":4,"proposal":{"id":"pa2","sessionId":"s","cwd":"/a","title":"t","status":"expired"}}
        """.utf8))
        #expect(expired.adoption?.status == .expired)
        let store = AppStore(transport: InMemoryTransport(autoConnect: false))
        store.applySync(SyncResult(seq: 4, messages: [helper, noFolder, adopt, expired]), since: nil)
        #expect(store.pendingProposalCount == 0)
        #expect(store.firstWaiting == nil)
        // A whole one still counts.
        let whole = try JSONDecoder().decode(ChatMessage.self, from: Data("""
        {"seq":5,"id":"m5","role":"assistant","kind":"pal_adopt","text":"x","channel":"system","ts":5,"proposal":{"id":"pa3","sessionId":"s","cwd":"/a","title":"t"}}
        """.utf8))
        store.receive(whole)
        #expect(store.pendingProposalCount == 1)
    }

    @Test func theLineLeadsToTheOldestWaitingCard() {
        let store = store()
        store.receive(helperCard(seq: 4, id: "hp2"))
        #expect(store.firstWaiting == .message(seq: 2))
        store.receive(helperCard(seq: 2, id: "hp1", status: .created, updatedSeq: 5))
        #expect(store.firstWaiting == .message(seq: 4))
    }
}
