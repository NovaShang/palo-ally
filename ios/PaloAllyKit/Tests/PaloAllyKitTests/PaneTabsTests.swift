import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Pane tabs")
struct PaneTabsRulesTests {
    let session = PaneTabsKey.session("pal_a")
    let palo = PaneTabsKey.palo

    @Test func theDefaultHasOnlyThePinnedTabs() {
        for key in [palo, session, PaneTabsKey.workspace("ws_a")] {
            #expect(TabsState().normalized(key: key).tabs.map(\.kind) == ["library", "files"])
        }
    }

    @Test func aStateWithoutItsPinnedTabsGetsThemFirstAndKeepsTheActiveTab() {
        let s = TabsState(tabs: [.webTab("https://a.test"), PaneTab(kind: "files"), PaneTab(kind: "files")], active: 0, open: true)
        let n = s.normalized(key: session)
        #expect(n.tabs.map(\.kind) == ["library", "files", "web"] && n.active == 2 && n.open)
        // Out of range clamps.
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: 9).normalized(key: session).active == 1)
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: -3).normalized(key: session).active == 0)
        // A state from when one tab was pinned: the active preview stays active, the active files tab is files.
        let old = TabsState(tabs: [PaneTab(kind: "files"), .previewTab("a.md")], active: 1)
        #expect(old.normalized(key: session).active == 2 && old.normalized(key: session).activeTab?.path == "a.md")
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: 0).normalized(key: session).activeTab?.kind == "files")
    }

    @Test func openingFilesAndLibraryShowTheirPinnedTab() {
        for key in [palo, session] {
            let f = TabsState().openingFiles(key: key)
            #expect(f.tabs.count == 2 && f.active == 1 && f.open)
            let l = f.openingLibrary(key: key)
            #expect(l.tabs.count == 2 && l.active == 0)
            let w = TabsState().openingWeb(url: "https://a.test", key: key).openingFiles(key: key)
            #expect(w.tabs.count == 3 && w.active == 1)
        }
    }

    @Test func aPreviewReusesItsTabAndTheOthersAdd() {
        let a = TabsState().openingPreview(path: "a.md", key: session).openingPreview(path: "b.md", key: session)
        #expect(a.tabs.map(\.path) == [nil, nil, "a.md", "b.md"] && a.active == 3)
        let again = a.openingPreview(path: "a.md", key: session)
        #expect(again.tabs.count == 4 && again.active == 2 && again.open)
    }

    @Test func aPreviewKeepsTheFilesItWasOpenedIn() {
        let ws = PaneTabsKey.workspace("w1")
        let s = TabsState().openingPreview(path: "a.md", scope: .pal("p1"), key: ws)
            .openingPreview(path: "a.md", scope: .pal("p2"), key: ws)
            .openingPreview(path: "a.md", scope: .pal("p1"), key: ws)
        #expect(s.tabs.count == 4 && s.active == 2)
        #expect(s.tabs[2].fileScope == .pal("p1") && s.tabs[3].fileScope == .pal("p2"))
        #expect(PaneTab.previewTab("a.md").fileScope == nil)
        for scope in [FileScope.palo, .home, .pal("x"), .folder("f:1")] { #expect(FileScope(tag: scope.tag) == scope) }
        for bad in ["", "pal:", "nope", "palo:x", "home:1"] { #expect(FileScope(tag: bad) == nil) }
    }

    @Test func aWebTabIsKeptPerAddress() {
        let a = TabsState().openingWeb(url: " https://a.test ", key: session).openingWeb(url: "https://b.test", key: session)
        #expect(a.tabs.compactMap(\.url) == ["https://a.test", "https://b.test"])
        let again = a.openingWeb(url: "https://a.test", key: session)
        #expect(again.tabs.count == 4 && again.active == 2)
    }

    @Test func closingKeepsThePinnedTabsAndPicksTheNeighbour() {
        var s = TabsState().openingPreview(path: "a", key: session).openingPreview(path: "b", key: session).openingPreview(path: "c", key: session)
        #expect(s.closing(at: 0, key: session) == s.normalized(key: session))
        #expect(s.closing(at: 1, key: session) == s.normalized(key: session))
        #expect(!s.canClose(at: 0, key: session) && !s.canClose(at: 1, key: session) && s.canClose(at: 3, key: session) && !s.canClose(at: 9, key: session))
        // The last, active one: the one before it shows.
        s = s.closing(at: 4, key: session)
        #expect(s.tabs.map(\.path) == [nil, nil, "a", "b"] && s.active == 3)
        // A middle, active one: the one that moved into its place.
        s = s.activating(2, key: session).closing(at: 2, key: session)
        #expect(s.tabs.map(\.path) == [nil, nil, "b"] && s.active == 2)
        // One before the active one: the active tab stays the same tab.
        s = s.openingPreview(path: "d", key: session)
        #expect(s.active == 3)
        s = s.closing(at: 2, key: session)
        #expect(s.tabs.map(\.path) == [nil, nil, "d"] && s.active == 2)
        // Nothing to close at a bad index.
        #expect(s.closing(at: 7, key: session) == s)
        #expect(TabsState().closing(at: 0, key: palo).tabs.map(\.kind) == ["library", "files"])
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
        hub.activate(key, at: 2)
        #expect(hub.state(for: key).tabs.count == 4 && hub.state(for: key).active == 2 && hub.state(for: key).open)
        let sent = await until { await host.paneTabs[key] != nil && hub.writes == 1 }
        #expect(sent)
        let kept = await host.paneTabs[key]
        #expect(kept?.tabs.map(\.kind) == ["library", "files", "web", "preview"] && kept?.active == 2)
        // The host stamped it, and the echo changed nothing.
        try await Task.sleep(for: .milliseconds(80))
        #expect(hub.state(for: key).updatedAt == kept?.updatedAt && hub.state(for: key).active == 2)
        #expect(hub.writes == 1)
    }

    @Test func anotherDevicesChangeIsShownAndADroppedKeyGoes() async throws {
        let (store, host, hub) = await demo()
        let key = PaneTabsKey.workspace("ws-1")
        let theirs = TabsState(tabs: [PaneTab(kind: "files"), .webTab("https://b.test")], active: 1, open: true, updatedAt: 500)
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": try .from(theirs)] as JSONValue)
        #expect(hub.state(for: key).tabs.count == 3 && hub.state(for: key).active == 2)
        // An older stamp is not taken.
        var older = theirs; older.updatedAt = 400; older.active = 0
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": try .from(older)] as JSONValue)
        #expect(hub.state(for: key).active == 2)
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
        #expect(s.retargetingWeb(at: 2, to: " https://a.test ", key: key).tabs[2].url == "https://a.test")
        #expect(s.retargetingWeb(at: 3, to: "https://a.test", key: key) == s)
        #expect(s.retargetingWeb(at: 0, to: "https://a.test", key: key) == s)
    }
}
