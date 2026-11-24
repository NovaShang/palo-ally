import Foundation

// Claude 用量 in the demo host (docs/workbench-design/usage.html), each state
// by `-demoState`: usageNear, usageExtra (near, extra usage on), usageHit,
// usageHitMany (12 agents), usageHitModel (one model's week), usageHitExtra (hit, extra usage on),
// usageSignedOut, usageLogoutFails, usageLoading, usageFailed (no answer lately), usageOffline (the computer
// goes away), usageNoMethod (the account alone), usageHidden, usageApi,
// usageBedrock, usageOld (a host from before it); with `-demoHosts 2`,
// usageDiff (two accounts) and usageSame (one). Otherwise a usual day.
extension DemoHost {
    static let demoAccount = LoginAccount(email: "lin@example.com", organization: "Lin", plan: "max")
    static let demoTeamAccount = LoginAccount(email: "lin@company.example", organization: "Company", plan: "team")

    static let demoOtherAccount = LoginAccount(email: "mei@example.com", organization: "Mei", plan: "pro")

    private static func session(_ used: Int, inMinutes: Int64, now: Int64) -> UsageLimit {
        UsageLimit(kind: "session", group: "session", used: used, resetsAt: now + inMinutes * 60_000, windowMs: 5 * 3600_000)
    }

    private static func week(_ used: Int, inHours: Int64, scope: String? = nil, now: Int64) -> UsageLimit {
        UsageLimit(kind: scope == nil ? "weekly_all" : "weekly_scoped", group: "weekly", used: used,
                   resetsAt: now + inHours * 3600_000, windowMs: 7 * 24 * 3600_000, scope: scope)
    }

    static func demoUsage(_ used: Int = 48, opus: Int = 44, extra: Bool = false, now: Int64) -> UsageStatus {
        UsageStatus(state: .limits,
                    limits: [session(used, inMinutes: 112, now: now), week(57, inHours: 64, now: now), week(opus, inHours: 64, scope: "Opus", now: now)],
                    extraUsage: extra, account: demoAccount, at: now - 60_000)
    }

    /// nil: not one of these.
    func demoUsage(for scenario: String, now: Int64) -> UsageStatus? {
        switch scenario {
        case "usageNear": return Self.demoUsage(84, now: now)
        case "usageExtra": return Self.demoUsage(84, extra: true, now: now)
        case "usageHit", "usageHitMany": return Self.demoUsage(100, now: now)
        case "usageHitModel": return Self.demoUsage(opus: 100, now: now)
        case "usageHitExtra": return Self.demoUsage(100, extra: true, now: now)
        case "usageLoading": return UsageStatus(state: .loading)
        case "usageFailed", "usageOffline":
            var u = Self.demoUsage(now: now)
            u.at = now - 3 * 3600_000
            u.stale = scenario == "usageFailed"
            return u
        case "usageNoMethod": return UsageStatus(state: .unsupported, account: Self.demoAccount)
        case "usageHidden": return UsageStatus(state: .hidden, account: Self.demoAccount)
        case "usageApi": return UsageStatus(state: .noLimits, account: LoginAccount(apiKeySource: "ANTHROPIC_API_KEY"))
        case "usageBedrock": return UsageStatus(state: .noLimits, account: LoginAccount(provider: "bedrock"))
        case "usageDiff" where office:
            return UsageStatus(state: .limits, limits: [Self.session(31, inMinutes: 192, now: now), Self.week(88, inHours: 29, now: now)],
                               extraUsage: false, account: Self.demoTeamAccount, at: now - 60_000)
        case "usage", "usageDiff", "usageSame", "usageSignedOut", "usageLogoutFails": return Self.demoUsage(now: now)
        default: return nil
        }
    }

    func applyUsageScenario(_ name: String) {
        usageScenario = name
        if name == "usageSignedOut" { _ = try? demoLogout() }
        guard name != "usageOld", var u = demoUsage(for: name, now: Date().epochMillis) else { return }
        // Used up (extra usage off): what it stopped, to go on when it resets.
        if u.extraUsage != true, let l = u.limits.first(where: \.isUsedUp) {
            var stopped = stopDemoWork(until: l.resetsAt)
            if name == "usageHitMany" {
                let names = ["把三年的照片按地点和人物重新归类并去重，拿不准的单独放一个相册", "接口迁移", "Quarterly report: pull numbers from three sources and reconcile",
                             "合同审阅", "数据看板", "季度总结", "课程表", "旅行计划", "周报", "翻译"]
                stopped.agents += names.enumerated().map { .init(id: "pal-more-\($0.offset)", name: $0.element, until: l.resetsAt) }
            }
            u.stopped = stopped
            for a in stopped.agents.prefix(2) where until(l) != nil {
                var m = ChatMessage(seq: (palLogs[a.id]?.map(\.seq).max() ?? 0) + 1, id: "limit-\(a.id)", role: .system, kind: .notice,
                                      text: "5 小时额度用完了，\(until(l) ?? "") 恢复，到点我自己接着做。", ts: Date().epochMillis)
                m.pal = a.id
                appendPal(m)
            }
        }
        usage = u
        emit(RPCEventName.usageUpdated, ["usage": u])
        guard name == "usageOffline" else { return }
        // The numbers stay on the app while the computer is away.
        Task {
            await pause(3)
            transport.unreachable = true
            transport.simulateDisconnect()
        }
    }

    /// auth.logout: what runs stops, and all waits for a sign-in.
    func demoLogout() throws -> JSONValue {
        if usageScenario == "usageLogoutFails" { throw DemoError(message: "没能退出登录，刚才停下的已经接着做了") }
        var s = status
        s.auth = AuthStatus(state: .expired, since: Date().epochMillis, stopped: stopDemoWork(until: nil), signedOut: true)
        setStatus(s)
        return ["auth": try .from(s.auth)]
    }

    /// A sign-in went through (`account`: another one's; its numbers come a moment later).
    func demoSignedIn(_ account: LoginAccount?) {
        guard let account, account != usage.account else { return }
        usage = UsageStatus(state: .loading, account: account)
        emit(RPCEventName.usageUpdated, ["usage": usage])
        Task {
            await pause(2)
            usage = Self.demoUsage(12, opus: 5, now: Date().epochMillis)
            usage.account = account
            emit(RPCEventName.usageUpdated, ["usage": usage])
        }
    }

    private func until(_ l: UsageLimit) -> String? {
        l.resetsAt.map {
            let p = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double($0) / 1000))
            return String(format: "%02d:%02d", p.hour ?? 0, p.minute ?? 0)
        }
    }

    /// 网站帮手 and 笔记整理 stop mid-turn (nothing of them waits on the owner), and the assistant.
    func stopDemoWork(until: Int64?) -> StoppedWork {
        let ids = ["pal-site", "pal-notes"].filter { id in pals.contains { $0.id == id } }
        for id in ids {
            settlePalCards(of: id)
            setPal(id) { $0.status = .idle; $0.attention = .idle; $0.finishedAt = nil }
        }
        return StoppedWork(assistant: true, until: until, agents: ids.compactMap { id in
            pals.first { $0.id == id }.map { StoppedWork.Agent(id: id, name: $0.name, until: until) }
        }, schedules: 2)
    }

    func usageGet(_ p: JSONValue) throws -> JSONValue {
        if usageScenario == "usageOld" { throw DemoError(message: "unknown method \(RPCMethod.usageGet)") }
        // Asked again: the same numbers, as of now.
        let now = Date().epochMillis
        if p["refresh"] == true, let at = usage.at, !usage.stale, status.auth == nil, usageScenario != "usageOffline", now - at >= 60_000 {
            usage.at = now
            emit(RPCEventName.usageUpdated, ["usage": usage])
        }
        return ["usage": try .from(usage)]
    }
}
