import Foundation

/// How much of the plan of this computer's login is used (Claude 用量): kept
/// by the host, which says when it changes (`usage.updated`).
extension AppStore {
    /// nil until the host has answered.
    public var usage: UsageStatus? { shared.usage }

    /// false for a host from before usage.get; nil until asked.
    public var usageSupported: Bool? { shared.usageSupported }

    /// Reading for a while and nothing yet: no longer said to be on its way (until the numbers come).
    public var usageOverdue: Bool { shared.usageOverdue }

    /// How long it's said to be reading.
    static var usagePatience: Duration { .seconds(15) }

    /// `refresh`: its page is open (the host asks again when a minute has passed; the news comes as an event).
    public func loadUsage(refresh: Bool = false) async {
        do {
            let r: UsageResult = try await rpc.call(RPCMethod.usageGet, params: UsageParams(refresh: refresh))
            apply(usage: r.usage)
        } catch {
            guard case .remote(let m)? = error as? RPCError, m.lowercased().contains("unknown method") else { return }
            shared.usageSupported = false
            shared.usage = nil
        }
    }

    func apply(usage: UsageStatus?, patience: Duration = AppStore.usagePatience) {
        guard let usage else { return }
        if usage.state != .loading {
            shared.usageWait?.cancel()
            shared.usageWait = nil
            if shared.usageOverdue { shared.usageOverdue = false }
        } else if shared.usageWait == nil {
            shared.usageWait = Task { [shared] in
                try? await Task.sleep(for: patience)
                if !Task.isCancelled { shared.usageOverdue = true }
            }
        }
        if shared.usageSupported != true { shared.usageSupported = true }
        if shared.usage != usage { shared.usage = usage }
    }
}
