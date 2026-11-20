import Foundation
import Testing
@testable import PaloAllyKit

/// 等你的事 on the client: the list from sync and events, its order, what it
/// adds to the waiting counts, answers, 聊这件 and the owner's hand on it.
@MainActor
@Suite("Pending items")
struct PendingTests {
    func demo(pals: Bool = true) async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, pals: pals)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && !store.pendingItems.isEmpty }
        return (store, host)
    }

    @Test func theListComesWithSyncBlockingFirst() async throws {
        let (store, _) = await demo()
        let open = store.openPending
        #expect(open.count >= 4)
        // every blocking one ahead of the rest
        let firstLoose = open.firstIndex { !$0.blocking } ?? open.count
        #expect(open[firstLoose...].allSatisfy { !$0.blocking })
        #expect(open.contains { $0.source.kind == .session && $0.blocking && $0.questionId == "sq1" })
        #expect(open.contains { $0.id == "p_meeting" && $0.options == ["改到周五", "维持周四"] })
        #expect(open.contains { $0.id == "p_flight" && $0.options == nil && $0.source.kind == .brief && $0.messageId != nil })
        #expect(store.pendingHandledToday.map(\.id) == ["p_hotel"])
        // The proposal card waiting in the conversation is an item too (a link to it).
        #expect(open.contains { $0.link?.kind == .proposal && $0.options == ["开吧", "不用"] })
    }

    @Test func answeringTheAssistantsItemIsTheOwnersMessageAndTheItemIsDecided() async throws {
        let (store, _) = await demo()
        let item = try #require(store.pendingItem(id: "p_meeting"))
        try await store.answerPending(item, "改到周五")
        #expect(store.pendingItem(id: "p_meeting")?.status == .done)
        #expect(await until { store.messages.contains { $0.role == .user && $0.pendingId == "p_meeting" && $0.text == "改到周五" } })
        #expect(await until { store.messages.last?.text.contains("还剩") == true })
    }

    @Test func answeringABlockingQuestionAnswersTheQuestion() async throws {
        let (store, _) = await demo()
        let item = try #require(store.openPending.first { $0.questionId == "sq1" })
        try await store.answerPending(item, "B 用中位数补上")
        #expect(await until { store.question(id: "sq1")?.status == .answered })
        #expect(await until { store.pendingItem(id: item.id)?.status == .done })
    }

    @Test func surfacingPutsItsCardAtTheBottomAndHidesTheCapsule() async throws {
        let (store, _) = await demo()
        let item = try #require(store.pendingItem(id: "p_flight"))
        #expect(store.discussingPending == nil)
        try await store.surfacePending(item)
        #expect(await until { store.messages.contains { $0.kind == .pending && $0.pendingId == "p_flight" } })
        #expect(store.discussingPending?.id == "p_flight")
        try await store.updatePending(item, action: "ignore")
        #expect(store.pendingItem(id: "p_flight")?.status == .ignored)
        #expect(store.discussingPending == nil)
        try await store.updatePending(try #require(store.pendingItem(id: "p_flight")), action: "reopen")
        #expect(await until { store.pendingItem(id: "p_flight")?.isOpen == true })
    }

    @Test func aProposalsItemAndItsCardMoveTogetherBothWays() async throws {
        let (store, _) = await demo()
        let item = try #require(store.openPending.first { $0.link?.kind == .proposal })
        let id = try #require(item.link?.id)
        // 不用 on the list: the card says so
        try await store.answerPending(item, "不用")
        #expect(await until { store.messages.contains { $0.proposal?.id == id && $0.proposal?.status == .discarded } })
        #expect(store.pendingItem(id: item.id)?.status == .done)
        #expect(!store.openPending.contains { $0.link?.kind == .proposal })
    }

    @Test func aTaskThatNeedsTheOwnerIsAnItemUntilItGoesOn() async throws {
        let (store, host) = await demo()
        let before = store.openPending.count
        let now = Date().epochMillis
        await host.upsertTask(AllyTask(id: "t-need", title: "订餐厅", summary: "几个人？", status: .needsInput, createdAt: now, updatedAt: now))
        #expect(await until { store.openPending.count == before + 1 })
        #expect(store.openPending.contains { $0.link == PendingLink(kind: .task, id: "t-need") && $0.title == "「订餐厅」需要你" })
        await host.upsertTask(AllyTask(id: "t-need", title: "订餐厅", summary: "订好了", status: .done, createdAt: now, updatedAt: now + 1))
        #expect(await until { store.openPending.count == before })
    }
}
