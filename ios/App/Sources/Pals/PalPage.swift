import PaloAllyKit
import SwiftUI

/// A session's page (pals-prd §4): a remote Claude Code. Its conversation is the
/// assistant's conversation view on the Pal's scoped store (`palStore`):
/// streaming, the paced reveal, following the end, cards, the composer and
/// voice, all the same; what the owner types goes in as typed. Its title is
/// the capsule that opens the details (rename, files, model, 结束…); stopping
/// a turn is the composer's stop button.
struct PalPage: View {
    let palID: String
    /// The assistant's store, which makes and feeds the Pal's.
    @Environment(AppStore.self) private var store

    var body: some View {
        PalConversation(palID: palID)
            .environment(store.palStore(palID))
    }
}

private struct PalConversation: View {
    let palID: String
    @Environment(AppModel.self) private var model
    /// The Pal's own store.
    @Environment(AppStore.self) private var store

    enum Panel: Equatable {
        case none
        /// Something didn't work: why.
        case notice(String)
    }
    @State private var panel = Panel.none
    /// The Pal as last seen: it leaves the list once ended or gone.
    @State private var last: Pal?

    private var pal: Pal? { store.pal(id: palID) ?? last }
    /// No longer on the list (ended here or elsewhere, or gone at the computer).
    private var gone: Bool { store.pal(id: palID) == nil && store.palsSupported == true }
    /// Words sent to it asleep: it's being woken (§12).
    private var waking: Bool { store.status?.busy == true && store.status?.activity == AppStore.wakingActivity }

    var body: some View {
        ChatView(bottomPanel: bottom, pageTop: .init(subtitle: subtitle, dot: waking ? .working : pal?.dot, capsule: true))
            .navigationSubtitle(subtitle)
            .onChange(of: store.pal(id: palID), initial: true) { _, p in if let p { last = p } }
            // Opened, or finished while it is open: seen, on every device.
            .onChange(of: store.pal(id: palID)?.attention, initial: true) { _, a in
                if a == .done { store.markSeen(id: palID) }
            }
            .animation(.snappy, value: panel)
            .modifier(PalFilesSheet(palID: palID))
            #if DEBUG
            .task {
                // `-demoUnfold <message id>`: that long message opens unfolded.
                if let id = UserDefaults.standard.string(forKey: "demoUnfold") { store.setUnfolded(id, true) }
            }
            #endif
    }

    /// Its state and folder (在忙 / 空闲 / 睡着 / 等你), under its name.
    private var subtitle: String { pal.map { Copy.palSubtitle($0, waking: waking) } ?? "" }

    // MARK: bottom

    /// In place of the composer: what's being asked, or the line to copy.
    private var bottom: AnyView? {
        let name = pal?.displayName ?? String(localized: "它")
        let content: AnyView
        switch panel {
        case .none:
            guard gone else { return nil }
            content = AnyView(
                NoticePanel(text: Copy.spaced(String(localized: "\(name)已经不在会话列表里了。对话记录还在电脑上。")), action: String(localized: "回到列表")) {
                    model.showList()
                })
        case .notice(let why):
            content = AnyView(NoticePanel(text: why, action: String(localized: "好")) { panel = .none })
        }
        return AnyView(
            content
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: ChatView.readableWidth)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity)))
    }
}

/// 重命名 (pals-prd §13): the system's alert with the name filled in. Claude
/// Code's title for the session changes too; a name another Pal has comes
/// back with a number. Used by the Pal's page and its row on the list.
struct PalRenameAlert: ViewModifier {
    @Binding var pal: Pal?
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: Binding(get: { pal != nil }, set: { if !$0 { pal = nil } })) {
                TextField("名字", text: $text)
                    .accessibilityIdentifier("pal-rename-field")
                Button("取消", role: .cancel) { pal = nil }
                Button("好") {
                    let id = pal?.id
                    let name = text
                    pal = nil
                    guard let id else { return }
                    Task {
                        do {
                            try await store.renamePal(id: id, name: name)
                        } catch {
                            failure = String(localized: "没改成：\(Copy.error(error))")
                        }
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("电脑上的 Claude Code 里也会是这个名字。")
            }
            .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            }
            .onChange(of: pal?.id) { _, id in if id != nil { text = pal?.displayName ?? "" } }
    }
}

extension View {
    /// 重命名 a Pal: set `pal` to ask.
    func palRename(_ pal: Binding<Pal?>) -> some View { modifier(PalRenameAlert(pal: pal)) }
}
