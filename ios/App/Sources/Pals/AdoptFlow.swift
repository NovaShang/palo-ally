import PaloAllyKit
import SwiftUI

/// 从终端搬进来… (the sidebar's ＋ menu): the computer's other live Claude
/// Code sessions, each with 接管. Adopting happens in place: a moment's wait,
/// or (a terminal session) the line asking the owner to quit it there, with
/// 取消. Tapping a row looks at its conversation, read only (pals-prd §14).
struct AdoptFlowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.otherSessions) { session in
                    OtherSessionRow(session: session)
                        .contentShape(.rect)
                        .onTapGesture {
                            dismiss()
                            model.openSession(session.id)
                        }
                }
            }
            .overlay {
                if store.otherSessions.isEmpty {
                    Text("电脑上开着的 Claude Code 会出现在这里。接管以后，在手机上接着聊。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .accessibilityIdentifier("adopt-empty")
                }
            }
            .navigationTitle("从终端搬进来")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .animation(.snappy, value: store.otherSessions)
            .animation(.snappy, value: store.adoptions)
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .accessibilityIdentifier("adopt-flow")
    }
}

/// One of the computer's other live sessions: dimmer, with its state, and
/// 接管. Adopting it happens in place: a moment's wait, or (a terminal
/// session) the line asking the owner to quit it there, with 取消.
struct OtherSessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let session: CCSession

    var body: some View {
        let adoption = store.adoptions[session.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusDot(StatusDotKind(session.status), size: 9)
                    .frame(width: 24)
                    .opacity(0.8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.displayName)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        SessionKindTag(kind: session.kind)
                    }
                    Text(secondLine(adoption))
                        .font(.subheadline)
                        .foregroundStyle(failed(adoption) ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                        .lineLimit(failed(adoption) ? 3 : 1)
                }
                Spacer(minLength: 4)
                trailing(adoption)
            }
            if store.waitsForExit(session) {
                waitingForExit
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row-session-\(session.id)")
    }

    private func failed(_ a: PalAdoption?) -> Bool { if case .failed? = a { return true } else { return false } }

    private func secondLine(_ a: PalAdoption?) -> String {
        switch a {
        case .working?: return String(localized: "正在接管…")
        case .failed(let why)?: return why
        default:
            let line = Copy.sessionLine(session)
            let status = Copy.sessionStatus(session.status)
            return line.isEmpty ? status : "\(status) · \(line)"
        }
    }

    @ViewBuilder
    private func trailing(_ a: PalAdoption?) -> some View {
        switch a {
        case .working?:
            ProgressView()
        case .waitingForExit?:
            EmptyView()
        case nil where store.waitsForExit(session):
            EmptyView()
        case .failed?:
            Button("好") { store.clearAdoption(sessionId: session.id) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.secondary)
        case nil:
            Button("接管") { adopt() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.primary)
                .disabled(!store.connection.isOnline)
                .accessibilityIdentifier("adopt-\(session.id)")
                .accessibilityHint("让 PaloAlly 接着跑它，在手机上跟它说话")
        }
    }

    /// A terminal session: quit it there first; PaloAlly carries on by itself.
    private var waitingForExit: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("请在终端里输入 /exit 退出它，退出后自动接管")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // The host stops waiting too: quitting it later adopts nothing.
            Button("取消") { Task { await store.cancelAdoption(sessionId: session.id) } }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.secondary)
                .accessibilityIdentifier("adopt-cancel-\(session.id)")
        }
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adopt-waiting-\(session.id)")
    }

    private func adopt() {
        Task {
            if case .adopted(let pal)? = try? await store.adopt(sessionId: session.id) {
                model.openPal(pal.id)
            }
        }
    }
}

