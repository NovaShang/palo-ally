import PaloAllyKit
import SwiftUI

/// The Mac: a page's top the way the assistant's conversation has it (its
/// orb's strip, ChatView). Under the window's transparent titlebar a
/// navigation bar draws a translucent band; instead the page runs to the
/// window's top and its title, a small status line and its menu float in a
/// strip just below the titlebar, the content passing softly beneath (a
/// `safeAreaBar`, so the system's soft scroll edge). Phones and iPads keep
/// their system navigation bars.
struct MacPageStrip: View {
    let title: String
    var subtitle: String = ""
    /// A dot before the status line (a session's state, as on its row).
    var dot: StatusDotKind? = nil
    /// A page pushed in a column: back to the one before.
    var back: (() -> Void)? = nil
    var trailing: AnyView? = nil
    /// The title as the glass capsule at the left (a session's and Palo's
    /// page, TitleCapsule), in place of the centered title.
    var capsule: AnyView? = nil

    var body: some View {
        if let capsule {
            HStack(spacing: 8) {
                if let back {
                    MacStripButton(action: back) { Image(systemName: "chevron.backward") }
                        .keyboardShortcut("[", modifiers: .command)
                        .accessibilityLabel("返回")
                }
                capsule
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            .tint(.primary)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: 34)
        } else {
            centered
        }
    }

    private var centered: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page-title")
                if !subtitle.isEmpty {
                    HStack(spacing: 5) {
                        if let dot {
                            StatusDot(dot, size: 6)
                        }
                        Text(subtitle)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("page-status")
                }
            }
            .padding(.horizontal, 64)
            .animation(.snappy, value: subtitle)
            HStack(spacing: 8) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel("返回")
                }
                Spacer(minLength: 0)
                if let trailing {
                    trailing
                }
            }
        }
        .tint(.primary) // chrome stays neutral; the theme color is for 发送
        // Compact, like the orb's strip: the system's scroll edge ends at its bottom.
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, minHeight: 34)
    }
}

/// A round glass button for the strip's trailing side (⋯, ✕).
struct MacStripButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// A menu as a round glass button, for the strip (the Mac draws a plain menu
/// as a bordered pop-up).
struct MacStripMenu<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// The Mac: no navigation bar; the strip at the top instead. Elsewhere nothing changes.
struct MacPageTop: ViewModifier {
    let strip: MacPageStrip

    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaBar(edge: .top, spacing: 0) { strip }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

extension View {
    /// The Mac's floating strip in place of this page's navigation bar (MacPageStrip).
    func macPageTop(_ title: String, subtitle: String = "", dot: StatusDotKind? = nil, back: (() -> Void)? = nil,
                    trailing: AnyView? = nil) -> some View {
        modifier(MacPageTop(strip: MacPageStrip(title: title, subtitle: subtitle, dot: dot, back: back, trailing: trailing)))
    }
}

/// A page's ⋯ menu: in the navigation bar on phones and iPads, a round glass
/// button in the strip on the Mac.
struct PageMenu<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if Platform.barInWindowToolbar {
            MacStripMenu(label: label, content: content)
        } else {
            Menu(content: content) {
                Label(label, systemImage: "ellipsis")
            }
            // Chrome stays neutral; the theme color is for 发送.
            .tint(.primary)
        }
    }
}

/// Phones and iPads: the page's menu in the navigation bar. The Mac has it in
/// the page's strip, and no toolbar at all.
struct BarMenu<Item: View>: ViewModifier {
    @ViewBuilder let item: () -> Item

    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content
        } else {
            content.toolbar { ToolbarItem(placement: .topBarTrailing, content: item) }
        }
    }
}
