import Foundation
import Testing
@testable import PaloAllyKit

/// Claude 用量 (docs/workbench-design/usage.html): what a computer says of its
/// plan, and what the app works out from it.
@Suite("Plan usage")
@MainActor
struct UsageTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: Int64 = 3600_000

    private func limit(_ used: Int, window: Int64 = 5 * hour, left: Int64?, kind: String = "session") -> UsageLimit {
        UsageLimit(kind: kind, group: kind, used: used, resetsAt: left.map { Self.now.epochMillis + $0 }, windowMs: window)
    }

    @Test func decodesAsTheHostSendsItAndLaterHostsToo() throws {
        let json = #"""
        {"usage":{"state":"limits","extraUsage":false,"at":5,"account":{"email":"lin@example.com","organization":"Lin","plan":"max"},
        "limits":[{"kind":"session","group":"session","used":48,"resetsAt":10,"windowMs":18000000},
                  {"kind":"weekly_scoped","group":"weekly","used":44,"resetsAt":20,"windowMs":604800000,"scope":"Opus"}]}}
        """#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let (r, issues) = try LenientDiagnostics.collect { try v.decode(UsageResult.self) }
        #expect(issues.isEmpty)
        let u = try #require(r.usage)
        #expect(u.state == .limits && u.extraUsage == false && u.at == 5 && !u.stale)
        #expect(u.limits.map(\.left) == [52, 56])
        #expect(u.limits[1].scope == "Opus")
        #expect(u.account?.planName("Claude") == "Claude Max")
        // a state and a kind this app doesn't know
        let later = try JSONDecoder().decode(UsageStatus.self, from: Data(#"{"state":"paused","limits":[{"kind":"monthly","used":130}]}"#.utf8))
        #expect(later.state == .unknown)
        #expect(later.limits.first?.kind == "monthly" && later.limits.first?.used == 100)
        let none = try JSONDecoder().decode(UsageStatus.self, from: Data(#"{"state":"none","limits":[]}"#.utf8))
        #expect(none.state == .noLimits)
    }

    @Test func colorsAsTheIndicators() {
        #expect([0, 79, 80, 94, 95, 100].map { limit($0, left: 1).tone } == [.normal, .normal, .warn, .warn, .danger, .danger])
    }

    @Test func thePaceIsTheWindowsAverageSoFar() {
        // 3 h 08 of 5 h gone by (the draft's numbers).
        let left: Int64 = 112 * 60_000
        #expect(abs(limit(48, left: left).elapsed(Self.now)! - 0.6267) < 0.001)
        #expect(limit(48, left: left).pace(Self.now) == .lasts)
        guard case .runsOut(let at)? = limit(84, left: left).pace(Self.now) else { Issue.record("runs out"); return }
        // start + 188 min / 0.84 = 223.8 min into the window, 35.8 min from now
        #expect(abs(at.timeIntervalSince(Self.now) - 35.8 * 60) < 10)
        // exactly even: lasts
        #expect(limit(50, left: 5 * Self.hour / 2).pace(Self.now) == .lasts)
        #expect(limit(0, left: left).pace(Self.now) == .lasts)
        // used up, too early, over, or nothing to go by: says nothing
        #expect(limit(100, left: left).pace(Self.now) == nil)
        #expect(limit(9, left: 5 * Self.hour * 91 / 100).pace(Self.now) == nil)
        #expect(limit(9, left: 5 * Self.hour * 89 / 100).pace(Self.now) == .lasts)
        #expect(limit(48, left: -1).pace(Self.now) == nil)
        #expect(limit(48, left: nil).pace(Self.now) == nil)
        #expect(limit(48, window: 0, left: left).elapsed(Self.now) == nil)
    }

    @Test func theTightestIsTheOneUsedMostWhoseWindowGoesOn() {
        let u = UsageStatus(state: .limits, limits: [limit(90, left: -1), limit(57, left: 1, kind: "a"), limit(57, left: 1, kind: "b"), limit(44, left: nil, kind: "c")])
        #expect(u.tightest(Self.now)?.kind == "a")
        #expect(UsageStatus(state: .limits).tightest(Self.now) == nil)
    }

    @Test func oneAccountOnTwoComputersCountsOnce() {
        func u(_ email: String?, _ used: Int, at: Int64, org: String? = "Lin") -> UsageStatus {
            UsageStatus(state: .limits, limits: [limit(used, left: Self.hour)], account: LoginAccount(email: email, organization: org), at: at)
        }
        let same = UsageGroup.grouped([("a", u("lin@example.com", 40, at: 1)), ("b", u("lin@example.com", 42, at: 2))], now: Self.now)
        #expect(same.map(\.hosts) == [["a", "b"]])
        #expect(same.first?.usage.limits.first?.used == 42) // the latest numbers
        // another organization, or no email at all (two keys): not the same
        let apart = UsageGroup.grouped([("a", u("lin@example.com", 40, at: 1)), ("b", u("lin@example.com", 88, at: 2, org: "Company")),
                                        ("c", u(nil, 10, at: 3)), ("d", u(nil, 10, at: 4))], now: Self.now)
        #expect(apart.map(\.hosts) == [["b"], ["a"], ["c"], ["d"]]) // the tightest first
        // no numbers: last
        let quiet = UsageGroup.grouped([("a", UsageStatus(state: .noLimits)), ("b", u("x@example.com", 1, at: 1))], now: Self.now)
        #expect(quiet.map(\.hosts) == [["b"], ["a"]])
    }

    @Test func loadsOnConnectingAndFollowsTheHost() async throws {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        #expect(store.usage == nil && store.usageSupported == nil)
        store.start()
        #expect(await until { store.usageSupported == true })
        #expect(store.usage?.tightest(Date())?.kind == "weekly_all")
        await host.applyScenario("usageNear")
        #expect(await until { store.usage?.tightest(Date())?.used == 84 })
        await store.loadUsage(refresh: true)
        #expect(await host.lastParams["usage.get"]?["refresh"] == true)
    }

    @Test func aHostFromBeforeItHasNone() async {
        let host = DemoHost(speed: 0)
        await host.applyScenario("usageOld")
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.usageSupported == false })
        #expect(store.usage == nil)
    }

    @Test func theNumbersStayWhileTheComputerIsAway() async {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.usageSupported == true })
        await host.applyScenario("usageOffline")
        #expect(await until { !store.connection.isOnline })
        #expect(store.usage?.limits.count == 3)
        #expect(store.usageSupported == true)
    }

    @Test func everyStateOfTheDraftIsInTheDemo() async {
        let host = DemoHost(speed: 0), office = DemoHost(speed: 0, office: true)
        let now = Date().epochMillis
        for (name, state) in [("usage", UsageState.limits), ("usageNear", .limits), ("usageExtra", .limits), ("usageHit", .limits), ("usageHitModel", .limits),
                              ("usageHitExtra", .limits), ("usageLoading", .loading), ("usageFailed", .limits), ("usageOffline", .limits),
                              ("usageNoMethod", .unsupported), ("usageHidden", .hidden), ("usageApi", .noLimits), ("usageBedrock", .noLimits)] {
            #expect(await host.demoUsage(for: name, now: now)?.state == state, "\(name)")
        }
        #expect(await host.demoUsage(for: "usageFailed", now: now)?.stale == true)
        #expect(await host.demoUsage(for: "nothing", now: now) == nil)
        for (name, groups) in [("usageDiff", 2), ("usageSame", 1)] {
            let all = [("home", await host.demoUsage(for: name, now: now)!), ("office", await office.demoUsage(for: name, now: now)!)]
            #expect(UsageGroup.grouped(all).count == groups)
        }
    }
}
