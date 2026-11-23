import PaloAllyKit
import SwiftUI

/// 在终端打开: an agent's session in the owner's own terminal. On the Mac
/// whose host runs it, the host opens it (its process ends first, and it
/// comes back when the terminal quits); on a phone, an iPad or another Mac,
/// the line for it is copied. A host from before this doesn't offer it.
enum AgentTerminal {
    /// The store's host runs on this very Mac.
    @MainActor static func opensHere(_ store: AppStore) -> Bool {
        MachineIdentity.matches(machineID: store.hostMachineID, hostName: store.hostName)
    }

    #if DEBUG
    /// The demo action `terminal:<pal id>`.
    static let demoAsk = Notification.Name("palo.demo.terminal")
    #endif
}

/// The action, for a menu or the details: what it does is the modifier's
/// (`agentTerminal`), which outlives the menu. None for one already open there.
struct AgentTerminalButton: View {
    let id: String
    let ask: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.terminalSupported, !store.singlePalOpenInTerminal(id: id) {
            Group {
                if AgentTerminal.opensHere(store) {
                    Button("在终端打开", systemImage: "terminal", action: ask)
                } else {
                    Button("复制终端命令", systemImage: "doc.on.doc", action: ask)
                }
            }
            .disabled(!store.connection.isOnline)
        }
    }
}

/// Set `pal` to open it in a terminal (or copy the line): one that has
/// something on is asked about first; what went wrong is said.
private struct AgentTerminalActions: ViewModifier {
    @Binding var pal: Pal?
    var copied: () -> Void
    @Environment(AppStore.self) private var store
    @State private var asking: Pal?
    @State private var failure: String?
    @State private var copies = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: pal?.id) {
                guard let p = pal else { return }
                pal = nil
                start(store.pal(id: p.id) ?? p)
            }
            .confirmationDialog(Copy.spaced(String(localized: "在终端打开「\(asking?.displayName ?? "")」？")),
                                isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible) {
                Button("打开") {
                    if let p = asking { open(p, force: true) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("它手上的事会停下，到终端里可以接着做。")
            }
            .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            }
            .sensoryFeedback(.success, trigger: copies)
    }

    private func start(_ p: Pal) {
        guard AgentTerminal.opensHere(store) else { return copy(p) }
        if p.isOccupied { asking = p } else { open(p, force: false) }
    }

    private func open(_ p: Pal, force: Bool) {
        Task {
            do { try await store.openInTerminal(id: p.id, force: force) } catch { failure = Copy.error(error) }
        }
    }

    private func copy(_ p: Pal) {
        Task {
            do {
                Clipboard.copy(try await store.terminalCommand(id: p.id))
                copies += 1
                copied()
            } catch {
                failure = Copy.error(error)
            }
        }
    }
}

extension View {
    /// 在终端打开 a Pal (or copying its line): set `pal` to ask.
    func agentTerminal(_ pal: Binding<Pal?>, copied: @escaping () -> Void = {}) -> some View {
        modifier(AgentTerminalActions(pal: pal, copied: copied))
    }
}
