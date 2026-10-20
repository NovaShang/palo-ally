import PaloAllyKit
import SwiftUI

/// The phone's quick-switch strip, above the composer of a session that is
/// in a workspace (docs/workbench-design/quick-switch.html): one glass chip
/// per session of the workspace, no icons. The glass is tinted by state, in
/// the indicator's colors (blue 在干, amber 等你, green 做完了, plain 闲着);
/// the current chip's glass is strongly tinted (gray when 闲着) and its words
/// are in full, the others faint and dimmed; every chip keeps one size.
///
/// Gestures: tap selects. A horizontal swipe ON THE STRIP goes to the
/// previous or next chip. To keep the two from fighting, the strip does not
/// scroll by hand: it is moved by selection only, keeping the current chip
/// in the middle. So a swipe never competes with a scroll view's pan, and a
/// chip off screen is reached by swiping towards it. Nothing is added to the
/// conversation.
struct QuickSwitchStrip: View {
    let current: String
    /// The workspace's sessions (`QuickSwitch.members`), two or more.
    let members: [String]

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var renaming: Pal?
    @State private var ending: Pal?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Spacing 0: chips never melt into each other, even the
                // current one, which is drawn a little bigger.
                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: 10) {
                        ForEach(members, id: \.self) { id in
                            chip(id).id(id)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, (QuickSwitchSlot.height - 32) / 2)
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
        .simultaneousGesture(swipe)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-switch")
        .palRename($renaming)
        .confirmationDialog(Copy.spaced(String(localized: "结束「\(ending?.displayName ?? "")」？")),
                            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            titleVisibility: .visible) {
            Button("结束会话", role: .destructive) {
                if let p = ending { Task { await end(p) } }
            }
        } message: {
            Text("它会停下，之后还能从历史记录里接着聊。")
        }
    }

    // MARK: chips

    private func chip(_ id: String) -> some View {
        let pal = store.pal(id: id)
        let state = pal?.dot ?? .idle
        let isCurrent = id == current
        return Button { if !isCurrent { go(to: id) } } label: {
            // One weight for every chip, so a chip keeps its width (and the
            // strip its spacing) whichever one is current.
            Text(pal?.displayName ?? "…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .glassEffect(Self.glass(state, current: isCurrent), in: .capsule)
        .animation(.snappy, value: isCurrent)
        .contextMenu { if let pal { menu(pal) } }
        .accessibilityLabel(Text(verbatim: "\(pal?.displayName ?? ""), \(StatusDot.label(state))"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("quick-switch-\(id)")
    }

    /// The current chip: its state's color, strong (闲着: a gray), its words
    /// in full. The others: the color faint (闲着: plain glass), their
    /// words dimmed. Same size either way.
    static func glass(_ state: StatusDotKind, current: Bool) -> Glass {
        if current { return .regular.tint(StatusDot.color(state).opacity(state == .idle ? 0.35 : 0.6)) }
        guard state != .idle else { return .regular }
        return .regular.tint(StatusDot.color(state).opacity(0.18))
    }

    // MARK: swipe

    /// Left swipe: next. Right swipe: previous. Mostly horizontal only, so
    /// a vertical drag that starts on the strip does nothing.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 40, abs(dx) > abs(dy) * 1.5 else { return }
                if let next = QuickSwitch.neighbor(of: current, step: dx < 0 ? 1 : -1, in: members) {
                    go(to: next)
                }
            }
    }

    /// Switches with the pages sliding: the next one in from the right, the
    /// previous one from the left, as the strip's order goes.
    private func go(to id: String) {
        let from = members.firstIndex(of: current) ?? 0, to = members.firstIndex(of: id) ?? 0
        model.quickSwitchForward = to >= from
        withAnimation(.snappy(duration: 0.32)) { model.openPal(id) }
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

    private func end(_ p: Pal) async {
        let next = QuickSwitch.landing(after: p.id, in: members)
        _ = try? await store.endSession(id: p.id)
        // Ending the page being shown: go to its neighbor, else the list.
        guard p.id == current else { return }
        if let next { go(to: next) } else { model.showList() }
    }
}

/// Where the strip goes on a session's page: an empty slot above the
/// composer, its place passed up to the container that draws the strip.
struct QuickSwitchSlot: View {
    static let height: CGFloat = 44

    var body: some View {
        Color.clear
            .frame(height: Self.height)
            .anchorPreference(key: QuickSwitchSlotKey.self, value: .bounds) { $0 }
    }
}

struct QuickSwitchSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// On the container of the conversation pages (phones): draws the strip in
/// the slot the session's page left for it. One strip for all the
/// workspace's pages, so it stays put and its chips change color smoothly
/// while the pages slide under it.
struct QuickSwitchOverlay: ViewModifier {
    let current: AppModel.Conversation
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(QuickSwitchSlotKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, case .pal(let id) = current {
                    let members = QuickSwitch.members(current: id, pals: store.pals, workspaces: store.workspaces)
                    if !members.isEmpty {
                        let r = proxy[anchor]
                        QuickSwitchStrip(current: id, members: members)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .transition(.opacity)
                    }
                }
            }
        }
    }
}
