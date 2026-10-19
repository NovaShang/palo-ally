import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Pane tabs")
struct PaneTabsRulesTests {
    let session = PaneTabsKey.session("pal_a")
    let palo = PaneTabsKey.palo

    @Test func theDefaultHasOnlyThePinnedTab() {
        #expect(TabsState().normalized(key: palo).tabs.map(\.kind) == ["library"])
        #expect(TabsState().normalized(key: session).tabs.map(\.kind) == ["files"])
        #expect(TabsState().normalized(key: PaneTabsKey.workspace("ws_a")).tabs.map(\.kind) == ["files"])
    }

    @Test func aStateWithoutItsPinnedTabGetsItFirstAndClampsActive() {
        let s = TabsState(tabs: [.webTab("https://a.test"), PaneTab(kind: "files"), PaneTab(kind: "files")], active: 9, open: true)
        let n = s.normalized(key: session)
        #expect(n.tabs.map(\.kind) == ["files", "web"] && n.active == 1 && n.open)
        #expect(TabsState(tabs: [PaneTab(kind: "files")], active: -3).normalized(key: session).active == 0)
    }

    @Test func openingFilesShowsTheFilesTabOnce() {
        let a = TabsState().openingFiles(key: session)
        #expect(a.tabs.count == 1 && a.active == 0 && a.open)
        let w = TabsState().openingWeb(url: "https://a.test", key: session).openingFiles(key: session)
        #expect(w.tabs.count == 2 && w.active == 0)
        // Beside the assistant files is a tab of its own, after 成果.
        let p = TabsState().openingFiles(key: palo)
        #expect(p.tabs.map(\.kind) == ["library", "files"] && p.active == 1)
        #expect(p.openingFiles(key: palo).tabs.count == 2)
    }

    @Test func aPreviewReusesItsTabAndTheOthersAdd() {
        let a = TabsState().openingPreview(path: "a.md", key: session).openingPreview(path: "b.md", key: session)
        #expect(a.tabs.map(\.path) == [nil, "a.md", "b.md"] && a.active == 2)
        let again = a.openingPreview(path: "a.md", key: session)
        #expect(again.tabs.count == 3 && again.active == 1 && again.open)
    }

    @Test func aWebTabIsKeptPerAddress() {
        let a = TabsState().openingWeb(url: " https://a.test ", key: session).openingWeb(url: "https://b.test", key: session)
        #expect(a.tabs.compactMap(\.url) == ["https://a.test", "https://b.test"])
        let again = a.openingWeb(url: "https://a.test", key: session)
        #expect(again.tabs.count == 3 && again.active == 1)
    }

    @Test func closingKeepsThePinnedTabAndPicksTheNeighbour() {
        var s = TabsState().openingPreview(path: "a", key: session).openingPreview(path: "b", key: session).openingPreview(path: "c", key: session)
        #expect(s.closing(at: 0, key: session) == s.normalized(key: session))
        #expect(!s.canClose(at: 0, key: session) && s.canClose(at: 2, key: session) && !s.canClose(at: 9, key: session))
        // The last, active one: the one before it shows.
        s = s.closing(at: 3, key: session)
        #expect(s.tabs.map(\.path) == [nil, "a", "b"] && s.active == 2)
        // A middle, active one: the one that moved into its place.
        s = s.activating(1, key: session).closing(at: 1, key: session)
        #expect(s.tabs.map(\.path) == [nil, "b"] && s.active == 1)
        // One before the active one: the active tab stays the same tab.
        s = s.openingPreview(path: "d", key: session)
        #expect(s.active == 2)
        s = s.closing(at: 1, key: session)
        #expect(s.tabs.map(\.path) == [nil, "d"] && s.active == 1)
        // Nothing to close at a bad index; the 成果 tab is pinned beside the assistant.
        #expect(s.closing(at: 7, key: session) == s)
        #expect(TabsState().closing(at: 0, key: palo).tabs.map(\.kind) == ["library"])
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
        hub.activate(key, at: 1)
        #expect(hub.state(for: key).tabs.count == 3 && hub.state(for: key).active == 1 && hub.state(for: key).open)
        let sent = await until { await host.paneTabs[key] != nil && hub.writes == 1 }
        #expect(sent)
        let kept = await host.paneTabs[key]
        #expect(kept?.tabs.map(\.kind) == ["files", "web", "preview"] && kept?.active == 1)
        // The host stamped it, and the echo changed nothing.
        try await Task.sleep(for: .milliseconds(80))
        #expect(hub.state(for: key).updatedAt == kept?.updatedAt && hub.state(for: key).active == 1)
        #expect(hub.writes == 1)
    }

    @Test func anotherDevicesChangeIsShownAndADroppedKeyGoes() async throws {
        let (store, host, hub) = await demo()
        let key = PaneTabsKey.workspace("ws-1")
        let theirs = TabsState(tabs: [PaneTab(kind: "files"), .webTab("https://b.test")], active: 1, open: true, updatedAt: 500)
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": try .from(theirs)] as JSONValue)
        #expect(hub.state(for: key).tabs.count == 2 && hub.state(for: key).active == 1)
        // An older stamp is not taken.
        var older = theirs; older.updatedAt = 400; older.active = 0
        store.apply(event: RPCEventName.workbenchUpdated, data: ["key": .string(key), "state": try .from(older)] as JSONValue)
        #expect(hub.state(for: key).active == 1)
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
        #expect(s.retargetingWeb(at: 1, to: " https://a.test ", key: key).tabs[1].url == "https://a.test")
        #expect(s.retargetingWeb(at: 2, to: "https://a.test", key: key) == s)
        #expect(s.retargetingWeb(at: 0, to: "https://a.test", key: key) == s)
    }
}
