import PaloAllyKit
import SwiftUI

/// A Pal's page (pals-prd §4): a remote Claude Code. Its conversation is the
/// assistant's conversation view on the Pal's scoped store (`palStore`):
/// streaming, the paced reveal, following the end, cards, the composer and
/// voice, all the same; what the owner types goes in as typed. ⋯ has
/// 停止这一轮, 重命名 (the system's alert), 交还终端 (the line that resumes it
/// in a terminal, to copy) and 移出 Pals, these two asked in the page in
/// place of the composer.
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
        /// 交还终端, asked first.
        case release
        /// Handed back: the line that picks it up in a terminal.
        case released(String)
        /// 移出 Pals, asked first.
        case remove
        /// Something didn't work: why.
        case notice(String)
    }
    @State private var panel = Panel.none
    @State private var working = false
    /// 重命名 asked.
    @State private var renaming: Pal?
    /// The Pal as last seen: it leaves the list once handed back or removed.
    @State private var last: Pal?

    private var pal: Pal? { store.pal(id: palID) ?? last }
    /// No longer on the list (handed back, removed, or gone at the computer).
    private var gone: Bool { store.pal(id: palID) == nil && store.palsSupported == true }
    /// Words sent to it asleep: it's being woken (§12).
    private var waking: Bool { store.status?.busy == true && store.status?.activity == AppStore.wakingActivity }

    var body: some View {
        ChatView(bottomPanel: bottom, pageTop: .init(subtitle: subtitle, dot: waking ? .green : pal.flatMap { Copy.palStatusColor($0.status) },
                                                     menu: AnyView(menu)))
            .navigationSubtitle(subtitle)
            .modifier(BarMenu { menu })
            .onChange(of: store.pal(id: palID), initial: true) { _, p in if let p { last = p } }
            .animation(.snappy, value: panel)
            .palRename($renaming)
            .modifier(PalFilesSheet(palID: palID))
            #if DEBUG
            // `-demoPalPanel release | remove | released`: the page opens on it (snapshots).
            .task {
                switch UserDefaults.standard.string(forKey: "demoPalPanel") {
                case "release": panel = .release
                case "remove": panel = .remove
                case "released": panel = .released(pal?.resumeCommand ?? "claude --resume")
                default: break
                }
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
        let name = pal?.displayName ?? "它"
        let content: AnyView
        switch panel {
        case .none:
            guard gone else { return nil }
            content = AnyView(
                NoticePanel(text: Copy.spaced("\(name)已经不在 Pals 里了。对话记录还在电脑上。"), action: "回到列表") {
                    model.showList()
                })
        case .release:
            content = AnyView(
                ConfirmPanel(title: "交还终端？",
                             text: "PaloAlly 会关掉它。你在电脑的终端里运行一行命令，就从刚才的地方接着用，对话一字不丢。",
                             action: "交还", working: working, destructive: false,
                             cancel: { panel = .none }, confirm: { Task { await release() } }))
        case .released(let command):
            content = AnyView(
                CommandPanel(title: "在终端里接着用",
                             text: "在电脑的终端里运行这一行，就从刚才的地方接着跟它说。",
                             command: command) { model.showList() })
        case .remove:
            content = AnyView(
                ConfirmPanel(title: Copy.spaced("把\(name)移出 Pals？"),
                             text: "PaloAlly 不再管它，它会停下。对话记录还在电脑上。",
                             action: "移出", working: working,
                             cancel: { panel = .none }, confirm: { Task { await remove() } }))
        case .notice(let why):
            content = AnyView(NoticePanel(text: why, action: "好") { panel = .none })
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

    // MARK: menu

    private var menu: some View {
        PageMenu(label: "更多") {
            if pal?.inTurn == true || store.isBusy {
                Button("停止这一轮", systemImage: "stop.circle") { Task { await stop() } }
            }
            Button("重命名", systemImage: "pencil") { renaming = pal }
            Button { model.openPalFiles(palID) } label: {
                Label { Text("文件", tableName: "Files") } icon: { Image(systemName: "folder") }
            }
            Section {
                Button("交还终端", systemImage: "apple.terminal") { panel = .release }
                Button("移出 Pals", systemImage: "minus.circle", role: .destructive) { panel = .remove }
            }
        }
        .disabled(working || gone || !store.connection.isOnline)
        .accessibilityIdentifier("pal-menu")
    }

    // MARK: actions

    private func stop() async {
        do {
            try await store.stop()
        } catch {
            panel = .notice("没停下：\(Copy.error(error))")
        }
    }

    private func release() async {
        working = true
        defer { working = false }
        do {
            let command = try await store.releasePal(id: palID)
            panel = .released(command)
        } catch {
            panel = .notice("没交还成：\(Copy.error(error))")
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            try await store.removePal(id: palID)
            panel = .none
            model.showList()
        } catch {
            panel = .notice("没移出：\(Copy.error(error))")
        }
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
                            failure = "没改成：\(Copy.error(error))"
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
