import PaloAllyKit
import SwiftUI

/// Signs Claude Code in again on the computer from here: when its login ran
/// out (or the owner signed out) and everything stopped, while it still
/// works, or as another account (Claude 用量). The computer starts Claude Code's own login;
/// its authorization page opens here, and the code that page shows is pasted
/// back and typed into the login on the computer. The code goes nowhere else.
struct ClaudeLoginSheet: View {
    /// What it's opened for while the login still works: the same one again,
    /// or another account. (Run out, or signed out, the status says so.)
    enum Purpose { case again, switching }
    var purpose: Purpose = .again

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false
    /// Whose login it was, and how things stood, when this opened.
    @State private var before: LoginAccount?
    @State private var stopped = false
    @State private var signedOut = false
    @FocusState private var codeFocused: Bool

    private var login: LoginStatus? { store.status?.auth?.login }
    private var checking: Bool { login?.state == .checking }

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Section {
                        Label(doneText, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        if let url = login?.url.flatMap(URL.init(string:)) {
                            Button {
                                openURL(url)
                                codeFocused = true
                            } label: {
                                Label("打开授权页", systemImage: "safari")
                            }
                        } else if login?.state == .failed {
                            Button("重新开始") { start() }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在主机上准备登录…").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        // (the page may be signed in to the old account)
                        Text(purpose == .switching && !stopped ? String(localized: "1. 授权，先在页面里换账号") : String(localized: "1. 授权"))
                    }
                    Section {
                        HStack {
                            TextField("粘贴代码", text: $code)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($codeFocused)
                                .submitLabel(.go)
                                .onSubmit(submit)
                            PasteButton(payloadType: String.self) { strings in
                                if let s = strings.first { code = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.capsule)
                        }
                        .disabled(login?.url == nil || checking)
                    } header: {
                        Text("2. 代码")
                    } footer: {
                        if checking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("正在登录…")
                            }
                        } else if login?.state == .invalid {
                            Text("代码不对，请确认整段复制了。").foregroundStyle(.red)
                        } else if login?.state == .failed {
                            Text(String(localized: "没登录成功：\(login?.error ?? "")")).foregroundStyle(.red)
                        } else if let error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(purpose == .switching && !stopped ? String(localized: "换个账号") : String(localized: "重新登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("登录") { submit() }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || login?.url == nil || checking || working)
                    }
                }
            }
        }
        .onAppear {
            guard before == nil else { return }
            before = store.usage?.account
            stopped = store.status?.auth?.isExpired == true
            signedOut = store.status?.auth?.signedOut == true
        }
        .task {
            if login == nil || login?.state == .failed { start() }
        }
        #if DEBUG
        // `-demoLoginCode <code>` (the demo): typed in once the link is there; `!` after it: and sent.
        .task(id: login?.url != nil) {
            guard login?.url != nil, let demo = UserDefaults.standard.string(forKey: "demoLoginCode") else { return }
            try? await Task.sleep(for: .seconds(1))
            code = demo.replacingOccurrences(of: "!", with: "")
            if demo.hasSuffix("!") { submit() }
        }
        #endif
        // The login went through: the computer says so by dropping the state.
        .onChange(of: store.status?.auth == nil) { _, gone in
            if gone { withAnimation { done = true } }
        }
    }

    // MARK: what it says, by what it's for

    /// The account it is now, when that's another one (said by the computer before the sign-in is done).
    private var changedTo: String? {
        guard let now = store.usage?.account, let email = now.email, before?.email != nil, before?.isSame(as: now) != true else { return nil }
        return email
    }

    private var doneText: String {
        if let changedTo { return String(localized: "已换成 \(changedTo)") }
        if stopped { return String(localized: "登录好了") }
        guard let email = store.usage?.account?.email else { return String(localized: "登录好了") }
        return String(localized: "登录好了，还是 \(email)")
    }

    private func start() {
        error = nil
        Task {
            do { try await store.startLogin() } catch { self.error = String(localized: "没能开始登录：\(Friendly.message(error))") }
        }
    }

    private func submit() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            do { try await store.submitLoginCode(c) } catch { self.error = String(localized: "没发出去：\(Friendly.message(error))") }
            working = false
        }
    }

    private func cancel() {
        Task { try? await store.cancelLogin() }
        dismiss()
    }
}
