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
        store.startBacklog(item, by: "pal-notes", forPal: "pal-notes", words: "开始做这件")
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

    /// The item with this id on 网站帮手's list now.
    private func site(_ store: AppStore, _ id: String) -> BacklogItem? {
        store.backlog(forPal: "pal-site")?.items.first { $0.id == id }
    }

    @Test func wordsChangeInPlaceAndReachTheHost() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        #expect(store.backlog(forPal: "pal-site")?.editable == true)
        store.editBacklog(id: "b_lazy", text: " 首页图片都懒加载 ", forPal: "pal-site")
        // at once; the note as it was
        #expect(site(store, "b_lazy")?.text == "首页图片都懒加载" && site(store, "b_lazy")?.note == "首屏 3.2 MB，大部分是图")
        store.editBacklog(id: "b_lazy", note: "只管首屏", forPal: "pal-site")
        #expect(await until { store.shared.backlogEdits.isEmpty })
        var kept = await host.backlogs["/Users/demo/code/site"]?.items.first { $0.id == "b_lazy" }
        #expect(kept?.text == "首页图片都懒加载" && kept?.note == "只管首屏")
        // an empty note takes it away; empty words change nothing
        store.editBacklog(id: "b_lazy", note: " ", forPal: "pal-site")
        store.editBacklog(id: "b_lazy", text: "  ", forPal: "pal-site")
        #expect(await until { store.shared.backlogEdits.isEmpty })
        kept = await host.backlogs["/Users/demo/code/site"]?.items.first { $0.id == "b_lazy" }
        #expect(kept?.note == nil && kept?.text == "首页图片都懒加载")
    }

    @Test func aListArrivingMeanwhileDoesntPutTheOldWordsBack() async throws {
        let (store, _) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        let old = try #require(store.backlog(forPal: "pal-site"))
        store.editBacklog(id: "b_toc", text: "文章页加一个目录", forPal: "pal-site")
        // another device's change, sent before the host had these words
        store.apply(event: RPCEventName.backlogUpdated, data: try .from(old))
        #expect(site(store, "b_toc")?.text == "文章页加一个目录")
        #expect(await until { store.shared.backlogEdits.isEmpty })
        #expect(site(store, "b_toc")?.text == "文章页加一个目录")
        // the host has them: from then on its list is the truth
        store.apply(event: RPCEventName.backlogUpdated, data: try .from(old))
        #expect(site(store, "b_toc")?.text == "文章页加目录")
    }

    @Test func wordsTypedWhileOfflineAreSentOnceItsReached() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        await host.transport.stop()
        #expect(await until { !store.connection.isOnline })
        store.editBacklog(id: "b_404", text: "404 页面重画", forPal: "pal-site")
        store.editBacklog(id: "b_404", note: "带搜索框", forPal: "pal-site")
        #expect(await until { store.shared.backlogEdits["b_404"]?.sending == false })
        #expect(site(store, "b_404")?.text == "404 页面重画")
        var kept = await host.backlogs["/Users/demo/code/site"]?.items.first { $0.id == "b_404" }
        #expect(kept?.text == "404 页面重做")
        await host.transport.start()
        #expect(await until { store.connection.isOnline && store.shared.backlogEdits.isEmpty })
        kept = await host.backlogs["/Users/demo/code/site"]?.items.first { $0.id == "b_404" }
        #expect(kept?.text == "404 页面重画" && kept?.note == "带搜索框")
    }

    @Test func wordsForAnItemThatsGoneAreDropped() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        _ = try await host.dispatchBacklog(RPCMethod.backlogRemove, ["pal": "pal-site", "id": "b_radius"])
        store.editBacklog(id: "b_radius", text: "圆角", forPal: "pal-site")
        #expect(await until { store.shared.backlogEdits.isEmpty && site(store, "b_radius") == nil })
    }

    @Test func undoingDoneAndRemovalPutsThemBackWhereTheyWere() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        try await store.assignBacklog(try #require(site(store, "b_404")), to: "pal-site", forPal: "pal-site")
        let was = try #require(store.backlog(forPal: "pal-site")).items
        for id in ["b_lazy", "b_404", "b_sitemap"] {
            let item = try #require(site(store, id))
            let place = try #require(store.backlog(forPal: "pal-site")?.place(of: id))
            try await store.doneBacklog(item, forPal: "pal-site")
            #expect(site(store, id)?.state == .done)
            try await store.undoDoneBacklog(item, place: place, forPal: "pal-site")
            #expect(store.backlog(forPal: "pal-site")?.items == was)
            try await store.removeBacklog(item, forPal: "pal-site")
            #expect(site(store, id) == nil)
            try await store.restoreBacklog(item, place: place, forPal: "pal-site")
            #expect(store.backlog(forPal: "pal-site")?.items == was)
            #expect(await host.backlogs["/Users/demo/code/site"]?.items == was)
        }
        // one being done: done, then back with its agent, nothing said to it
        let before = store.palStore("pal-site").messages.count
        try await store.undoDoneBacklog(BacklogItem(id: "b_404", text: "404 页面重做", state: .doing, pal: "pal-site", palName: "网站帮手"),
                                        place: 0, forPal: "pal-site")
        #expect(store.backlog(forPal: "pal-site")?.doing.map(\.pal) == ["pal-site"])
        #expect(store.palStore("pal-site").messages.count == before)
    }

    @Test func aHostFromBeforeEditingStillUndoes() async throws {
        let (store, host) = await demo()
        await host.applyScenario("backlogOld")
        await store.loadBacklog(forPal: "pal-site")
        #expect(store.backlog(forPal: "pal-site")?.editable == nil)
        try await store.assignBacklog(try #require(site(store, "b_toc")), to: "pal-site", forPal: "pal-site")
        let item = try #require(site(store, "b_toc"))
        try await store.removeBacklog(item, forPal: "pal-site")
        try await store.restoreBacklog(item, place: 1, forPal: "pal-site")
        let back = try #require(store.backlog(forPal: "pal-site")?.queued[1])
        #expect(back.text == item.text && back.note == item.note && back.pal == "pal-site" && store.backlog(forPal: "pal-site")?.queued.count == 7)
        let first = try #require(store.backlog(forPal: "pal-site")?.queued.first)
        try await store.doneBacklog(first, forPal: "pal-site")
        try await store.undoDoneBacklog(first, place: 0, forPal: "pal-site")
        #expect(store.backlog(forPal: "pal-site")?.queued.first?.id == first.id)
    }

    @Test func startingIsOnTheListItsFromWhoeverDoesIt() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: nil)
        await store.loadBacklog(forPal: "pal-notes")
        // The assistant's item, given to an agent of another folder.
        let item = try #require(store.backlog(forPal: nil)?.queued.first)
        store.startBacklog(item, by: "pal-notes", forPal: nil, words: "开始做这件")
        #expect(store.palStore("pal-notes").messages.last?.replyTo?.messageId == "backlog:\(item.id)")
        #expect(await until { store.backlog(forPal: nil)?.doing.first?.id == item.id })
        #expect(store.backlog(forPal: nil)?.doing.first?.palName == "笔记整理")
        #expect(await until { await host.backlogs[DemoHost.demoAssistantFolder]?.doing.first?.pal == "pal-notes" })
        // The agent's own list is its own still.
        #expect(store.backlog(forPal: "pal-notes")?.doing.isEmpty == true)
        // The assistant itself: no one's name.
        let next = try #require(store.backlog(forPal: nil)?.queued.first)
        store.markBacklogStarted(next, by: nil, forPal: nil)
        #expect(await until { await host.backlogs[DemoHost.demoAssistantFolder]?.doing.count == 2 })
        #expect(store.backlog(forPal: nil)?.doing.last?.pal == nil)
    }

    @Test func theDemosStates() async throws {
        let (store, host) = await demo()
        await store.loadBacklog(forPal: "pal-site")
        await host.applyScenario("backlogMany")
        #expect(await until { store.backlog(forPal: "pal-site")?.queued.count == 30 })
        #expect(store.backlog(forPal: "pal-site")?.doing.first?.palName == "网站帮手")
        #expect(await until { store.backlogAgents(forPal: "pal-site").map(\.id).sorted() == ["pal-blog", "pal-site"] })
        await host.applyScenario("backlogEmpty")
        #expect(await until { store.backlog(forPal: "pal-site")?.items.isEmpty == true })
    }

    @Test func restoringIsPure() {
        let b = Backlog(folder: "/f", name: "f", items: [
            BacklogItem(id: "d", text: "d", state: .doing), BacklogItem(id: "a", text: "a"), BacklogItem(id: "x", text: "x", state: .done),
        ])
        #expect(b.restoring(BacklogItem(id: "b", text: "b"), to: 0).items.map(\.id) == ["d", "b", "a", "x"])
        #expect(b.restoring(BacklogItem(id: "b", text: "b"), to: 9).items.map(\.id) == ["d", "a", "b", "x"])
        #expect(b.restoring(BacklogItem(id: "y", text: "y", state: .done), to: 1).items.map(\.id) == ["d", "a", "x", "y"])
        #expect(b.restoring(BacklogItem(id: "e", text: "e", state: .doing), to: 0).items.map(\.id) == ["e", "d", "a", "x"])
        #expect(b.restoring(b.items[1], to: 0) == b)
        #expect(Backlog(folder: "/f", name: "f", items: [b.items[2]]).restoring(b.items[1], to: 0).items.map(\.id) == ["a", "x"])
        #expect(b.starting("a", by: "p", name: "P").items.map(\.id) == ["d", "a", "x"] && b.starting("a", by: "p").items[1].state == .doing)
        #expect(b.place(of: "a") == 0 && b.place(of: "none") == nil)
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
