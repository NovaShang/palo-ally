import PaloAllyKit
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The list is the floating one: it doesn't claim the orb's resting place
    /// (the capsule has it while the sidebar is away).
    @Entry var inFloatingSidebar = false
}

/// What the detail column needs to know about the Mac's title bar (the same
/// in every window).
@MainActor @Observable
final class SidebarChrome {
    static let shared = SidebarChrome()
    /// The Mac: the title bar's middle line (the traffic lights'), in the window.
    var titlebarMidY: CGFloat = 26
}

/// The sidebar's collapse on the Mac (workbench-prd §8), around the split view:
/// its button is the system's own, in the window toolbar (MacToolbar; the
/// owner, 11-05: no capsule, no Palo orb by the traffic lights);
/// collapsed, the sidebar floats in from the left over the content without
///   pushing it when the mouse is at the window's left edge. It goes when the
///   mouse leaves it (300 ms), when a row is picked, or on Esc.
/// The split view itself keeps doing the collapse (`columnVisibility`, the
/// full width for the detail); this only adds the way back. An iPad has the
/// system's own sidebar button and nothing of this (the owner, 11-02: the
/// capsule looked out of place there, over the system button).
struct SidebarCollapse: ViewModifier {
    let model: WindowModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var peeking = false
    @State private var hideTask: Task<Void, Never>?
    /// Where the traffic lights end and the toolbar's middle line, in the window.
    @State private var inset: CGFloat = 80
    @State private var midY: CGFloat = 26

    private var large: Bool { sizeClass == .regular && model.layout == .split }
    private var canPeek: Bool { large && model.sidebarCollapsed && Platform.isMac }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in refreshChrome() }
            .overlay(alignment: .leading) {
                if canPeek { peekLayer }
            }
            .background {
                // Esc puts the floating sidebar away.
                if peeking {
                    Button("收起侧栏") { hide() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: model.selection) { hide() }
            .onChange(of: canPeek) { _, can in if !can { hide() } }
            .task { refreshChrome() }
    }

    /// The Mac: the window's traffic lights end somewhere, and full screen has none.
    private func refreshChrome() {
        guard Platform.isMac else { return }
        Task { @MainActor in
            for delay in [0, 400, 1200] as [Int] {
                try? await Task.sleep(for: .milliseconds(delay))
                if let c = AppKitBundle.leadingChrome() {
                    inset = c.x + 10
                    midY = c.y
                    SidebarChrome.shared.titlebarMidY = c.y
                }
            }
        }
    }

    // MARK: the floating sidebar

    private var peekLayer: some View {
        ZStack(alignment: .leading) {
            // The hot zone: invisible, a little in from the window's resize edge.
            if !peeking {
                Color.clear
                    .frame(width: 8)
                    .padding(.leading, 3)
                    .padding(.top, 8)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        if case .active = phase { reveal() }
                    }
                    .frame(maxHeight: .infinity)
            }
            if peeking {
                ConversationList()
                    .environment(\.inFloatingSidebar, true)
                    .frame(width: 310)
                    .scrollContentBackground(.hidden)
                    .clipShape(.rect(cornerRadius: 24))
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 8)
                    .padding(8)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: hideTask?.cancel()
                        case .ended: scheduleHide()
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .accessibilityIdentifier("sidebar-peek")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func reveal() {
        hideTask?.cancel()
        guard canPeek, !peeking else { return }
        withAnimation(.easeOut(duration: 0.15)) { peeking = true }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        guard peeking else { return }
        withAnimation(.easeIn(duration: 0.2)) { peeking = false }
    }
}

// MARK: - the Mac's window chrome

#if targetEnvironment(macCatalyst)
extension AppKitBundle {
    /// Where the traffic lights end (0 in full screen, where there are none)
    /// and the middle of the toolbar's line, in the window's own points.
    static func leadingChrome() -> (x: CGFloat, y: CGFloat)? {
        guard let s = call("leadingChrome") else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (CGFloat(p[0]), CGFloat(p[1])) : nil
    }
}
#else
private enum AppKitBundle {
    static func leadingChrome() -> (x: CGFloat, y: CGFloat)? { nil }
}
#endif
