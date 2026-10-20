import PaloAllyKit
import SwiftUI

/// The phone's quick-switch strip for a session in a workspace, copied from
/// Bento Term's Focus-mode window tab bar (`WindowTabBar`): a row of glass
/// chips at the very bottom of the screen, under the composer, one per
/// session of the workspace, no icons. It scrolls sideways by hand like any
/// scroll view; a tap switches; the current one is kept in view. The
/// keyboard covers it (it steps aside while typing).
///
/// Chips as Bento's `WindowTab` + `BarItemGlass`: the name capped at 140 pt,
/// the glass tinted by state in the indicator's colors (blue 在干, amber 等你,
/// green 做完了): the current chip wears the full color with white words,
/// the others half the color (闲着: plain glass) with dim words. Bento's
/// current idle chip wears the theme color; here it is the idle gray, the
/// theme color being kept for the main actions.
struct QuickSwitchStrip: View {
    let current: String
    /// The workspace's sessions (`QuickSwitch.members`), two or more.
    let members: [String]

    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Asked from a chip's menu, answered by the bar: the strip goes away
    /// while the keyboard is up, and the rename alert's field brings it up.
    @Binding var renaming: Pal?
    @Binding var ending: Pal?
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(members, id: \.self) { id in
                        chip(id).id(id)
                    }
                }
                // Each chip at its own width (a name, up to 140 pt), never
                // stretched by the room around them...
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // ...and a few of them in the middle of the screen.
                .frame(minWidth: width)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, c in
                // Keep the current tab in view.
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(c, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-switch")
    }

    // MARK: chips

    private func chip(_ id: String) -> some View {
        let pal = store.pal(id: id)
        let state = pal?.dot ?? .idle
        let isCurrent = id == current
        return Text(pal?.displayName ?? "…")
            .font(.footnote)
            .foregroundStyle(isCurrent ? Color.white : Color.secondary)
            .lineLimit(1)
            .frame(maxWidth: 140)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(Self.glass(state, current: isCurrent), in: .capsule)
            .contentShape(Capsule())
            .onTapGesture { if !isCurrent { go(to: id) } }
            .contextMenu { if let pal { menu(pal) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(pal?.displayName ?? ""), \(StatusDot.label(state))"))
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("quick-switch-\(id)")
    }

    /// Bento's `BarItemGlass`: the state color full on the current chip, half
    /// on the others; idle: gray on the current one, plain glass otherwise.
    static func glass(_ state: StatusDotKind, current: Bool) -> Glass {
        let base = StatusDot.color(state)
        if current { return .regular.tint(base).interactive() }
        guard state != .idle else { return .regular.interactive() }
        return .regular.tint(base.opacity(0.5)).interactive()
    }

    /// Switches with the pages sliding: the next one in from the right, the
    /// previous one from the left, as the strip's order goes.
    private func go(to id: String) {
        let from = members.firstIndex(of: current) ?? 0, to = members.firstIndex(of: id) ?? 0
        model.quickSwitchForward = to >= from
        withAnimation(.snappy(duration: 0.32)) { model.openPal(id) }
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

}

/// On the container of the conversation pages (phones): the strip at the
/// bottom of the screen, under the page's composer, for a session in a
/// workspace. One strip for all the workspace's pages, so it stays put while
/// they slide past above it. Hidden while the keyboard is up (in Bento the
/// keyboard slides over it).
struct QuickSwitchBar: ViewModifier {
    let current: WindowModel.Conversation
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var keyboardUp = false
    @State private var renaming: Pal?
    @State private var ending: Pal?

    private var members: [String] {
        guard case .pal(let id) = current else { return [] }
        return QuickSwitch.members(current: id, pals: store.pals, workspaces: store.workspaces)
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.layout == .phone, !keyboardUp, case .pal(let id) = current, !members.isEmpty {
                    QuickSwitchStrip(current: id, members: members, renaming: $renaming, ending: $ending)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
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

    private func end(_ p: Pal) async {
        let list = members
        let next = QuickSwitch.landing(after: p.id, in: list)
        _ = try? await store.endSession(id: p.id)
        // Ending the page being shown: go to its neighbor, else the list.
        guard case .pal(p.id) = current else { return }
        if let next {
            let from = list.firstIndex(of: p.id) ?? 0, to = list.firstIndex(of: next) ?? 0
            model.quickSwitchForward = to >= from
            withAnimation(.snappy(duration: 0.32)) { model.openPal(next) }
        } else {
            model.showList()
        }
    }
}
