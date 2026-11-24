import PaloAllyKit
import SwiftUI

/// What the sidebar's row says: the limit met first, of every computer's
/// account (one on several computers counts once).
struct UsageSummary {
    enum Icon { case ring(UsageLimit?), expired, key }
    var icon: Icon
    var line: String

    /// nil: no computer answers usage.get (an older host): no row.
    @MainActor static func of(_ model: WindowModel, now: Date) -> UsageSummary? {
        let hosts = model.app.sidebarHostIDs.compactMap { id -> (host: String, usage: UsageStatus)? in
            guard let s = model.stores[id], s.usageSupported == true, let u = s.usage else { return nil }
            return (id, u)
        }
        let groups = UsageGroup.grouped(hosts, now: now)
        guard let first = groups.first else { return nil }
        // Several accounts: whose it is.
        func said(_ line: String, _ ids: [String]) -> String {
            groups.count > 1 ? "\(ids.map(model.displayName).joined(separator: "、")) · \(line)" : line
        }
        if let id = hosts.map(\.host).first(where: { model.stores[$0]?.status?.auth?.isExpired == true }) {
            return UsageSummary(icon: .expired, line: said(String(localized: "登录过期"), [id]))
        }
        let u = first.usage
        let old = u.stale || !first.hosts.contains(where: model.isOnline)
        switch u.state {
        case .limits:
            guard let l = u.tightest(now) else { break }
            let line = UsageText.line(l, now: now)
            return UsageSummary(icon: .ring(l),
                                line: said(old && u.at != nil ? "\(line) · \(Copy.relative(u.at ?? 0))" : line, first.hosts))
        case .loading:
            let late = first.hosts.contains { model.stores[$0]?.usageOverdue == true }
            return UsageSummary(icon: .ring(nil), line: said(late ? String(localized: "还没读到") : String(localized: "正在读取…"), first.hosts))
        case .noLimits:
            return UsageSummary(icon: .key, line: said(UsageText.keyed(u.account), first.hosts))
        case .hidden, .unsupported, .unknown:
            break
        }
        // No numbers: the plan.
        let brand = first.hosts.first.flatMap { model.stores[$0]?.harness.login.account } ?? ""
        return UsageSummary(icon: .ring(nil), line: said(u.account?.planName(brand) ?? "", first.hosts))
    }
}

/// 「Claude 用量」, over 主机与设备: a row like it, its second line what's left.
struct UsageListRow: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        TimelineView(.everyMinute) { t in
            let s = UsageSummary.of(model, now: t.date) ?? UsageSummary(icon: .ring(nil), line: "")
            SidebarRowLayout {
                icon(s.icon)
            } title: {
                Text("\(store.harness.login.account) 用量")
            } subtitle: {
                Text(s.line)
            } trailing: {
                EmptyView()
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func icon(_ i: UsageSummary.Icon) -> some View {
        switch i {
        case .ring(let l): UsageRing(limit: l)
        case .expired: Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, StatusDot.color(.waiting)).font(.system(size: 16))
        case .key: Image(systemName: "key.horizontal").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

/// How much of a limit is used, as a ring: gray, orange from 80%, red from 95%.
struct UsageRing: View {
    let limit: UsageLimit?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let line: CGFloat = 3.3
        // (the sidebar draws `primary` at 85%, a ring too light beside the rows' glyphs)
        let ink: Color = scheme == .dark ? .white : .black
        ZStack {
            Circle().inset(by: line / 2).stroke(ink.opacity(0.18), lineWidth: line)
            if let limit, limit.used > 0 {
                Circle().inset(by: line / 2)
                    .trim(from: 0, to: Double(limit.used) / 100)
                    .stroke(UsageText.tint(limit) ?? ink.opacity(0.62), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 18.7, height: 18.7)
        .accessibilityHidden(true)
    }
}
