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

    // MARK: one way to decide, for a card and a row

    @Test func aCardsOptionsPutTheYesLastAndPlainOnesStayAnswers() {
        let src = PendingSource(kind: .palo, name: "Palo")
        let approval = PendingItem(id: "1", source: src, title: "运行", options: ["允许", "拒绝"], createdAt: 0, blocking: true, approvalId: "a1")
        #expect(approval.subject == .approval("a1") && !approval.takesWords)
        #expect(approval.choices == [PendingChoiceButton(title: "拒绝", choice: .deny), PendingChoiceButton(title: "允许", choice: .allow(remember: false), primary: true)])
        let proposal = PendingItem(id: "2", source: src, title: "开吧？", options: ["开吧", "不用"], createdAt: 0, link: PendingLink(kind: .proposal, id: "hp"))
        #expect(proposal.subject == .proposal("hp") && proposal.choices.map(\.choice) == [.decline, .accept] && proposal.choices.last?.primary == true)
        let draft = PendingItem(id: "3", source: src, title: "发吗", options: ["发送", "不发"], createdAt: 0, link: PendingLink(kind: .allyDraft, id: "e1"))
        #expect(draft.subject == .allyDraft("e1") && draft.choices.map(\.title) == ["不发", "发送"])
        let plain = PendingItem(id: "4", source: src, title: "改不改", options: ["改到周五", "维持周四", " "], createdAt: 0)
        #expect(plain.subject == .item("4") && plain.choices.map(\.choice) == [.option("改到周五"), .option("维持周四")] && plain.choices.allSatisfy { !$0.primary })
        #expect(PendingItem(id: "5", source: src, title: "q", createdAt: 0, questionId: "q1").subject == .question("q1"))
        #expect(PendingItem(id: "6", source: src, title: "t", createdAt: 0, link: PendingLink(kind: .task, id: "t1")).subject == .task("t1"))
        // The words a card's choice has on the list (the host maps them back).
        #expect(AppStore.words(of: .allow(remember: true), item: approval) == "允许" && AppStore.words(of: .decline, item: proposal) == "不用")
        #expect(AppStore.words(of: .sendEdited("x"), item: draft) == nil)
    }

    @Test func aPromptDecidedOnItsRowOrOnItsCardGoesTheSameWay() async throws {
        let (store, _) = await demo()
        // The row: its buttons.
        let row = try #require(store.openPending.first { $0.approvalId == "a2" })
        let allow = try #require(row.choices.first { $0.primary })
        try await store.decide(row, allow.choice)
        #expect(store.pendingItem(id: row.id)?.status == .done && !store.openPending.contains { $0.id == row.id })
        #expect(store.approval(id: "a2")?.status == .allowed)
        // The card: its own buttons, by what it stands for.
        let card = try #require(store.pendingItem(for: .approval("a1")))
        #expect(card.isOpen)
        try await store.decide(.approval("a1"), .deny)
        #expect(store.approval(id: "a1")?.status == .denied && store.pendingItem(id: card.id)?.status == .done)
        #expect(await until { store.pendingItem(id: card.id)?.conclusion == "拒绝了" })
    }

    @Test func aQuestionsCardAnswersAllItsQuestionsAndClosesItsItem() async throws {
        let (store, _) = await demo()
        let item = try #require(store.pendingItem(for: .question("q1")))
        try await store.decide(.question("q1"), .answers(["周五晚上几个人？": "四个人", "想吃什么？": "日料, 粤菜"]))
        #expect(store.question(id: "q1")?.status == .answered && store.question(id: "q1")?.answers?["想吃什么？"] == "日料, 粤菜")
        #expect(store.pendingItem(id: item.id)?.status == .done)
        // A one-question card answered on its row: the option is its answer.
        let row = try #require(store.pendingItem(for: .question("sq1")))
        try await store.decide(row, .option("A 直接删掉"))
        #expect(await until { store.question(id: "sq1")?.answers?["没填收入的 37 份问卷怎么处理？"] == "A 直接删掉" })
    }

    @Test func aDraftGoesWithTheOwnersChangedWordsAndAProposalFromItsRow() async throws {
        let (store, host) = await demo()
        await host.makeDraft(to: "al-family", text: "今晚七点到")
        let draft = try #require(await until { store.openPending.contains { $0.link?.kind == .allyDraft } } ? store.openPending.first { $0.link?.kind == .allyDraft } : nil)
        try await store.decide(draft.subject, .sendEdited("今晚七点半到，路上买菜"))
        #expect(await until { store.allyEntry(id: draft.link!.id)?.text == "今晚七点半到，路上买菜" })
        #expect(await until { store.pendingItem(id: draft.id)?.status == .done })
        let proposal = try #require(store.openPending.first { $0.link?.kind == .proposal })
        try await store.decide(proposal, .decline)
        #expect(await until { store.messages.contains { $0.proposal?.id == proposal.link?.id && $0.proposal?.status == .discarded } })
        #expect(store.pendingItem(id: proposal.id)?.status == .done)
    }

    @Test func aDecisionTheHostRefusesPutsTheItemBack() async throws {
        let (store, _) = await demo()
        let item = try #require(store.pendingItem(id: "p_meeting"))
        await #expect(throws: (any Error).self) { try await store.decide(item, .option("   ")) }
        #expect(store.pendingItem(id: "p_meeting")?.isOpen == true)
        // Nothing to answer at all: said so, nothing changes.
        await #expect(throws: PendingDecideError.nothingToAnswer) { try await store.decide(.approval("none"), .allow(remember: false)) }
        // 忽略 and 放回 go the same way.
        try await store.decide(item, .ignore)
        #expect(store.pendingItem(id: "p_meeting")?.status == .ignored)
        try await store.decide(item.subject, .reopen)
        #expect(await until { store.pendingItem(id: "p_meeting")?.isOpen == true })
    }

    @Test func theSidebarsCountsAreTheLists() async throws {
        let (store, _) = await demo()
        #expect(await until { store.pals.count == 4 })
        let tree = store.sidebarTree
        // Agents with items: the Pals and the computer's other sessions alike.
        let withItems = store.pals.filter { store.palPendingCount($0.id) > 0 }.count
            + store.otherSessions.filter { store.palPendingCount($0.id) > 0 }.count
        #expect(tree.waitingCount == withItems && withItems >= 1)
        for node in tree.workspaces {
            #expect(node.waiting == node.members.reduce(0) { $0 + store.palPendingCount($1.id) })
        }
    }
}
