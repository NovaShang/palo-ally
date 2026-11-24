import PaloAllyKit
import SwiftUI

/// The details of an agent, the assistant's and a Pal's on one page
/// (docs/workbench-design/details-v5.html): tiles. Who it is and how it
/// stands with its context round its indicator, the model and the depth it
/// thinks at, what it runs now, the pages and menus behind the small tiles,
/// and 归档 (an agent) or 停下 (the assistant). The data is one
/// `AgentDetail`; what one kind has and the other hasn't is its
/// `capabilities`, and a tile its host or harness can't fill isn't there.
struct DetailTiles: View {
    /// A Pal's id; nil: the assistant.
    let agent: String?
    /// How high it all is, for the popover (with `insets`) or the sheet round it.
    var onHeight: (_ content: CGFloat, _ insets: CGFloat) -> Void = { _, _ in }

    @Environment(\.tileDetail) private var tileDetail
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.detailOnGlass) private var onGlass
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var palDetail: PalDetail?
    /// The host doesn't have the details (an older one).
    @State private var untold = false
    @State private var failure: String?
    @State private var renaming = false
    @State private var working: String?
    /// The depth just picked, shown until the host's answer is in.
    @State private var pickedDepth: String??
    @State private var asking = false
    @State private var allTasks = false
    @State private var inTerminal: Pal?
    @State private var copiedTerminal = false
    /// How many files it remembers (nil: not known yet), and that its host keeps none for it.
    @State private var memoryCount: Int?
    @State private var noMemory = false
    /// The home indicator's, under the scroll.
    @State private var bottomInset: CGFloat = 0

    private var online: Bool { store.connection.isOnline }
    private var pal: Pal? { agent.flatMap { store.pal(id: $0) ?? palDetail?.pal } }
    private var caps: AgentDetail.Capabilities { agent == nil ? .assistant : .agent }
    /// Open in a terminal, or out of reach: nothing is sent to it.
    private var held: Bool { !online || pal?.openInTerminal == true }
    private var metrics: DetailMetrics { DetailMetrics(phone: phoneSized) }
    private var phoneSized: Bool {
        #if DEBUG
        // `-demoDetailPhone YES`: the phone's sizes on a Mac (snapshots).
        if UserDefaults.standard.bool(forKey: "demoDetailPhone") { return true }
        #endif
        return model.layout == .phone
    }

    private var inSheet: Bool { phoneSized && model.detailShown }

    private var detail: AgentDetail? {
        var d: AgentDetail?
        if agent == nil {
            d = store.assistantDetail
        } else if let palDetail {
            d = AgentDetail(palDetail, harness: store.harness)
        } else if let pal {
            d = untold ? AgentDetail(contextPct: pal.contextPct, capabilities: .agent) : AgentDetail(early: pal, harness: store.harness)
        }
        if let pickedDepth { d?.effort = pickedDepth }
        return d
    }

    /// Asked again when the host says the session changed (`pals.updated`).
    private var refreshKey: String {
        guard let pal else { return "\(online)" }
        return "\(online)|\(pal.updatedAt ?? 0)|\(pal.attention.rawValue)|\(pal.contextPct ?? -1)|\(pal.model ?? "")|\(pal.effort ?? "")|\(pal.permissionMode ?? "")"
    }

    var body: some View {
        ScrollView {
            tiles
                .padding([.horizontal, .top], metrics.padding)
                .padding(.top, inSheet ? 10 : 0)
                // The home indicator's room under 归档 is room enough.
                .padding(.bottom, inSheet ? max(2, metrics.padding - bottomInset) : metrics.padding)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.contentInsets.top + $0.contentInsets.bottom, height: $0.contentSize.height) } action: { _, s in
            onHeight(s.height, s.width)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { _, b in
            // (Not the keyboard.)
            if b < 60 { bottomInset = b }
        }
        .environment(\.detailMetrics, metrics)
        .navigationTitle("")
        .detailGround()
        .task(id: refreshKey) { await load() }
        .task(id: "\(online)|\(model.memoryRevision)") { await countMemory() }
        .navigationDestination(item: Binding(get: { model.detailPage }, set: { model.detailPage = $0 })) { page in
            DetailPageView(page: page, agent: agent, past: detail?.pastTasks ?? [])
                .environment(\.detailMetrics, metrics)
                .environment(\.detailOnGlass, onGlass)
        }
        .sheet(isPresented: Binding(get: { agent == nil && model.showIdentityEditor }, set: { model.showIdentityEditor = $0 })) {
            IdentityEditor(purpose: .edit).environment(model).environment(store)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .demoDetail)) { n in
            switch n.object as? String {
            case "detail-rename": renaming = agent != nil
            case "detail-ask": asking = true
            case "detail-more": allTasks = true
            default: break
            }
        }
        #endif
        .accessibilityIdentifier(agent == nil ? "management" : "agent-details")
    }

    @ViewBuilder private var tiles: some View {
        if agent == nil || pal != nil {
            VStack(spacing: DetailMetrics.gap) {
                top
                let running = detail?.tasks ?? []
                if !running.isEmpty, pal?.openInTerminal != true {
                    DetailTasksTile(tasks: running, all: $allTasks, canStop: caps.stopTasks && online,
                                    open: agent == nil ? { model.detailPage = .task($0.id) } : nil, stop: stop)
                }
                squares
                if let failure {
                    Text(Copy.spaced(failure))
                        .detailFont(metrics.line)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                end
            }
        }
    }

    // MARK: who it is, the model, the depth

    @ViewBuilder private var top: some View {
        let d = detail
        let model = untold ? nil : d
        let depth = d.flatMap { $0.efforts.isEmpty ? nil : $0 }
        if model == nil && depth == nil {
            hero
        } else if typeSize.isAccessibilitySize {
            VStack(spacing: DetailMetrics.gap) {
                hero
                if let model { modelTile(model) }
                if let depth { depthTile(depth) }
            }
        } else {
            HStack(spacing: DetailMetrics.gap) {
                hero.frame(maxWidth: .infinity)
                VStack(spacing: DetailMetrics.gap) {
                    if let model { modelTile(model) }
                    if let depth { depthTile(depth) }
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelTile(_ d: AgentDetail) -> some View {
        DetailModelTile(detail: d) { m in setModel(m, .none) }
            .disabled(!online)
    }

    private func depthTile(_ d: AgentDetail) -> some View {
        DetailDepthTile(detail: d) { e in setModel(.none, .some(e)) }
            .disabled(!online)
            .opacity(online ? 1 : 0.42)
    }

    private var hero: some View {
        let d = detail
        let canCompact = online && working == nil && (agent == nil ? !store.isBusy : pal?.status != .busy)
        return DetailHeroTile(
            name: pal?.displayName ?? store.assistantName, status: status,
            fill: d?.contextFill, tokens: d?.contextTokens, window: d?.contextWindow,
            compact: compactable ? { compact() } : nil, compacting: working == "compact", canCompact: canCompact, held: held,
            canRename: agent == nil || (online && store.harness.features.rename),
            rename: agent.map { id in { name in rename(id, name) } },
            edit: { model.showIdentityEditor = true }, renaming: $renaming
        ) { ring in
            // The drop's body about half of the ring, whichever it is.
            if let pal { SessionIndicator(pal, size: ring * 0.56) } else { TitleOrbDrop(size: ring * 0.68) }
        }
    }

    /// Its harness compacts; the assistant's is a command said to it.
    private var compactable: Bool {
        guard caps.compact, store.harness.features.compact, !untold else { return false }
        return agent != nil || store.harness.commandPrefix != nil
    }

    /// 「等你 · ~/code/site」; alone what stops it (offline, a limit, a
    /// terminal). The assistant's own line.
    private var status: String {
        if !online, store.connectionTrouble { return Copy.connectionShort(store.displayedConnection) }
        guard let pal else {
            let line = store.agentStatusLine
            return line.kind == .idle ? UsageText.assistantStopped(store) ?? line.text : line.text
        }
        if let stopped = UsageText.stopped(pal, model.store ?? store) { return stopped }
        let line = AgentStatusLine.of(pal)
        if pal.openInTerminal { return line.text }
        return "\(line.text) · \(CCSession.shortPath(pal.cwd))"
    }

    // MARK: the small tiles

    private var squares: some View {
        let d = detail ?? AgentDetail(capabilities: caps)
        let tiles = untold ? [] : d.tiles(memory: !noMemory && (agent == nil || store.harness.features.projectMemory), terminal: store.terminalSupported)
        return TileRow(columns: typeSize >= .xxxLarge ? 2 : 4) {
            ForEach(tiles, id: \.self) { square($0, d) }
        }
    }

    @ViewBuilder private func square(_ tile: AgentDetail.Tile, _ d: AgentDetail) -> some View {
        switch tile {
        case .goals:
            let waiting = store.watches.filter(\.needsOwner).count
            pageTile(.goals, "target", String(localized: "目标"), count: waiting, waiting: true)
                .accessibilityIdentifier("detail-timers")
        case .history:
            pageTile(.history, "clock", String(localized: "历史"), count: d.pastTasks.count)
                .accessibilityIdentifier("detail-past-tasks")
        case .memory:
            pageTile(.memory, "text.book.closed", String(localized: "记忆"), count: memoryCount ?? 0)
                .accessibilityIdentifier("detail-memory")
        case .settings:
            pageTile(.settings, "circle.lefthalf.filled", String(localized: "设置"))
                .accessibilityIdentifier("detail-settings")
        case .permissions:
            permissionTile(d)
        case .terminal:
            if let pal { terminalTile(pal) }
        }
    }

    private func pageTile(_ page: DetailPage, _ symbol: String, _ name: String, count: Int = 0, waiting: Bool = false) -> some View {
        Button { model.detailPage = page } label: {
            SquareTileLabel(symbol: symbol, name: name, count: count, waiting: waiting)
        }
        .buttonStyle(TileButtonStyle())
    }

    /// 权限: a menu of the modes; under the one chosen, the one it really
    /// runs in when that's another (auto needs a model that has it).
    private func permissionTile(_ d: AgentDetail) -> some View {
        Menu {
            ForEach(d.permissionModes, id: \.self) { mode in
                Toggle(isOn: Binding(get: { mode == d.permissionMode }, set: { on in if on { setMode(mode, from: d.permissionMode) } })) {
                    Text(d.harness.modeLabel(mode))
                    if mode == d.permissionMode, let running = d.runningMode {
                        Text("现在实际是「\(d.harness.modeLabel(running))」")
                    }
                }
            }
        } label: {
            SquareTileLabel(symbol: "checkmark.shield", name: String(localized: "权限"))
        }
        .menuStyle(.button)
        .buttonStyle(TileButtonStyle())
        .menuIndicator(.hidden)
        .disabled(!online || palDetail == nil)
        .accessibilityValue(d.harness.modeLabel(d.permissionMode))
        .accessibilityIdentifier("detail-permission-mode")
    }

    /// 终端: its session in a terminal on this Mac, or the line for it copied.
    private func terminalTile(_ pal: Pal) -> some View {
        let here = AgentTerminal.opensHere(store)
        return Button { inTerminal = pal } label: {
            SquareTileLabel(symbol: copiedTerminal ? "checkmark" : "apple.terminal",
                            name: copiedTerminal ? String(localized: "已复制") : String(localized: "终端"))
        }
        .buttonStyle(TileButtonStyle())
        .disabled(held)
        .accessibilityLabel(here ? Text("在终端打开") : Text("复制终端命令"))
        .accessibilityIdentifier("detail-terminal")
        .agentTerminal($inTerminal) { copiedTerminal = true }
        .task(id: copiedTerminal) {
            guard copiedTerminal else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedTerminal = false
        }
    }

    // MARK: 归档, 停下

    private var name: String { pal?.displayName ?? store.assistantName }

    @ViewBuilder private var end: some View {
        if asking {
            VStack(spacing: 10) {
                Text(Copy.spaced(caps.archive ? String(localized: "归档「\(name)」？") : String(localized: "让 \(name) 停下？")))
                    .detailFont(metrics.row, .bold)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    askButton(String(localized: "算了"), prominent: false) { withAnimation(.snappy) { asking = false } }
                        .accessibilityIdentifier("detail-ask-cancel")
                    askButton(caps.archive ? String(localized: "归档") : String(localized: "停下"), prominent: true) { caps.archive ? archive() : stopAssistant() }
                        .accessibilityIdentifier("detail-ask-confirm")
                }
                .disabled(working != nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .detailTile()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-ask")
        } else {
            let can = online && (caps.archive || store.assistantWorking)
            Button { withAnimation(.snappy) { asking = true } } label: {
                Text(caps.archive ? String(localized: "归档") : String(localized: "停下"))
                    .detailFont(metrics.row, .semibold)
                    .foregroundStyle(Color(rgb: 0xFF453A))
            }
            .buttonStyle(EndButtonStyle())
            .disabled(!can)
            .accessibilityIdentifier(caps.archive ? "detail-end" : "detail-stop")
        }
    }

    private func askButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .detailFont(metrics.row, .semibold)
                .foregroundStyle(prominent ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: metrics.askButton)
                .background(prominent ? Color(rgb: 0xFF3B30) : DetailColors.track, in: .capsule)
        }
        .buttonStyle(TileInnerButtonStyle())
    }

    // MARK: actions

    private func load() async {
        guard online else { return }
        guard let agent else {
            if store.modelInfo == nil { try? await store.loadModels() }
            return
        }
        do {
            palDetail = try await store.palDetail(id: agent)
            untold = false
            failure = nil
        } catch RPCError.remote(let m) where m.contains("unknown method") {
            // A host from before the details: what it can't tell isn't there.
            untold = palDetail == nil
        } catch {
            if palDetail == nil { failure = Copy.error(error) }
        }
    }

    private func countMemory() async {
        guard online else { return }
        do {
            memoryCount = try await store.memoryFiles(agent: agent).filter { !$0.missing }.count
            noMemory = false
        } catch RPCError.remote {
            noMemory = agent != nil && memoryCount == nil
        } catch {}
    }

    private func run(_ key: String, _ op: @escaping () async throws -> Void) {
        guard working == nil else { return }
        working = key
        failure = nil
        Task {
            defer { working = nil }
            do { try await op() } catch { failure = Copy.error(error) }
        }
    }

    private func rename(_ id: String, _ name: String) {
        run("rename") {
            do { _ = try await store.renamePal(id: id, name: name) } catch {
                throw FriendlyFailure(message: String(localized: "没改成：\(Copy.error(error))"))
            }
        }
    }

    /// The one setter (the assistant's model.set or an agent's pals.setModel).
    private func setModel(_ m: String??, _ e: String??) {
        guard working == nil else { return }
        pickedDepth = e
        run("model") {
            defer { pickedDepth = .none }
            try await store.setAgentModel(agent, model: m, effort: e)
            if let agent { palDetail = try await store.palDetail(id: agent) }
        }
    }

    /// Its permission mode; the one it's in already does nothing.
    private func setMode(_ mode: String, from current: String?) {
        guard mode != current, let agent else { return }
        run("mode") {
            try await store.setSessionMode(id: agent, mode: mode)
            palDetail = try await store.palDetail(id: agent)
        }
    }

    private func compact() {
        guard let agent else { return store.compactAssistant() }
        run("compact") {
            try await store.compactSession(id: agent)
            palDetail = try? await store.palDetail(id: agent)
        }
    }

    private func stop(_ t: AgentTask) {
        run("stop") {
            if let agent {
                try await store.stopTask(id: agent, taskId: t.id)
                palDetail = try? await store.palDetail(id: agent)
            } else {
                try await store.stopTask(id: t.id)
            }
        }
    }

    private func archive() {
        guard let agent else { return }
        run("end") {
            try await store.endSession(id: agent)
            model.setDetail(false, tile: tileDetail)
            // On its own page it is gone; in a tile the workspace carries on.
            if tileDetail == nil { model.showList() }
        }
    }

    private func stopAssistant() {
        run("stop") {
            do { try await store.stop() } catch { throw FriendlyFailure(message: String(localized: "没成功：\(Friendly.message(error))")) }
            asking = false
        }
    }
}

/// An error whose words are already the owner's.
struct FriendlyFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The red words at the bottom: a faint red under the pointer.
private struct EndButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration) }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Color(rgb: 0xFF453A).opacity(enabled && (hovered || configuration.isPressed) ? 0.12 : 0), in: .capsule)
                .contentShape(.capsule)
                .opacity(enabled ? 1 : 0.42)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.15), value: hovered)
                .padding(.top, 2)
        }
    }
}

#if DEBUG
/// `-demoDetailType YES`: the largest text (a Mac has no setting for it; snapshots).
struct DemoTypeSize: ViewModifier {
    func body(content: Content) -> some View {
        if UserDefaults.standard.bool(forKey: "demoDetailType") { content.dynamicTypeSize(.accessibility5) } else { content }
    }
}

extension Notification.Name {
    /// Demo actions `detail-rename`, `detail-ask`, `detail-more` (RootView).
    static let demoDetail = Notification.Name("palo.demo.detail")
}
#endif
