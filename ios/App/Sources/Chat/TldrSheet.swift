import PaloAllyKit
import SwiftUI

/// 「TL;DR」: the recent stretch of the conversation in a few points, the
/// owner's own words (checked verbatim on the computer) apart from what
/// assistants said or passed on. Asked from the page's menu (a pane's ⋯,
/// the Mac toolbar's ⋯, the details on phones); a view for the owner only:
/// nothing goes into the conversation.
extension AppStore {
    /// Which conversation a TL;DR is for (WindowModel.tldrFor); none for a
    /// session only looked at (not a Pal: the host doesn't summarize those).
    var tldrKey: String? {
        switch scope {
        case .palo: "palo"
        case .pal(let id): id
        case .session: nil
        }
    }
}

extension WindowModel {
    /// The menu entry's action: this conversation's TL;DR opens.
    func openTldr(_ key: String) { tldrFor = key }
}

enum TldrCopy {
    static let menuTitle = "TL;DR"
    static let icon = "text.badge.star"
}

/// The Mac: the page's ⋯ in the window toolbar, with 「TL;DR」 (Palo's page
/// and a session's; a workspace's panes have their own ⋯). Put up whenever
/// the window shows this conversation without it: at launch the window's
/// page can change twice in one update (the saved one, then a launch
/// option), which clears the toolbar after the page first put it up.
struct TldrMacMenu: ViewModifier {
    let enabled: Bool
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var token = UUID()

    func body(content: Content) -> some View {
        if enabled, Platform.barInWindowToolbar, let key = store.tldrKey {
            let page: WindowModel.Conversation = store.palID == nil ? .palo : .pal(key)
            content
                // Shown, and the toolbar doesn't have it (yet, or any more:
                // a change of page clears the toolbar's menus).
                .onChange(of: model.selection == page && model.macToolbarPage != page, initial: true) { _, missing in
                    if missing { publish(page, key) }
                }
                .onDisappear {
                    guard model.macToolbarOwner == token else { return }
                    model.clearMacToolbarMenus()
                }
        } else {
            content
        }
    }

    private func publish(_ page: WindowModel.Conversation, _ key: String) {
        model.macToolbarOwner = token
        model.macToolbarPage = page
        model.macToolbarMenus = MacToolbarMenus(menu: [MacMenuItem(title: TldrCopy.menuTitle, image: TldrCopy.icon) { model.openTldr(key) }])
    }
}

/// Phones and iPads: 「TL;DR」 in the details the title opens (their pages
/// have no ⋯); the details close and the sheet comes up in their place.
/// The Mac has it in its toolbar's ⋯ and the panes' ⋯ instead.
struct TldrDetailRow: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.tileDetail) private var tileDetail

    var body: some View {
        if !Platform.barInWindowToolbar, let key = store.tldrKey {
            Section {
                Button {
                    model.setDetail(false, tile: tileDetail)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450)) // one sheet away before the next
                        model.openTldr(key)
                    }
                } label: {
                    Label(TldrCopy.menuTitle, systemImage: TldrCopy.icon)
                }
                .tint(.primary) // a row like the others; the theme color is for 发送
                .disabled(!store.connection.isOnline)
                .accessibilityIdentifier("detail-tldr")
            } footer: {
                Text("最近一段对话的要点，你自己的原话单独列出。")
            }
        }
    }
}

/// The sheet, on the conversation it summarizes (a workspace's tile has its own).
struct TldrPresenter: ViewModifier {
    /// A quote tapped: its message, to bring into view.
    let jump: (String) -> Void
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { store.tldrKey != nil && model.tldrFor == store.tldrKey },
                                           set: { if !$0, model.tldrFor == store.tldrKey { model.tldrFor = nil } })) {
            TldrView { id in
                model.tldrFor = nil
                jump(id)
            }
            .environment(store)
            .presentationDetents(Platform.isMac ? [.large] : [.medium, .large])
            .modifier(MacSheetSize())
        }
    }
}

/// The Mac: a sheet about 460 pt wide and tall enough for a few points and
/// quotes; phones and iPads keep the system's sizes.
private struct MacSheetSize: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.isMac {
            content.frame(width: 460, height: 600).presentationSizing(.fitted)
        } else {
            content
        }
    }
}

struct TldrView: View {
    let jump: (String) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var result: TldrResult?
    @State private var failure: String?
    @State private var copied = false
    /// Bumped by 重试.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    summary(result)
                } else if let failure {
                    ContentUnavailableView {
                        Label("没整理出来", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(Copy.spaced(failure))
                    } actions: {
                        Button("重试") { self.failure = nil; attempt += 1 }
                            .buttonStyle(.glass)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在整理最近的对话…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("tldr-loading")
                }
            }
            .navigationTitle("要点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? String(localized: "已拷贝") : String(localized: "拷贝"), systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
                        .labelStyle(.titleOnly)
                        .disabled(result == nil)
                        .accessibilityIdentifier("tldr-copy")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .tint(.primary)
        }
        .task(id: attempt) { await load() }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .accessibilityIdentifier("tldr")
    }

    private func summary(_ r: TldrResult) -> some View {
        List {
            Section {
                ForEach(Array(r.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(.secondary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(point).textSelection(.enabled)
                    }
                }
            } footer: {
                Text(covered(r))
            }
            if !r.ownWords.isEmpty {
                Section {
                    ForEach(r.ownWords, id: \.self) { quote(for: $0) }
                } header: {
                    Text("你说过的原话")
                } footer: {
                    Text("逐字摘自你自己发的消息，没有改动。")
                }
            }
            if !r.relayed.isEmpty {
                Section {
                    ForEach(r.relayed, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.who).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(item.gist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("转述的内容")
                } footer: {
                    Text("助理或别的会话说的、转来的，不是你的原话。")
                }
            }
        }
        .accessibilityIdentifier("tldr-summary")
    }

    /// One of the owner's quotes: a bar at its side, its time; tapping it
    /// goes to its message when that is loaded in the conversation.
    @ViewBuilder private func quote(for q: TldrQuote) -> some View {
        let here = store.messages.contains { $0.id == q.messageId }
        let row = HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.35)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(q.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Text(Copy.clock(q.ts)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if here {
                Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        if here {
            Button { jump(q.messageId) } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("回到这条消息")
        } else {
            row.textSelection(.enabled)
        }
    }

    private func covered(_ r: TldrResult) -> String {
        let span = r.since > 0 && r.until > 0 ? "\(Copy.clock(r.since)) – \(Copy.clock(r.until))" : ""
        return span.isEmpty ? String(localized: "整理了最近 \(r.covered) 条消息") : String(localized: "整理了最近 \(r.covered) 条消息 · \(span)")
    }

    private func load() async {
        guard result == nil else { return }
        do {
            result = try await store.tldr()
        } catch {
            failure = Copy.error(error)
        }
    }

    private func copy() {
        guard let r = result else { return }
        let text = r.markdown(title: String(localized: "要点"), ownTitle: String(localized: "你说过的原话"),
                              relayedTitle: String(localized: "转述的内容"), time: Copy.clock)
        #if DEBUG
        // `-copyDryRun YES` (tests): said in the log, the clipboard left as it is.
        if UserDefaults.standard.bool(forKey: "copyDryRun") {
            debugLog("[tldr] copy (dry run): \(text.count) characters")
            copied = true
            return
        }
        #endif
        Clipboard.copy(text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            copied = false
        }
    }
}
