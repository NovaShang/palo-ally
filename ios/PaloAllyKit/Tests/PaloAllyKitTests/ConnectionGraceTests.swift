import Foundation
import Testing
@testable import PaloAllyKit

// iOS closes the socket whenever the app is suspended, so coming back always
// starts with a drop and a quick reconnect. The owner is only shown a drop
// that lasts (displayedConnection / connectionTrouble); a refusal shows at once.

@MainActor
@Suite("Connection: grace before showing a drop")
struct ConnectionGraceTests {
    func online(_ host: ManualHost, grace: Double) async -> AppStore {
        let store = AppStore(transport: host.transport)
        store.troubleGrace = grace
        store.start()
        _ = await until { store.connection == .online }
        return store
    }

    @Test func shortDropNeverShowsOffline() async throws {
        let host = ManualHost()
        let store = await online(host, grace: 0.4)
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        // Raw link is down, but nothing alarming shows.
        #expect(store.displayedConnection == .online)
        #expect(!store.connectionTrouble)
        try await Task.sleep(for: .milliseconds(150))
        await host.transport.simulateConnect()
        #expect(await until { store.connection == .online })
        // Past the original grace deadline: still never shown.
        try await Task.sleep(for: .milliseconds(450))
        #expect(!store.connectionTrouble)
        #expect(store.displayedConnection == .online)
    }

    @Test func longDropShowsOffline() async throws {
        let host = ManualHost()
        let store = await online(host, grace: 0.2)
        host.transport.simulateDisconnect(.network("gone"))
        #expect(store.displayedConnection == .online || !store.connectionTrouble)
        #expect(await until { store.connectionTrouble })
        #expect(store.displayedConnection == .offline("gone"))
        // Back again: shown as online, the trouble is over.
        await host.transport.simulateConnect()
        #expect(await until { store.connection == .online })
        #expect(!store.connectionTrouble)
        #expect(store.displayedConnection == .online)
    }

    @Test func rejectedShowsImmediately() async throws {
        let host = ManualHost()
        let store = await online(host, grace: 30)
        host.transport.simulateDisconnect(.rejected("unknown device"))
        #expect(await until(1) { store.connectionTrouble })
        #expect(store.displayedConnection == .rejected("unknown device"))
    }

    @Test func foregroundReconnectsImmediately() async throws {
        let host = ManualHost()
        let store = await online(host, grace: 30)
        let t0 = Date()
        store.didEnterBackground(at: t0)
        // Suspended: the socket went away.
        host.transport.simulateDisconnect(.closed)
        #expect(await until { store.connection != .online })
        // Back to the app (a short stay away: no forced reconnect needed) —
        // reconnects right away, no backoff, and the drop never shows.
        store.didBecomeActive(at: t0.addingTimeInterval(5))
        #expect(await until(1) { store.connection == .online })
        #expect(host.transport.forcedReconnects == 0)
        #expect(!store.connectionTrouble)
        #expect(store.displayedConnection == .online)
    }

    /// Time spent suspended doesn't count: a drop while away, however long,
    /// isn't shown on return — the grace starts over and the reconnect lands.
    @Test func dropWhileAwayDoesNotShowOnReturn() async throws {
        let host = ManualHost()
        let store = await online(host, grace: 0.2)
        store.didEnterBackground()
        host.transport.simulateDisconnect(.closed)
        #expect(await until { store.connection != .online })
        try await Task.sleep(for: .milliseconds(450)) // well past the grace, but away
        #expect(!store.connectionTrouble)
        store.didBecomeActive()
        #expect(await until(1) { store.connection == .online })
        #expect(!store.connectionTrouble)
        #expect(store.displayedConnection == .online)
    }

    @Test func sendDuringGraceQueuesQuietly() async throws {
        let host = ManualHost()
        let store = await online(host, grace: 30)
        host.transport.simulateDisconnect()
        #expect(await until { store.connection != .online })
        store.send("在路上")
        #expect(await until { store.messages.first?.delivery == .queued })
        // Not an error yet: it goes out by itself on the reconnect.
        #expect(store.lastError == nil)
        await host.transport.simulateConnect()
        #expect(await until { host.request("chat.send") != nil })
    }
}
