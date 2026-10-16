import PaloAllyKit
import SwiftUI

/// One of the computer's Claude Code sessions that isn't a Pal, read only
/// (pals-prd §14): a live one (terminal or background) or a conversation that
/// ended lately. The conversation view a Pal's page has, on the session's
/// read-only store (`sessionStore`): its words, paging back, another agent's
/// long words folded, the cards it asked through the hooks at its end. An
/// open page asks for what's new every 3 seconds. In place of the composer,
/// a quiet bar: 接管 (the theme color) runs the usual adoption, a terminal
/// session waiting to be quit there first; once it's a Pal, its page opens.
struct SessionPage: View {
    let sessionID: String
    /// The assistant's store, which makes the session's.
    @Environment(AppStore.self) private var store

    var body: some View {
        SessionConversation(sessionID: sessionID)
            .environment(store.sessionStore(sessionID))
    }
}

private struct SessionConversation: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    /// The session's own store.
    @Environment(AppStore.self) private var store

    enum Step: Equatable {
        case idle
        /// Being asked of the computer.
        case working
        /// Still open in a terminal: quit it there first.
        case waiting
        /// It didn't work: why.
        case failed(String)
    }
    @State private var step = Step.idle

    private var shown: (name: String, cwd: String, live: CCSession?)? { store.viewedSession(sessionID) }

    var body: some View {
        ChatView(bottomPanel: AnyView(bar), pageTop: .init(subtitle: subtitle,
                                                          dot: shown?.live.flatMap { s in Copy.sessionStatusColor(s.status) == .clear ? nil : Copy.sessionStatusColor(s.status) }))
            .navigationSubtitle(subtitle)
            .animation(.snappy, value: step)
            // What it says while the page is open.
            .task(id: store.connection.isOnline) {
                guard store.connection.isOnline else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await store.reloadSessionPage()
                }
            }
            // A Pal now (here, from its row, on another device): its page.
            .onChange(of: store.pal(sessionId: sessionID)?.id, initial: true) { _, id in
                if let id { model.openPal(id) }
            }
            .onChange(of: store.otherSessions.first { $0.id == sessionID }.map(store.waitsForExit), initial: true) { _, waits in
                if waits == true, step != .waiting { step = .waiting }
                // Cancelled on another device, or the host gave up waiting.
                if waits == false, step == .waiting { step = .idle }
            }
    }

    private var subtitle: String {
        guard let s = shown else { return "" }
        let folder = CCSession.shortPath(s.cwd)
        if let live = s.live { return "\(Copy.sessionStatus(live.status)) · \(folder)" }
        return String(localized: "已退出 · \(folder)")
    }

    // MARK: the bar

    @ViewBuilder private var bar: some View {
        Group {
            switch step {
            case .idle, .working:
                HStack(spacing: 12) {
                    Text("接管后可以在这里跟它说话")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { await adopt() }
                    } label: {
                        Text(step == .working ? String(localized: "接管中…") : String(localized: "接管"))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(step == .working || !store.connection.isOnline)
                    .accessibilityIdentifier("session-adopt")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
            case .waiting:
                NoticePanel(text: String(localized: "它还在终端里开着。请在终端里输入 /exit 退出它，退出后自动接管。"), action: String(localized: "取消")) {
                    step = .idle
                    Task { await store.cancelAdoption(sessionId: sessionID) }
                }
            case .failed(let why):
                NoticePanel(text: Copy.spaced(String(localized: "没接管成：\(why)")), action: String(localized: "好")) { step = .idle }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: ChatView.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private func adopt() async {
        step = .working
        do {
            switch try await store.adopt(sessionId: sessionID) {
            case .adopted(let pal):
                step = .idle
                model.openPal(pal.id)
            case .waitingForExit:
                // The Pal's page opens by itself once it's been quit.
                step = .waiting
            }
        } catch {
            store.clearAdoption(sessionId: sessionID)
            step = .failed(Copy.error(error))
        }
    }
}
