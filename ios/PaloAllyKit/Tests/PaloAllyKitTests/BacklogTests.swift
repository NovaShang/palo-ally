import Foundation
import Testing
@testable import PaloAllyKit

/// 待办 on the client: a folder's list from the host, the owner's hand on it
/// (shown at once), the event from another device, 下一件 and 以后再说.
@MainActor
@Suite("Backlog", .serialized)
struct BacklogTests {
    func demo() async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.pals.count == 4 && !store.pendingItems.isEmpty }
        return (store, host)
    }

    @Test func theAssistantsAndAnAgentsListsAreTheirFolders() async throws {
        let (store, _) = await demo()
        await store.loadBacklog(forPal: nil)
        await store.loadBacklog(forPal: "pal-site")
        #expect(store.backlogSupported == true)
        let mine = try #require(store.backlog(forPal: nil))
        #expect(mine.assistant == true && mine.queued.map(\.text).first == "整理十月的报销单")
        let site = try #require(store.backlog(forPal: "pal-site"))
        #expect(site.folder == "/Users/demo/code/site" && site.queued.count == 7 && site.done.count == 2)
        // the latest done first
        #expect(site.done.first?.id == "b_sort")
        #expect(store.backlogAgents(forPal: "pal-site").map(\.id) == ["pal-site"])
    }

    @Test func movingShowsAtOnceAndTheHostAgrees() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        let site = try #require(store.backlog(forPal: "pal-site"))
        let last = try #require(site.queued.last)
        try await store.moveBacklog(last, to: 0, forPal: "pal-site")
        #expect(store.backlog(forPal: "pal-site")?.queued.first?.id == last.id)
        let kept = await host.backlogs["/Users/demo/code/site"]
        #expect(kept?.queued.first?.id == last.id && kept?.queued.count == 7)
        // a done one dragged into the queue is in line again
        let done = try #require(store.backlog(forPal: "pal-site")?.done.first)
        try await store.moveBacklog(done, to: 1, forPal: "pal-site")
        #expect(store.backlog(forPal: "pal-site")?.queued[1].id == done.id && store.backlog(forPal: "pal-site")?.queued[1].state == .queued)
    }

    @Test func addAssignDoneRemove() async throws {
        let (store, _) = await demo()
        await store.loadBacklog(forPal: nil)
        try await store.addBacklog("  给车续保险 ", forPal: nil)
        let mine = try #require(store.backlog(forPal: nil))
        let added = try #require(mine.queued.last)
        #expect(added.text == "给车续保险")
        try await store.assignBacklog(added, to: "pal-notes", forPal: nil)
        #expect(store.backlog(forPal: nil)?.items.first { $0.id == added.id }?.palName == "笔记整理")
        try await store.doneBacklog(added, forPal: nil)
        #expect(store.backlog(forPal: nil)?.done.first?.id == added.id)
        try await store.doneBacklog(added, done: false, forPal: nil)
        #expect(store.backlog(forPal: nil)?.queued.first?.id == added.id)
        try await store.removeBacklog(added, forPal: nil)
        #expect(store.backlog(forPal: nil)?.items.contains { $0.id == added.id } == false)
    }

    @Test func anotherDevicesChangeArrivesAsTheWholeList() async throws {
        let (store, _) = await demo()
        await store.loadBacklog(forPal: "pal-notes")
        let b = Backlog(folder: "/Users/demo/Documents/notes", name: "notes", items: [BacklogItem(id: "b_x", text: "别处加的")])
        store.apply(event: RPCEventName.backlogUpdated, data: try .from(b))
        #expect(store.backlog(forPal: "pal-notes")?.items.map(\.text) == ["别处加的"])
    }

    @Test func nextIsOfferedToAnAgentThatFinishedWithNothingWaiting() async throws {
        let (store, _) = await demo()
        UserDefaults.standard.removeObject(forKey: AppStore.dismissKey("pal-notes"))
        await store.loadBacklog(forPal: "pal-notes")
        await store.loadBacklog(forPal: "pal-site")
        // 笔记整理 finished a turn, nothing of it waits: its first item
        #expect(store.nextBacklog(forPal: "pal-notes")?.id == "b_tags")
        // 换一件: the next, round again after the last
        store.skipNextBacklog(forPal: "pal-notes")
        #expect(store.nextBacklog(forPal: "pal-notes")?.id == "b_dupes")
        store.skipNextBacklog(forPal: "pal-notes")
        store.skipNextBacklog(forPal: "pal-notes")
        #expect(store.nextBacklog(forPal: "pal-notes")?.id == "b_tags")
        // 网站帮手 waits on the owner: nothing offered
        #expect(store.nextBacklog(forPal: "pal-site") == nil)
        // 开始: quoted to the agent as the owner's words, and being done by it (no more offer)
        let item = try #require(store.nextBacklog(forPal: "pal-notes"))
        store.startBacklog(item, by: "pal-notes", words: "开始做这件")
        let page = store.palStore("pal-notes")
        #expect(page.messages.last?.replyTo == ReplyTo(messageId: "backlog:b_tags", excerpt: "把去年的读书笔记也补上标签"))
        #expect(await until { store.backlog(forPal: "pal-notes")?.doing.first?.id == "b_tags" })
        #expect(store.backlog(forPal: "pal-notes")?.doing.first?.pal == "pal-notes")
        #expect(store.nextBacklog(forPal: "pal-notes") == nil)
    }

    @Test func puttingTheOfferAwayKeepsItAwayToday() async throws {
        let (store, _) = await demo()
        UserDefaults.standard.removeObject(forKey: AppStore.dismissKey("pal-notes"))
        await store.loadBacklog(forPal: "pal-notes")
        #expect(store.nextBacklog(forPal: "pal-notes") != nil)
        store.dismissNextBacklog(forPal: "pal-notes")
        #expect(store.nextBacklog(forPal: "pal-notes") == nil)
        #expect(UserDefaults.standard.string(forKey: AppStore.dismissKey("pal-notes")) == AppStore.dayKey(Date()))
        UserDefaults.standard.removeObject(forKey: AppStore.dismissKey("pal-notes"))
    }

    @Test func laterMovesAnItemIntoItsFoldersBacklog() async throws {
        let (store, host) = await demo()
        let item = try #require(store.pendingItem(id: "p_meeting"))
        #expect(AppStore.canPutOff(item))
        // 以后再说 decides as the row's other buttons do.
        try await store.decide(item, .later)
        #expect(store.pendingItem(id: "p_meeting")?.status == .done)
        #expect(AppStore.conclusion(of: .later, item: item) == "放进待办了")
        let mine = await host.backlogs[DemoHost.demoAssistantFolder]
        #expect(mine?.queued.last?.text == "周四和王老师的会改不改时间")
        // a blocking one isn't offered
        let blocking = try #require(store.openPending.first { $0.blocking })
        #expect(!AppStore.canPutOff(blocking))
    }

    @Test func movingIsPure() {
        let b = Backlog(folder: "/f", name: "f", items: [
            BacklogItem(id: "d", text: "d", state: .doing, pal: "p"),
            BacklogItem(id: "a", text: "a"), BacklogItem(id: "b", text: "b"), BacklogItem(id: "c", text: "c"),
            BacklogItem(id: "x", text: "x", state: .done),
        ])
        #expect(b.moving("c", to: 0).items.map(\.id) == ["d", "c", "a", "b", "x"])
        #expect(b.moving("a", to: 9).items.map(\.id) == ["d", "b", "c", "a", "x"])
        #expect(b.moving("x", to: 1).items.map(\.id) == ["d", "a", "x", "b", "c"])
        #expect(b.moving("d", to: 0).items.first?.pal == nil)
        #expect(b.next(for: "q")?.id == "a")
    }
}
