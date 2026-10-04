import PaloAllyKit
import SwiftUI
import UIKit

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let isSheet: Bool

    @State private var linkText = ""
    @State private var code = ""
    @State private var showScanner = false
    @State private var showManual = false
    @State private var working = false
    @State private var error: String?
    /// A link that arrived from outside (URL open / launch option) while this
    /// device is already paired: ask before switching computers.
    @State private var confirmSwitch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 100, height: 100)
                            .glassEffect(.regular, in: .circle)
                        Text("你好，我是 PaloAlly")
                            .font(.title.bold())
                        Text("住在你电脑上的私人助理。把这台设备和电脑连起来，随时找我办事。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "在电脑上运行 paloally pair，屏幕上会出现一个二维码。")
                        step(2, QRScannerView.isAvailable ? "用这台设备扫一扫，或者把链接复制过来。" : "把电脑上显示的配对链接复制过来。")
                        step(3, "连上之后，数据只在你的电脑和这台设备之间加密传送。")
                    }
                    .padding(18)
                    .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))

                    VStack(spacing: 12) {
                        if QRScannerView.isAvailable {
                            Button {
                                showScanner = true
                            } label: {
                                Label("扫一扫", systemImage: "qrcode.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                        }

                        Button {
                            if let s = UIPasteboard.general.string { linkText = s }
                            submit()
                        } label: {
                            Label("粘贴配对链接", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)

                        DisclosureGroup("手动输入", isExpanded: $showManual) {
                            VStack(spacing: 10) {
                                TextField("配对链接（paloally://…）", text: $linkText, axis: .vertical)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .lineLimit(1...3)
                                TextField("6 位配对码", text: $code)
                                    .keyboardType(.numberPad)
                                    .font(.title3.monospacedDigit())
                                Button("连接") { submit() }
                                    .buttonStyle(.glassProminent)
                                    .disabled(linkText.isEmpty)
                            }
                            .textFieldStyle(.roundedBorder)
                            .padding(.top, 8)
                        }
                        .padding(.horizontal, 4)
                    }

                    if working {
                        ProgressView("正在连接…")
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }

                    if model.mode != .demo {
                        Button("先看看演示") {
                            model.startDemo()
                            if isSheet { dismiss() }
                        }
                        .font(.callout)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .disabled(working)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { payload in
                    showScanner = false
                    linkText = payload
                    submit()
                }
            }
            .onAppear(perform: takePendingLink)
            // A link can also arrive while this screen is already showing.
            .onChange(of: model.pendingPairingLink) { takePendingLink() }
            .confirmationDialog(switchTitle, isPresented: $confirmSwitch, titleVisibility: .visible) {
                Button("换过去") { submit() }
                Button("不换", role: .cancel) {
                    linkText = ""
                    if isSheet { dismiss() }
                }
            } message: {
                Text("收到了一个配对链接。换过去之后，这台设备就不再连「\(currentHostLabel)」了。")
            }
        }
    }

    private var currentHostLabel: String {
        let name = model.store?.hostName ?? ""
        if !name.isEmpty { return name }
        let label = model.pairedHost?.hostLabel ?? ""
        return label.isEmpty ? "现在的电脑" : label
    }

    private var switchTitle: String { "从「\(currentHostLabel)」换到另一台电脑？" }

    private func takePendingLink() {
        guard let pending = model.pendingPairingLink else { return }
        model.pendingPairingLink = nil
        linkText = pending
        if model.mode == .paired {
            confirmSwitch = true
        } else {
            submit()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.fill.tertiary, in: .circle)
            Text(text).font(.callout)
        }
    }

    private func submit() {
        error = nil
        do {
            var link = try PairingLink.parse(linkText)
            let typed = code.filter(\.isNumber)
            if !typed.isEmpty { link.code = typed }
            guard PairingLink.isValidCode(link.code) else {
                showManual = true
                error = "还差 6 位配对码，看一下电脑屏幕"
                return
            }
            working = true
            Task {
                do {
                    try await model.pair(with: link)
                    if isSheet { dismiss() }
                } catch {
                    appLog.error("pairing failed: \(String(describing: error), privacy: .public)")
                    debugLog("pairing failed: \(String(describing: error))")
                    self.error = (error as? PairingError)?.errorDescription ?? Copy.error(error)
                }
                working = false
            }
        } catch {
            appLog.error("bad pairing link: \(String(describing: error), privacy: .public)")
            debugLog("bad pairing link: \(String(describing: error))")
            self.error = (error as? LocalizedError)?.errorDescription ?? "这不是配对链接"
            showManual = true
        }
    }
}

#Preview {
    PairingView(isSheet: false).environment(AppModel(launch: LaunchOptions(demo: false, screen: nil, tab: nil)))
}
