import Foundation

/// How much of the plan of this computer's login is used (Claude 用量): kept
/// by the host, which says when it changes (`usage.updated`).
extension AppStore {
    /// nil until the host has answered.
    public var usage: UsageStatus? { shared.usage }

    /// false for a host from before usage.get; nil until asked.
    public var usageSupported: Bool? { shared.usageSupported }

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

    func apply(usage: UsageStatus?) {
        guard let usage else { return }
        if shared.usageSupported != true { shared.usageSupported = true }
        if shared.usage != usage { shared.usage = usage }
    }
}
