import Foundation

// How much of the plan of a computer's login is used (host/src/planUsage.ts;
// docs/workbench-design/usage.html): the limits there are, as they come, and
// the login they're for. What's computed from them is only what they say:
// what's left, how far their window has run, and whether the average pace so
// far would use one up before it resets.

public enum UsageState: String, TolerantStringEnum {
    /// limits: the numbers are there; noLimits: this login has no plan limits (a
    /// key, another provider); hidden: a subscription whose login may not see
    /// them; unsupported: the computer can't be asked (the account alone).
    case loading, limits, hidden, unsupported, unknown
    case noLimits = "none"
    public static let fallback = UsageState.unknown
}

/// The login the agents run on.
public struct LoginAccount: Codable, Sendable, Hashable {
    public var email: String?
    public var organization: String?
    /// "pro", "max", "team", …; nil for a key or another provider.
    public var plan: String?
    /// Another provider's ("bedrock", "vertex", …).
    public var provider: String?
    /// A key instead of a login: where it's set.
    public var apiKeySource: String?

    public init(email: String? = nil, organization: String? = nil, plan: String? = nil, provider: String? = nil, apiKeySource: String? = nil) {
        self.email = email; self.organization = organization; self.plan = plan
        self.provider = provider; self.apiKeySource = apiKeySource
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        email = l.string("email"); organization = l.string("organization"); plan = l.string("plan")
        provider = l.string("provider"); apiKeySource = l.string("apiKeySource")
    }

    /// 「Claude Max」: whose account (the harness' word for it) and the plan.
    public func planName(_ brand: String) -> String? {
        guard let plan, let first = plan.first else { return nil }
        return "\(brand) \(first.uppercased())\(plan.dropFirst())"
    }

    /// The same account on another computer (email and organization alike).
    public func isSame(as other: LoginAccount) -> Bool {
        guard let email, !email.isEmpty else { return false }
        return email == other.email && organization == other.organization
    }
}

/// One of the plan's limits.
public struct UsageLimit: Codable, Sendable, Hashable {
    /// "session", "weekly_all", "weekly_scoped"; a new one comes as it is.
    public var kind: String
    public var group: String
    /// 0 to 100.
    public var used: Int
    public var resetsAt: Int64?
    /// How long its window is.
    public var windowMs: Int64?
    /// The model it's for (its name), when it's for one.
    public var scope: String?

    public init(kind: String, group: String, used: Int, resetsAt: Int64? = nil, windowMs: Int64? = nil, scope: String? = nil) {
        self.kind = kind; self.group = group; self.used = used
        self.resetsAt = resetsAt; self.windowMs = windowMs; self.scope = scope
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        kind = l.string("kind", or: "")
        group = l.string("group", or: "")
        used = min(100, max(0, l.int("used", or: 0)))
        resetsAt = l.millis("resetsAt")
        windowMs = l.millis("windowMs")
        scope = l.string("scope")
    }

    public var left: Int { 100 - used }
    public var isUsedUp: Bool { used >= 100 }

    /// The indicator's arc colors: orange from 80%, red from 95%.
    public var tone: IndicatorRules.ArcTone { IndicatorRules.arcTone(fraction: Double(used) / 100) }

    /// Its window is over: these numbers are from before.
    public func hasReset(_ now: Date) -> Bool { resetsAt.map { $0 <= now.epochMillis } ?? false }

    /// How much of its window has gone by, 0...1.
    public func elapsed(_ now: Date) -> Double? {
        guard let resetsAt, let windowMs, windowMs > 0, !hasReset(now) else { return nil }
        return min(1, max(0, 1 - Double(resetsAt - now.epochMillis) / Double(windowMs)))
    }

    public enum Pace: Sendable, Hashable {
        case lasts
        case runsOut(Date)
    }

    /// At the window's average pace so far: whether it lasts until it resets,
    /// or when it's used up. Nothing in the first tenth of the window (too
    /// little to go by), or once it's used up.
    public func pace(_ now: Date) -> Pace? {
        guard let resetsAt, let windowMs, let elapsed = elapsed(now), elapsed >= 0.1, !isUsedUp else { return nil }
        guard used > 0 else { return .lasts }
        let start = Double(resetsAt - windowMs)
        let out = start + elapsed * Double(windowMs) * 100 / Double(used)
        return out >= Double(resetsAt) ? .lasts : .runsOut(Date(timeIntervalSince1970: out / 1000))
    }
}

public struct UsageStatus: Codable, Sendable, Hashable {
    public var state: UsageState
    public var limits: [UsageLimit]
    /// Past the limits it goes on, paid by use.
    public var extraUsage: Bool?
    public var account: LoginAccount?
    /// When the numbers came (ms).
    public var at: Int64?
    /// Asked since and got no answer: the numbers are from `at`.
    public var stale: Bool

    public init(state: UsageState, limits: [UsageLimit] = [], extraUsage: Bool? = nil, account: LoginAccount? = nil,
                at: Int64? = nil, stale: Bool = false) {
        self.state = state; self.limits = limits; self.extraUsage = extraUsage
        self.account = account; self.at = at; self.stale = stale
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        state = l.decode(UsageState.self, "state", or: .unknown)
        limits = l.array(UsageLimit.self, "limits", or: [])
        extraUsage = l.bool("extraUsage")
        account = l.decode(LoginAccount.self, "account")
        at = l.millis("at")
        stale = l.bool("stale") ?? false
    }

    /// The limit used the most: the one met first (none whose window is over).
    public func tightest(_ now: Date) -> UsageLimit? {
        limits.filter { !$0.hasReset(now) }.reduce(nil) { best, l in best.map { $0.used >= l.used ? $0 : l } ?? l }
    }
}

/// `usage.get {refresh}` → `{usage}`; `usage.updated` carries the same.
public struct UsageParams: Codable, Sendable {
    public var refresh: Bool
    public init(refresh: Bool) { self.refresh = refresh }
}

public struct UsageResult: Decodable, Sendable {
    public var usage: UsageStatus?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        usage = l.expect("usage", l.decode(UsageStatus.self, "usage"))
    }
}

/// Several computers on the same account count once: its computers and the
/// latest numbers any of them has.
public struct UsageGroup: Sendable, Hashable {
    public var hosts: [String]
    public var usage: UsageStatus

    /// One per account, the tightest first (a computer with no numbers after
    /// those that have them; else the order given).
    public static func grouped(_ all: [(host: String, usage: UsageStatus)], now: Date = Date()) -> [UsageGroup] {
        var groups: [UsageGroup] = []
        for (host, usage) in all {
            if let a = usage.account, let i = groups.firstIndex(where: { $0.usage.account.map(a.isSame) == true }) {
                groups[i].hosts.append(host)
                if (usage.at ?? 0) > (groups[i].usage.at ?? 0) { groups[i].usage = usage }
            } else {
                groups.append(UsageGroup(hosts: [host], usage: usage))
            }
        }
        func used(_ g: UsageGroup) -> Int { g.usage.tightest(now)?.used ?? -1 }
        return groups.enumerated().sorted { (used($0.element), $1.offset) > (used($1.element), $0.offset) }.map(\.element)
    }
}
