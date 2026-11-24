import PaloAllyKit
import SwiftUI

/// 「Claude 用量」 (docs/workbench-design/usage.html §2): what's left of each
/// limit of the plan, when it resets and whether it lasts, as the computer
/// says; under it the account the agents run on. Login expired: that first,
/// with the way back. Several accounts: one after the other, the tightest
/// first; the same one on several computers, once.
struct UsagePage: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// The computer being signed in again.
    @State private var signingIn: SignIn?
    /// Every agent that stopped is listed, not the first few.
    @State private var allStopped = false

    private struct SignIn: Identifiable { let id: String }

    /// As wide as 设置, whatever the window: a bar across all of it doesn't read.
    private static let widest: CGFloat = 664

    var body: some View {
        let title = String(localized: "\(store.harness.login.account) 用量")
        TimelineView(.everyMinute) { t in
            List { content(now: t.date) }
                .listStyle(.insetGrouped)
                // The same background from the title down, whatever is listed.
                .scrollContentBackground(.hidden)
                // (by its frame: a section's own margins lose the leading one, under the sidebar)
                .frame(maxWidth: model.layout == .phone ? .infinity : Self.widest + 40)
                .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .macPageTop(title, inRow: true, background: Color(.systemGroupedBackground))
        .refreshable { await load() }
        // While it's open, every minute.
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .sheet(item: $signingIn) { who in
            if let s = model.stores[who.id] { ClaudeLoginSheet().environment(s) }
        }
        .accessibilityIdentifier("usage-page")
    }

    private func load() async {
        for s in model.stores.values where s.usageSupported != false && s.connection.isOnline { await s.loadUsage(refresh: true) }
    }

    // MARK: the page

    private var hosts: [(host: String, usage: UsageStatus)] {
        model.app.sidebarHostIDs.compactMap { id in
            guard let s = model.stores[id], s.usageSupported == true, let u = s.usage else { return nil }
            return (id, u)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let groups = UsageGroup.grouped(hosts, now: now)
        ForEach(groups, id: \.hosts) { g in
            let apart = groups.count > 1
            notices(g, named: apart || g.hosts.count > 1, now: now)
                // (as much room above it as above a section's header)
                .listSectionMargins(.top, g.hosts == groups.first?.hosts && Platform.isMac ? 10 : nil)
            limits(g, apart: apart, now: now)
            ForEach(g.hosts, id: \.self) { account(g, host: $0, apart: apart) }
        }
    }

    private func expired(_ id: String) -> Bool { model.stores[id]?.status?.auth?.isExpired == true }
    private func name(_ ids: [String]) -> String { ids.map(model.displayName).joined(separator: "、") }
    private func assistant(_ id: String) -> String {
        let n = model.stores[id]?.assistantName ?? ""
        return n.isEmpty ? "Palo" : n
    }

    // MARK: what there is to say first

    @ViewBuilder private func notices(_ g: UsageGroup, named: Bool, now: Date) -> some View {
        ForEach(g.hosts.filter(expired), id: \.self) { id in
            Section {
                Notice(title: named ? "\(model.displayName(id)) · \(String(localized: "登录过期了"))" : String(localized: "登录过期了"), text: stopped(id)) {
                    if let l = model.stores[id]?.harness.login, l.fromPhone, l.kind == "oauth-code" {
                        Button { signingIn = SignIn(id: id) } label: { Text("重新登录").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .buttonBorderShape(.capsule)
                            .disabled(!model.isOnline(id))
                            .accessibilityIdentifier("usage-sign-in")
                    }
                }
            }
        }
        if !g.hosts.contains(where: expired), g.usage.state == .limits {
            let at = g.usage.at.map(Copy.clock) ?? ""
            if !g.hosts.contains(where: model.isOnline) {
                Section { Notice(title: String(localized: "连不上主机"), text: UsageText.tidy(String(localized: "下面是 \(at) 的数，连上就更新。"))) }
            } else if g.usage.stale {
                Section { Notice(title: String(localized: "没拿到新的数"), text: UsageText.tidy(String(localized: "下面是 \(at) 的数。"))) }
            } else if let l = usedUp(g.usage, now: now) {
                let extra = g.usage.extraUsage == true
                hit(g, title: hitTitle(l, extra: extra, now: now), note: hitText(l, extra: extra), now: now)
            }
        }
        // Stopped, and no numbers that say by what.
        if !g.hosts.contains(where: expired), g.hosts.contains(where: model.isOnline), usedUp(g.usage, now: now) == nil || g.usage.state != .limits || g.usage.stale,
           g.hosts.contains(where: { model.stores[$0]?.usage?.stopped != nil }) {
            hit(g, title: String(localized: "额度用完了"), note: nil, now: now)
        }
    }

    private func stopped(_ id: String) -> String {
        let who = assistant(id)
        let auth = model.stores[id]?.status?.auth
        // How many were cut off, when the host says.
        let n = auth?.stopped?.agents.count ?? 0
        let agents = n > 0 ? String(localized: "\(n) 个 agent") : "agent"
        guard let since = auth?.since, since > 0 else {
            return Copy.spaced(String(localized: "\(who)、\(agents)和定时安排都停着。登录好后会接着做。"))
        }
        return UsageText.tidy(String(localized: "\(who)、\(agents)和定时安排 \(Copy.clock(since)) 起都停着。登录好后会接着做。"))
    }

    /// The limit that stops things: one for everything before one for a model.
    private func usedUp(_ u: UsageStatus, now: Date) -> UsageLimit? {
        let up = u.limits.filter { $0.isUsedUp && !$0.hasReset(now) }
        return up.first { $0.scope == nil } ?? up.first
    }

    private func hitTitle(_ l: UsageLimit, extra: Bool, now: Date) -> String {
        let name = UsageText.name(l)
        if extra { return Copy.spaced(String(localized: "\(name)额度用完了，现在按量计费")) }
        guard let at = l.resetsAt else { return Copy.spaced(String(localized: "\(name)额度用完了")) }
        return UsageText.tidy(String(localized: "\(name)额度用完了，\(UsageText.when(at, now: now)) 恢复"))
    }

    private func hitText(_ l: UsageLimit, extra: Bool) -> String? {
        guard !extra, let scope = l.scope else { return nil }
        return Copy.spaced(String(localized: "只影响 \(scope)，别的模型还能用"))
    }

    /// The limit's card: what it is, who stopped for it, and each of them (a tap opens it).
    @ViewBuilder private func hit(_ g: UsageGroup, title: String, note: String?, now: Date) -> some View {
        let stopped = g.hosts.flatMap { id in (model.stores[id]?.usage?.stopped?.agents ?? []).map { (host: id, agent: $0) } }
        let assistants = g.hosts.filter { model.stores[$0]?.usage?.stopped?.assistant == true }
        let shown = allStopped ? stopped : Array(stopped.prefix(Self.few))
        let lines = [note, stoppedText(assistants, agents: stopped.count)].compactMap { $0 }
        Section {
            Notice(title: title, text: lines.isEmpty ? nil : lines.joined(separator: String(localized: "。")))
                .listRowSeparator(stopped.isEmpty ? .automatic : .hidden, edges: .bottom)
            ForEach(shown, id: \.agent.id) { s in
                Button { model.open(.pal(s.agent.id), on: s.host) } label: {
                    StoppedRow(agent: s.agent, host: g.hosts.count > 1 ? model.displayName(s.host) : nil, now: now)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage-stopped-\(s.agent.id)")
            }
            if stopped.count > shown.count {
                Button { withAnimation(.snappy) { allStopped = true } } label: {
                    Text("还有 \(stopped.count - shown.count) 个").foregroundStyle(.primary)
                }
                .tint(.primary)
            }
        }
    }

    /// How many of them are listed at first.
    private static let few = 6

    private func stoppedText(_ assistants: [String], agents: Int) -> String? {
        let who = assistants.map(assistant).joined(separator: "、")
        return switch (assistants.isEmpty, agents) {
        case (true, 0): nil
        case (true, _): Copy.spaced(String(localized: "\(agents) 个 agent 停在这里，到点自己接着做。"))
        case (false, 0): Copy.spaced(String(localized: "\(who)停在这里，到点自己接着做。"))
        case (false, _): Copy.spaced(String(localized: "\(who)和 \(agents) 个 agent 停在这里，到点自己接着做。"))
        }
    }

    // MARK: the limits

    @ViewBuilder private func limits(_ g: UsageGroup, apart: Bool, now: Date) -> some View {
        let u = g.usage
        let expired = g.hosts.contains(where: expired)
        let old = expired || u.stale || !g.hosts.contains(where: model.isOnline)
        let late = g.hosts.contains { model.stores[$0]?.usageOverdue == true }
        switch u.state {
        case .limits where !u.limits.isEmpty:
            Section {
                ForEach(Array(u.limits.enumerated()), id: \.offset) { i, l in
                    let repeated = u.limits[..<i].contains { $0.resetsAt == l.resetsAt }
                    LimitRow(limit: l, old: old, spans: !repeated, now: now)
                }
                // Near the end: what happens then (used up, the title says what did).
                if !old, let extra = u.extraUsage, usedUp(u, now: now) == nil,
                   u.limits.contains(where: { $0.tone != .normal && !$0.hasReset(now) }) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("额外用量")
                            Spacer(minLength: 12)
                            extraText(extra)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("额外用量")
                            extraText(extra)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                header(g, apart: apart)
            } footer: {
                Text(foot(g, old: old, expired: expired))
            }
        case .loading:
            Section {
                if late {
                    Text("还没读到").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: { header(g, apart: apart) }
        case .noLimits:
            Section { Text("这种登录按量计费，没有套餐额度") } header: { header(g, apart: apart) }
        case .hidden:
            Section { Text("这次登录看不到额度，重新登录试试") } header: { header(g, apart: apart) }
        default:
            EmptyView()
        }
    }

    private func extraText(_ on: Bool) -> Text {
        Text(on ? String(localized: "开着，用完后按量计费") : String(localized: "没开，用完会停下"))
    }

    @ViewBuilder private func header(_ g: UsageGroup, apart: Bool) -> some View {
        if apart { HostName(ids: g.hosts) } else { Text("还剩多少").textCase(nil) }
    }

    private func foot(_ g: UsageGroup, old: Bool, expired: Bool) -> String {
        let at = g.usage.at
        if old { return expired && at != nil ? UsageText.tidy(String(localized: "\(Copy.clock(at ?? 0)) 的数。")) : "" }
        let line = String(localized: "条上的细线是时间走到哪儿了。")
        if g.hosts.count > 1 {
            let same = g.hosts.count == 2 ? String(localized: "两台主机用同一个账号，额度合在一起。") : String(localized: "这些主机用同一个账号，额度合在一起。")
            return line + same
        }
        guard let at else { return line }
        if Date().epochMillis - at < 60_000 { return line + String(localized: "刚刚更新。") }
        return line + String(localized: "\(Copy.relative(at))更新。")
    }

    // MARK: the account

    @ViewBuilder private func account(_ g: UsageGroup, host id: String, apart: Bool) -> some View {
        let s = model.stores[id]
        // Each computer's own (one account on several: what it's called is the same, what's said of it not).
        let u = s?.usage ?? g.usage
        let brand = s?.harness.login.account ?? ""
        let late = s?.usageOverdue == true
        if u.account != nil || (u.state == .loading && !late) {
            Section {
                AccountRow(account: u.account, brand: brand, expired: expired(id))
            } header: {
                if !apart {
                    if g.hosts.count > 1 { HostName(ids: [id]) } else { Text("账号").textCase(nil) }
                }
            } footer: {
                Text(accountFoot(u.account, host: id, named: apart))
            }
        }
    }

    private func accountFoot(_ a: LoginAccount?, host id: String, named: Bool) -> String {
        if a?.provider != nil { return "" }
        if a?.apiKeySource != nil {
            let brand = model.stores[id]?.harness.login.account ?? ""
            return Copy.spaced(String(localized: "密钥在电脑上改。设着密钥时，登录 \(brand) 账号不起作用。"))
        }
        if expired(id) { return String(localized: "换成另一个账号也可以，授权时选它就行。") }
        let who = assistant(id)
        return Copy.spaced(named ? String(localized: "「\(model.displayName(id))」上的\(who)和 agent 用这个登录。")
            : String(localized: "\(who)和所有 agent 都用这个登录。"))
    }
}

/// A computer's name over its part, its dot as in the sidebar.
private struct HostName: View {
    @Environment(WindowModel.self) private var model
    let ids: [String]

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ids.contains(where: model.isOnline) ? StatusDot.color(.done) : Color(uiColor: .systemGray3))
                .frame(width: 7, height: 7)
            Text(verbatim: ids.map(model.displayName).joined(separator: "、"))
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// How things stand, and the way on: a title, a line, a button.
private struct Notice<Action: View>: View {
    let title: String
    var text: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let text { Text(text).font(.subheadline).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(.vertical, 15)
    }
}

extension Notice where Action == EmptyView {
    init(title: String, text: String?) {
        self.init(title: title, text: text) { EmptyView() }
    }
}

/// An agent that stopped for a limit, and when it goes on.
private struct StoppedRow: View {
    let agent: StoppedWork.Agent
    /// Whose it is, with several computers.
    let host: String?
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            SessionIndicator(glyph: .idle, size: 22)
                .frame(width: Platform.isMac ? 20 : 24)
            Text(verbatim: agent.name).lineLimit(1).truncationMode(.tail)
            if let host { Text(verbatim: host).font(Platform.isMac ? .subheadline : .footnote).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 12)
            if let until = agent.until {
                Text(UsageText.tidy(String(localized: "\(UsageText.when(until, now: now)) 接着做")))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// One limit: its name and what's left; how much is used, with where its
/// window's time is; when it resets, and whether it lasts.
private struct LimitRow: View {
    let limit: UsageLimit
    /// Numbers from before: what's left in gray, no time, nothing said of what's to come.
    let old: Bool
    /// Says how long until it resets.
    let spans: Bool
    let now: Date
    @Environment(WindowModel.self) private var model

    var body: some View {
        let reset = UsageText.reset(limit, now: now, left: spans && !old)
        let pace = old ? nil : UsageText.pace(limit, now: now)
        VStack(alignment: .leading, spacing: Platform.isMac ? 9 : 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageText.title(limit))
                Spacer(minLength: 12)
                Text(value)
                    .fontWeight(old ? .medium : .semibold)
                    .monospacedDigit()
                    .foregroundStyle(old ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            UsageBar(limit: limit, elapsed: old || limit.isUsedUp ? nil : limit.elapsed(now), reset: limit.hasReset(now), dim: old)
            if reset != nil || pace != nil {
                let stacked = VStack(alignment: .leading, spacing: 2) {
                    line(reset, pace: false)
                    line(pace, pace: true)
                }
                // Phones: stacked on every row (some would fit on one line, and look uneven).
                Group {
                    if model.layout == .phone {
                        stacked
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) {
                                line(reset, pace: false)
                                Spacer(minLength: 0)
                                line(pace, pace: true)
                            }
                            stacked
                        }
                    }
                }
                .font(Platform.isMac ? .subheadline : .footnote)
            }
        }
        .listRowInsets(.vertical, Platform.isMac ? 13 : 15)
        .accessibilityElement(children: .combine)
    }

    private var value: String {
        if limit.hasReset(now) { return String(localized: "已重置") }
        if limit.isUsedUp { return String(localized: "用完了") }
        let left = "\(limit.left)%"
        return String(localized: "剩 \(left)")
    }

    @ViewBuilder private func line(_ text: String?, pace: Bool) -> some View {
        if let text {
            Text(text)
                .foregroundStyle(pace ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }
}

/// How much of a limit is used, filled from the left like the context's bar;
/// the thin line is where its window's time is.
private struct UsageBar: View {
    let limit: UsageLimit
    let elapsed: Double?
    let reset: Bool
    let dim: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink: Color = scheme == .dark ? .white : .black
        Capsule()
            .fill(ink.opacity(scheme == .dark ? 0.12 : 0.09))
            .overlay {
                GeometryReader { g in
                    if !reset {
                        Capsule()
                            .fill(UsageText.tint(limit) ?? ink.opacity(scheme == .dark ? 0.52 : 0.31))
                            .opacity(dim ? 0.6 : 1)
                            .frame(width: limit.used > 0 ? max(6, g.size.width * Double(limit.used) / 100) : 0)
                    }
                    if let elapsed {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(ink.opacity(scheme == .dark ? 0.75 : 0.62))
                            .frame(width: 2, height: 12)
                            .background {
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(Color(.secondarySystemGroupedBackground))
                                    .padding(-1.5)
                            }
                            .position(x: g.size.width * elapsed, y: g.size.height / 2)
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}

/// Whose login: the email and the plan (or the key, or the provider).
private struct AccountRow: View {
    let account: LoginAccount?
    let brand: String
    let expired: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: keyed ? "key.horizontal" : "person")
                .font(.system(size: keyed ? 13 : 16))
                .foregroundStyle(.secondary)
                .frame(width: Platform.isMac ? 20 : 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                if let caption {
                    Text(verbatim: caption)
                        .font(Platform.isMac ? .subheadline : .footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var keyed: Bool { account?.apiKeySource != nil || account?.provider != nil }

    private var title: String {
        guard let account else { return String(localized: "正在读取…") }
        if keyed { return UsageText.keyed(account) }
        return account.email ?? account.organization ?? account.planName(brand) ?? brand
    }

    private var caption: String? {
        guard let account else { return brand }
        if account.provider != nil { return nil }
        if let source = account.apiKeySource { return source.hasSuffix("_KEY") ? String(localized: "电脑上设的 \(source)") : nil }
        let plan = account.planName(brand) ?? brand
        return expired ? "\(plan) · \(String(localized: "已过期"))" : plan
    }
}
