import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Pane tabs")
struct PaneTabsRulesTests {
    let session = PaneTabsKey.session("pal_a")
    let palo = PaneTabsKey.palo

    @Test func theDefaultHasOnlyThePinnedTabs() {
        for key in [palo, session, PaneTabsKey.workspace("ws_a")] {
            #expect(TabsState().normalized(key: key).tabs.map(\.kind) == ["pending", "library", "backlog", "files"])
        }
        #expect(PaneTabsKey.pinnedCount == 4)
    }

    @Test func aStateWithoutItsPinnedTabsGetsThemFirstAndKeepsTheActiveTab() {
        let s = TabsState(tabs: [.webTab("https://a.test"), PaneTab(kind: "files"), PaneTab(kind: "files")], active: 0, open: true)
        let n = s.normalized(key: session)
        #expect(n.tabs.map(\.kind) == ["pending", "library", "backlog", "files", "web"] && n.active == 4 && n.open)
        // Out of range clamps.
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: 9).normalized(key: session).active == 3)
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: -3).normalized(key: session).active == 0)
        // A state from when one tab was pinned: the active preview stays active, the active files tab is files.
        let old = TabsState(tabs: [PaneTab(kind: "files"), .previewTab("a.md")], active: 1)
        #expect(old.normalized(key: session).active == 4 && old.normalized(key: session).activeTab?.path == "a.md")
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: 0).normalized(key: session).activeTab?.kind == "files")
    }

    @Test func everyOlderLayoutIsMendedKeepingTheShownTab() {
        let pinned = ["pending", "library", "backlog", "files"]
        // 成果 and 文件 pinned, 等你 opened as a tab of its own after them:
        // it moves to the head, still the shown one.
        let tempPending = TabsState(tabs: [PaneTab(kind: "library"), PaneTab(kind: "files"), .webTab("https://a.test"), PaneTab(kind: "pending")], active: 3)
        let a = tempPending.normalized(key: session)
        #expect(a.tabs.map(\.kind) == pinned + ["web"] && a.activeTab?.kind == "pending")
        // 等你, 成果, 文件 pinned (no 待办 yet): a web tab shown stays shown.
        let noBacklog = TabsState(tabs: [PaneTab(kind: "pending"), PaneTab(kind: "library"), PaneTab(kind: "files"), .webTab("https://a.test")], active: 3)
        let b = noBacklog.normalized(key: session)
        #expect(b.tabs.map(\.kind) == pinned + ["web"] && b.active == 4 && b.activeTab?.url == "https://a.test")
        #expect(TabsState(tabs: noBacklog.tabs, active: 2).normalized(key: session).activeTab?.kind == "files")
        // 成果, 待办, 文件 pinned (no 等你 at the head): 待办 shown stays shown.
        let noPending = TabsState(tabs: [PaneTab(kind: "library"), PaneTab(kind: "backlog"), PaneTab(kind: "files"), .previewTab("/a.md")], active: 1)
        let c = noPending.normalized(key: session)
        #expect(c.tabs.map(\.kind) == pinned + ["preview"] && c.activeTab?.kind == "backlog")
        #expect(TabsState(tabs: noPending.tabs, active: 3).normalized(key: session).activeTab?.path == "/a.md")
        // Mending twice changes nothing.
        #expect(c.normalized(key: session) == c && b.normalized(key: session) == b)
    }

    @Test func pendingIsPinnedFirstAndOpensInPlace() {
        for key in [palo, session] {
            let p = TabsState().openingWeb(url: "https://a.test", key: key).openingPending(key: key)
            #expect(p.tabs.count == 5 && p.active == 0 && p.open && p.activeTab?.kind == PaneTab.pending)
            #expect(!p.canClose(at: 0, key: key) && p.closing(at: 0, key: key) == p.normalized(key: key))
        }
        #expect(PaneTabsKey.pinnedKinds.first == PaneTab.pending)
    }

    @Test func openingFilesLibraryAndBacklogShowTheirPinnedTab() {
        for key in [palo, session] {
            let f = TabsState().openingFiles(key: key)
            #expect(f.tabs.count == 4 && f.active == 3 && f.open)
            let l = f.openingLibrary(key: key)
            #expect(l.tabs.count == 4 && l.active == 1)
            let b = l.openingBacklog(key: key)
            #expect(b.tabs.count == 4 && b.active == 2 && b.activeTab?.kind == "backlog")
            let w = TabsState().openingWeb(url: "https://a.test", key: key).openingFiles(key: key)
            #expect(w.tabs.count == 5 && w.active == 3)
        }
    }

    @Test func aPreviewReusesItsTabAndTheOthersAdd() {
        let a = TabsState().openingPreview(path: "a.md", key: session).openingPreview(path: "b.md", key: session)
        #expect(a.tabs.map(\.path) == [nil, nil, nil, nil, "a.md", "b.md"] && a.active == 5)
        let again = a.openingPreview(path: "a.md", key: session)
        #expect(again.tabs.count == 6 && again.active == 4 && again.open)
    }

    @Test func aPreviewIsKeptByItsAbsolutePath() {
        let ws = PaneTabsKey.workspace("w1")
        let s = TabsState().openingPreview(path: "/Users/a/site/a.md", key: ws)
            .openingPreview(path: "/Users/a/blog/a.md", key: ws)
            .openingPreview(path: "/Users/a/site/a.md", key: ws)
        #expect(s.tabs.count == 6 && s.active == 4)
        #expect(s.tabs[4].isAbsolutePreview && !PaneTab.previewTab("a.md").isAbsolutePreview)
        // A tab an earlier version kept with a scope still reads (the scope is dropped).
        let old = try! JSONDecoder().decode(PaneTab.self, from: Data(#"{"kind":"preview","path":"a.md","scope":"pal:p1"}"#.utf8))
        #expect(old == PaneTab.previewTab("a.md"))
    }

    @Test func aWebTabIsKeptPerAddress() {
        let a = TabsState().openingWeb(url: " https://a.test ", key: session).openingWeb(url: "https://b.test", key: session)
        #expect(a.tabs.compactMap(\.url) == ["https://a.test", "https://b.test"])
        let again = a.openingWeb(url: "https://a.test", key: session)
        #expect(again.tabs.count == 6 && again.active == 4)
    }

    @Test func closingKeepsThePinnedTabsAndPicksTheNeighbour() {
        var s = TabsState().openingPreview(path: "a", key: session).openingPreview(path: "b", key: session).openingPreview(path: "c", key: session)
        for i in 0..<4 {
            #expect(s.closing(at: i, key: session) == s.normalized(key: session))
            #expect(!s.canClose(at: i, key: session))
        }
        #expect(s.canClose(at: 5, key: session) && !s.canClose(at: 9, key: session))
        // The last, active one: the one before it shows.
        s = s.closing(at: 6, key: session)
        #expect(s.tabs.map(\.path) == [nil, nil, nil, nil, "a", "b"] && s.active == 5)
        // A middle, active one: the one that moved into its place.
        s = s.activating(4, key: session).closing(at: 4, key: session)
        #expect(s.tabs.map(\.path) == [nil, nil, nil, nil, "b"] && s.active == 4)
        // One before the active one: the active tab stays the same tab.
        s = s.openingPreview(path: "d", key: session)
        #expect(s.active == 5)
        s = s.closing(at: 4, key: session)
        #expect(s.tabs.map(\.path) == [nil, nil, nil, nil, "d"] && s.active == 4)
        // Nothing to close at a bad index.
        #expect(s.closing(at: 8, key: session) == s)
        #expect(TabsState().closing(at: 0, key: palo).tabs.map(\.kind) == ["pending", "library", "backlog", "files"])
    }

    @Test func madeByKeepsOneSessionsItems() {
        let a = Artifact(id: "1", title: "", type: "", mainFile: "", source: "pal_a", updatedAt: 0)
        let b = Artifact(id: "2", title: "", type: "", mainFile: "", source: "palo", updatedAt: 0)
        #expect([a, b].made(by: "pal_a").map(\.id) == ["1"])
        #expect([a, b].made(by: nil).count == 2)
    }

    @Test func activatingAndOpenAreSeparate() {
        let s = TabsState().openingWeb(url: "https://a.test", key: session)
        #expect(s.activating(0, key: session).active == 0 && s.activating(0, key: session).open)
        #expect(s.activating(5, key: session).active == s.active)
        #expect(s.settingOpen(false, key: session).open == false && s.settingOpen(false, key: session).tabs == s.tabs)
    }
}

@MainActor
@Suite("Pane tabs hub", .serialized)
struct PaneTabsHubTests {
    func demo() async -> (AppStore, DemoHost, PaneTabsHub) {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.pals.count == 4 }
        PaneTabsHub.throttle = .milliseconds(30)
        return (store, host, PaneTabsHub.shared(for: store))
    }

    @Test func editsGoOutOnceAndTheEchoIsDropped() async throws {
        let (store, host, hub) = await demo()
        defer { withExtendedLifetime(store) {} }
        let key = PaneTabsKey.session("pal-site")
        hub.openWeb(key, url: "https://a.test")
        hub.openPreview(key, path: "README.md")
        hub.activate(key, at: 4)
        #expect(hub.state(for: key).tabs.count == 6 && hub.state(for: key).active == 4 && hub.state(for: key).open)
        let sent = await until { await host.paneTabs[key] != nil && hub.writes == 1 }
        #expect(sent)
        let kept = await host.paneTabs[key]
        #expect(kept?.tabs.map(\.kind) == ["pending", "library", "backlog", "files", "web", "preview"] && kept?.active == 4)
        // The host stamped it, and the echo changed nothing.
        try await Task.sleep(for: .milliseconds(80))
        #expect(hub.state(for: key).updatedAt == kept?.updatedAt && hub.state(for: key).active == 4)
        #expect(hub.writes == 1)
    }

    @Test func anotherDevicesChangeIsShownAndADroppedKeyGoes() async throws {
        let (store, host, hub) = await demo()
        let key = PaneTabsKey.workspace("ws-1")
        let theirs = TabsState(tabs: [PaneTab(kind: "files"), .webTab("https://b.test")], active: 1, open: true, updatedAt: 500)
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": try .from(theirs)] as JSONValue)
        #expect(hub.state(for: key).tabs.count == 5 && hub.state(for: key).active == 4)
        // An older stamp is not taken.
        var older = theirs; older.updatedAt = 400; older.active = 0
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": try .from(older)] as JSONValue)
        #expect(hub.state(for: key).active == 4)
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": .null] as JSONValue)
        #expect(hub.state(for: key).open == false && hub.states[key] == nil)
        _ = host
    }

    @Test func loadingTakesWhatTheHostHas() async throws {
        let (store, _, hub) = await demo()
        _ = try await store.rpc.callRaw(RPCMethod.workbenchTabsSet, params: TabsSetParams(key: "palo", tabs: [PaneTab(kind: "library")], active: 0, open: true))
        await hub.load()
        #expect(hub.loaded && hub.state(for: "palo").open)
    }
}

@Suite("Web addresses")
struct WebAddressTests {
    @Test func addressesAndSearches() {
        #expect(WebAddress.url(from: "  ") == nil)
        #expect(WebAddress.url(from: "https://a.test/x?y=1")?.absoluteString == "https://a.test/x?y=1")
        #expect(WebAddress.url(from: "example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(WebAddress.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(WebAddress.url(from: "192.168.1.5:8080/a")?.absoluteString == "http://192.168.1.5:8080/a")
        #expect(WebAddress.url(from: "swift concurrency")?.absoluteString == "https://duckduckgo.com/?q=swift%20concurrency")
        #expect(WebAddress.url(from: "hello")?.host == "duckduckgo.com")
        #expect(WebAddress.label(for: "https://www.example.com/a") == "example.com")
    }

    @Test func retargetingChangesOnlyAWebTab() {
        let key = PaneTabsKey.session("pal_a")
        let s = TabsState().openingWeb(url: "", key: key).openingPreview(path: "a.md", key: key)
        #expect(s.retargetingWeb(at: 4, to: " https://a.test ", key: key).tabs[4].url == "https://a.test")
        #expect(s.retargetingWeb(at: 5, to: "https://a.test", key: key) == s)
        #expect(s.retargetingWeb(at: 0, to: "https://a.test", key: key) == s)
    }
}
