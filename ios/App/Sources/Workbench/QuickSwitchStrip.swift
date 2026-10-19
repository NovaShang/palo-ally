import PaloAllyKit
import SwiftUI

/// The phone's quick-switch strip, above the composer (a port of Bento's
/// pane tab bar): one glass chip per conversation, no icons. The glass is
/// tinted by state (blue 在干, amber 等你, green 做完了, plain 闲着); the
/// current chip has a white outline and semibold text.
///
/// Gestures: tap selects. A horizontal swipe ON THE STRIP goes to the
/// previous or next chip. To keep the two from fighting, the strip does not
/// scroll by hand: it is moved by selection only, always keeping the current
/// chip centered. So a swipe never competes with a scroll view's pan, and any
/// chip off screen is reached by swiping towards it. Nothing is added to the
/// chat area.
///
/// Members: the current session's workspace members, else Palo and the
/// unfolded sessions in sidebar order (`QuickSwitch.members`).
struct QuickSwitchStrip: View {
    let current: QuickSwitch.Member
    let onSelect: (QuickSwitch.Member) -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var renaming: Pal?
    @State private var ending: Pal?

    var body: some View {
        let members = QuickSwitch.members(current: current, pals: store.pals, workspaces: store.workspaces,
                                         sessionOrder: store.sessionOrder)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(members, id: \.self) { m in
                            chip(m).id(m)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 4)
            }
            .scrollDisabled(true)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, c in
                withAnimation(.snappy) { proxy.scrollTo(c, anchor: .center) }
            }
            .onChange(of: members) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .mask(edgeFade)
        .simultaneousGesture(swipe(members))
        .palRename($renaming)
        .confirmationDialog(Copy.spaced(String(localized: "结束「\(ending?.displayName ?? "")」？")),
                            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            titleVisibility: .visible) {
            Button("结束会话", role: .destructive) {
                if let p = ending { Task { await end(p, members: members) } }
            }
        } message: {
            Text("它会停下，进到「以前的」里，之后还能接着聊。")
        }
    }

    // MARK: chips

    private func chip(_ m: QuickSwitch.Member) -> some View {
        let state = self.state(m)
        let isCurrent = m == current
        return Button { onSelect(m) } label: {
            Text(title(m))
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .glassEffect(Self.glass(state, current: isCurrent), in: .capsule)
        .overlay {
            if isCurrent { Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.5) }
        }
        .contextMenu { if let pal = pal(m) { menu(pal) } }
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// Plain glass for 闲着; tinted glass otherwise, a little stronger on the current chip.
    static func glass(_ state: StatusDotKind, current: Bool) -> Glass {
        guard let c = tint(state) else { return .regular }
        return .regular.tint(c.opacity(current ? 0.4 : 0.25))
    }

    /// The state colors of the indicator design: blue, amber, green.
    static func tint(_ state: StatusDotKind) -> Color? {
        switch state {
        case .working: Color(red: 0x0A / 255, green: 0x85 / 255, blue: 0xFF / 255)
        case .waiting: Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
        case .done: Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
        case .idle: nil
        }
    }

    private func pal(_ m: QuickSwitch.Member) -> Pal? { m.sessionID.flatMap { store.pal(id: $0) } }

    private func title(_ m: QuickSwitch.Member) -> String {
        switch m {
        case .palo: store.assistantName.isEmpty ? "Palo" : store.assistantName
        case .session: pal(m)?.displayName ?? "…"
        }
    }

    private func state(_ m: QuickSwitch.Member) -> StatusDotKind {
        switch m {
        case .session: pal(m)?.dot ?? .idle
        case .palo:
            switch store.agentStatusLine.kind {
            case .needsYou: .waiting
            case .working, .tasks: .working
            case .offline, .idle: .idle
            }
        }
    }

    // MARK: swipe

    /// Left swipe: next. Right swipe: previous. Mostly horizontal only, so
    /// a vertical drag that starts on the strip does nothing.
    private func swipe(_ members: [QuickSwitch.Member]) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 40, abs(dx) > abs(dy) * 1.5 else { return }
                if let next = QuickSwitch.neighbor(of: current, step: dx < 0 ? 1 : -1, in: members) {
                    onSelect(next)
                }
            }
    }

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
        }
    }

    // MARK: long press

    @ViewBuilder private func menu(_ pal: Pal) -> some View {
        Button("重命名", systemImage: "pencil") { renaming = pal }
            .disabled(!store.connection.isOnline)
        if store.workspacesSupported == true {
            Menu("移到工作区", systemImage: "square.grid.2x2") {
                ForEach(store.workspaces.filter { $0.id != pal.workspaceId }) { w in
                    Button(w.title(pals: store.pals)) { Task { try? await store.moveSession(pal.id, to: w.id) } }
                }
                Button("新建工作区…") { model.newWorkspace = [pal.id] }
            }
            .disabled(!store.connection.isOnline)
            if pal.workspaceId != nil {
                Button("移出工作区", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { try? await store.moveSession(pal.id, to: nil) }
                }
                .disabled(!store.connection.isOnline)
            }
        }
        Divider()
        Button("结束会话", systemImage: "stop.circle", role: .destructive) { ending = pal }
            .disabled(!store.connection.isOnline)
    }

    private func end(_ p: Pal, members: [QuickSwitch.Member]) async {
        let me = QuickSwitch.Member.session(p.id)
        let next = QuickSwitch.landing(after: me, in: members)
        _ = try? await store.endSession(id: p.id)
        // Ending the page being shown: go to a neighbor.
        if me == current { onSelect(next) }
    }
}

#if DEBUG
#Preview("Quick switch strip") {
    let model = AppModel.demo()
    let pals = model.store!.pals
    VStack {
        Spacer()
        QuickSwitchStrip(current: pals.first.map { .session($0.id) } ?? .palo) { _ in }
    }
    .environment(model)
    .environment(model.store!)
}
#endif
