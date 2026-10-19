import PaloAllyKit
import SwiftUI

/// Signs Claude Code in again on the computer from here, when its login ran
/// out and everything stopped. The computer starts Claude Code's own login;
/// its authorization page opens here, and the code that page shows is pasted
/// back and typed into the login on the computer. The code goes nowhere else.
struct ClaudeLoginSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false
    @FocusState private var codeFocused: Bool

    private var login: LoginStatus? { store.status?.auth?.login }
    private var checking: Bool { login?.state == .checking }

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Section {
                        Label("登录好了，停下的事会接着做。", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        Text("电脑上的 Claude Code 登录过期了。在这里打开授权页，用你的 Claude 账号同意，再把页面上显示的代码粘贴回来。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section("1. 授权") {
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
                                Text("正在电脑上准备登录…").foregroundStyle(.secondary)
                            }
                        }
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
            .navigationTitle("重新登录")
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
        .task {
            if login == nil || login?.state == .failed { start() }
        }
        // The login went through: the computer says so by dropping the state.
        .onChange(of: store.status?.auth == nil) { _, gone in
            if gone { withAnimation { done = true } }
        }
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
