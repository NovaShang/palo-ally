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
    /// A link that arrived from outside (a click, the Camera, a launch
    /// option) while this device already has an assistant: 「添加这台电脑？」.
    @State private var confirmAdd = false

    /// Only when the owner asked to add another computer does this screen
    /// talk about adding; otherwise it's plain pairing.
    private var adding: Bool { model.mode == .paired && model.pairingIntent == .add }

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
                        Text(adding ? "添加另一台电脑" : (model.mode == .paired ? "换一台电脑" : "你好，我是 PaloAlly"))
                            .font(.title.bold())
                        Text(adding
                             ? "每台电脑上是一个独立的助理。连上之后，点对话顶部的名字就能切换。"
                             : (model.mode == .paired
                                ? "连上新的电脑后，这台设备就和「\(currentHostLabel)」断开。"
                                : "住在你电脑上的私人助理。把这台设备和电脑连起来，随时找我办事。"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "在电脑上运行 paloally pair，会出现二维码和链接；或者在已经连上的设备上跟助理说「连一台新设备」。")
                        step(2, QRScannerView.isAvailable ? "用这台设备扫二维码，或者在这台设备上点开链接。" : "在这台设备上点开链接，或者把它复制过来。")
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
            .confirmationDialog("添加这台电脑？", isPresented: $confirmAdd, titleVisibility: .visible) {
                Button("添加") { submit() }
                if model.mode == .paired {
                    Button("换掉「\(currentHostLabel)」") { model.pairingIntent = .replace; submit() }
                }
                Button("不用", role: .cancel) {
                    linkText = ""
                    if isSheet { dismiss() }
                }
            } message: {
                Text(model.mode == .paired
                     ? "收到一个配对链接。添加后两台电脑的助理都在这里，点对话顶部的名字切换。"
                     : "收到一个配对链接。添加后离开演示，连上那台电脑上的助理。")
            }
        }
    }

    private var currentHostLabel: String {
        model.activeHostID.map(model.displayName) ?? "现在的电脑"
    }

    private func takePendingLink() {
        guard let pending = model.pendingPairingLink else { return }
        model.pendingPairingLink = nil
        linkText = pending
        // From outside, with an assistant here already: ask first.
        if model.confirmPairingLink {
            model.confirmPairingLink = false
            appLog.info("pairing link: asking 添加这台电脑？ (mode \(String(describing: model.mode), privacy: .public))")
            debugLog("pairing link: asking 添加这台电脑？ (mode \(String(describing: model.mode)))")
            confirmAdd = true
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
        // Someone's Ally invite, not a computer's pairing link.
        if AllyInviteLink.isAllyLink(linkText) {
            guard model.mode != .unpaired else {
                error = "这是加 Ally 的二维码。先把这台设备和你自己的电脑连上，再扫它。"
                return
            }
            model.allyInvite = PendingAllyInvite(link: linkText.trimmingCharacters(in: .whitespacesAndNewlines))
            if isSheet { dismiss() }
            return
        }
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

/// A pairing link for a computer this device is already paired with (the
/// assistant's pair_link, tapped on the device it was sent to): it's for
/// another device, so it's offered for passing on, and kept unused.
struct LinkForAnotherDeviceAlert: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let pending = model.linkForAnotherDevice
        content.alert("这台设备已经连着「\(pending.map { model.displayName($0.hostID) } ?? "")」",
                      isPresented: Binding(get: { model.linkForAnotherDevice != nil },
                                           set: { if !$0 { model.linkForAnotherDevice = nil } }),
                      presenting: pending) { p in
            Button("共享…") {
                // Once the alert is gone: it can't present the share sheet.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    SystemShare.present(p.link)
                }
            }
            Button("拷贝链接") { UIPasteboard.general.string = p.link }
            Button("好", role: .cancel) {}
        } message: { _ in
            Text("这个链接是给另一台设备用的：用隔空投送发过去，或者拷贝后在那台设备上粘贴，在那里点开。")
        }
    }
}

/// The system share sheet (隔空投送, 信息, 拷贝…) over whatever is showing.
@MainActor
enum SystemShare {
    static func present(_ text: String) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let window = scene?.keyWindow ?? scene?.windows.first, var top = window.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let items: [Any] = [URL(string: text) ?? text]
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad and Mac: a popover, from the middle of the window.
        sheet.popoverPresentationController?.sourceView = window
        sheet.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
    }
}

#Preview {
    PairingView(isSheet: false).environment(AppModel(launch: LaunchOptions(demo: false, screen: nil, tab: nil)))
}
