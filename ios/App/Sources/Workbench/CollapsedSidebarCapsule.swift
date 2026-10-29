import PaloAllyKit
import SwiftUI
import UIKit

extension WindowModel {
    /// The sidebar shown or put away: the window's sidebar button, ⌃⌘S and
    /// the capsule's button all come here.
    func toggleSidebar() {
        debugLog("[sidebar] \(columnVisibility == .detailOnly ? "shown" : "put away") in \(traceName)")
        withAnimation(.snappy) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// Sidebar collapsed on a large screen: the capsule stands in for it.
    var sidebarCollapsed: Bool { layout == .split && columnVisibility == .detailOnly }

    /// Sessions waiting on the owner, then the ones that finished something
    /// not yet looked at, each the latest first.
    func attentionSessions(in store: AppStore) -> (waiting: [Pal], done: [Pal]) {
        func latest(_ kind: StatusDotKind) -> [Pal] {
            store.pals.filter { $0.dot == kind }.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        }
        return (latest(.waiting), latest(.done))
    }

    /// A session picked in the capsule's list: the active tile when it is in
    /// the open workspace, else its own page.
    func jump(toSession pal: Pal) {
        if case .workspace(let w)? = selection, pal.workspaceId == w {
            activate(tile: pal.id, in: w)
        } else {
            openPal(pal.id)
        }
    }
}

/// The small glass capsule at the window's top left (by the traffic lights
/// on the Mac): the sidebar button, and while the sidebar is away a small
/// Palo orb and "N 等你 · N 做完" (workbench-prd §8). Expanded, it is only
/// the button. It floats over the page, never in the way of a strip's own
/// controls: the strips start below it.
struct CollapsedSidebarCapsule: View {
    let collapsed: Bool
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @State private var listShown = false
    /// The Mac: Palo's conversation in a popover from the orb.
    @State private var paloShown = false

    var body: some View {
        let (waiting, done) = model.attentionSessions(in: store)
        HStack(spacing: 6) {
            Button { model.toggleSidebar() } label: {
                // The whole square takes the click, not a circle inside the
                // capsule: its rim answered nothing (10-29).
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? String(localized: "显示侧栏") : String(localized: "隐藏侧栏"))
            .accessibilityIdentifier("sidebar-toggle")
            #if targetEnvironment(macCatalyst)
            .help(Text("显示或隐藏侧栏 ⌃⌘S"))
            #endif

            if collapsed {
                Button(action: orbClicked) {
                    AssistantAvatar(theme: model.currentTheme, hostID: model.activeHostID, bleed: 1.3)
                        .frame(width: 26, height: 26)
                        .paloOrbHome()
                        // The orb is drawn apart and takes no clicks itself:
                        // without a shape of its own the button had none to
                        // take (a click on it did nothing).
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $paloShown, arrowEdge: .top) {
                    // Made only while open (its conversation, its composer).
                    if let palo = model.store {
                        PaloPopover(model: model, store: palo, voice: voice)
                    }
                }
                .accessibilityLabel(store.assistantName.isEmpty ? "Palo" : store.assistantName)
                #if targetEnvironment(macCatalyst)
                .help(Text("和 Palo 说话"))
                #endif
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: .demoTogglePaloPopover)) { note in
                    guard (note.object as? WindowModel) === model else { return }
                    orbClicked()
                }
                #endif

                if !waiting.isEmpty || !done.isEmpty {
                    Button { listShown.toggle() } label: {
                        Text(summary(waiting: waiting.count, done: done.count))
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .lineLimit(1)
                            .padding(.trailing, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-capsule-counts")
                    .popover(isPresented: $listShown, arrowEdge: .top) {
                        AttentionList(waiting: waiting, done: done) { pal in
                            listShown = false
                            model.jump(toSession: pal)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 1)
        .frame(height: 34)
        .tint(.primary) // chrome stays neutral
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy, value: collapsed)
        .animation(.snappy, value: waiting.count)
        .animation(.snappy, value: done.count)
    }

    /// The Mac: Palo's conversation in a popover from the orb (again: it
    /// closes); on an iPad, Palo's conversation here.
    private func orbClicked() {
        if Platform.isMac {
            debugLog("[windows] capsule orb clicked in \(model.traceName): Palo's popover \(paloShown ? "closing" : "opening")")
            paloShown.toggle()
        } else {
            model.openPalo()
        }
    }

    /// "2 等你 · 1 做完", only what isn't zero.
    private func summary(waiting: Int, done: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append(String(localized: "\(waiting) 等你")) }
        if done > 0 { parts.append(String(localized: "\(done) 做完")) }
        return parts.joined(separator: " · ")
    }
}

/// The capsule's popover: the sessions that wait on the owner, then the ones
/// that finished, a dot, the name and one line each.
private struct AttentionList: View {
    let waiting: [Pal]
    let done: [Pal]
    let pick: (Pal) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(waiting + done) { pal in
                    Button { pick(pal) } label: {
                        HStack(spacing: 10) {
                            StatusDot(pal, size: 9).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pal.displayName).font(.body).lineLimit(1)
                                Text(Copy.palLine(pal))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("attention-\(pal.id)")
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .frame(height: min(360, CGFloat(waiting.count + done.count) * 50 + 14))
        .presentationCompactAdaptation(.popover)
    }
}

/// The Mac: Palo's conversation in a popover from the collapsed sidebar's
/// orb, instead of a window of its own: the same conversation as Palo's page
/// (the same store, the same unsent words), its own scroll. Hosted as Palo's
/// pane in a workspace is (a tile of its own): holding to talk here talks to
/// Palo, the voice's panel, scrim and words show in here, and its orb drops
/// out from the popover's top to listen.
struct PaloPopover: View {
    let model: WindowModel
    let store: AppStore
    let voice: VoiceInputController

    /// Its voice and focus owner (`voice.owner`, `ComposerFocus`).
    static let id = "palo-popover"
    static let size = CGSize(width: 420, height: 640)

    var body: some View {
        ChatView(inTile: true)
            .environment(\.tile, TileContext(id: Self.id, isActive: true))
            .chatDraft(model.draftBox(.palo))
            .environment(\.fileLinks, FileLinkContext(scope: .palo, resolver: .shared(for: store)))
            .environment(\.placesAsColumns, false)
            .overlay { TilePaloOrb(owner: Self.id, from: CGPoint(x: Self.size.width / 2, y: 0)) }
            // Presented apart from the window: its theme too.
            .appTheme(model.currentTheme)
            .environment(model)
            .environment(store)
            .environment(voice)
            .frame(width: Self.size.width, height: Self.size.height)
            .presentationCompactAdaptation(.popover)
            .onAppear {
                model.paloPopoverUp = true
                debugLog("[windows] Palo's popover up in \(model.traceName)")
            }
            .onDisappear {
                model.paloPopoverUp = false
                debugLog("[windows] Palo's popover gone in \(model.traceName)")
            }
    }
}
