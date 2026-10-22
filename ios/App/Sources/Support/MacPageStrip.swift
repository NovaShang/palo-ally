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

/// A round glass button for the strip's trailing side (⋯, ✕): frame, then
/// the hit shape, then the glass, so the whole circle takes the click.
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
        .macMenuHitArea()
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// The Mac: no navigation bar; the strip at the top instead. Elsewhere nothing changes.
struct MacPageTop: ViewModifier {
    let strip: MacPageStrip
    /// A page of the window (an Ally, 电脑与设备): its title in the title bar
    /// row itself (MacTitlebar), not in a strip below it; its menu is the
    /// window toolbar's ⋯ (`macToolbarMenu`).
    var inRow = false

    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar && inRow {
            content
                .toolbar(.hidden, for: .navigationBar)
                .macTitlebarFade()
                .macTitlebarCenter {
                    MacTitlebarTitle(title: strip.title, subtitle: strip.subtitle, dot: strip.dot)
                }
        } else if Platform.barInWindowToolbar {
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
    /// The Mac's floating strip in place of this page's navigation bar
    /// (MacPageStrip); `inRow`: in the window's title bar row (MacTitlebar).
    func macPageTop(_ title: String, subtitle: String = "", dot: StatusDotKind? = nil, back: (() -> Void)? = nil,
                    trailing: AnyView? = nil, inRow: Bool = false) -> some View {
        modifier(MacPageTop(strip: MacPageStrip(title: title, subtitle: subtitle, dot: dot, back: back, trailing: trailing),
                            inRow: inRow))
    }

    /// The Mac: no navigation bar and nothing in its place (a page whose
    /// title is already said above it, as 成果 under the right pane's tabs).
    @ViewBuilder func macBarHidden() -> some View {
        if Platform.barInWindowToolbar { toolbar(.hidden, for: .navigationBar) } else { self }
    }

    /// The Mac draws a menu with the borderless style as an AppKit button
    /// the size of its glyph (an ⋯ took clicks on a strip 5 pt tall); with
    /// the plain style its whole label takes them. Elsewhere borderless.
    @ViewBuilder func macMenuHitArea() -> some View {
        if Platform.isMac { buttonStyle(.plain) } else { buttonStyle(.borderless) }
    }
}

// MARK: - the title bar row

/// The Mac window's title bar is the traffic lights' row, the window
/// toolbar's (docs/workbench-design/mac-titlebar.html), transparent: the
/// page shows through it. A conversation page runs up under it with the
/// system's soft scroll edge (no band, no line); a workspace's tiles start
/// below it, the row painted with the page's background.
/// The row holds the sidebar's button at the left (SidebarCollapse), the
/// page's identity in the middle (MacTitlebarItems), and at the right the
/// toolbar's own items as one group: the page's ⋯, a workspace's ＋, and
/// the right pane's button last (MacToolbar).
enum MacTitlebar {
    /// The traffic lights' middle line, in the window.
    @MainActor static var midY: CGFloat { SidebarChrome.shared.titlebarMidY }
    /// The row's height: the content starts below it.
    @MainActor static var height: CGFloat { midY * 2 }
}

/// A page's title in the row: the name, and a small status line under it.
struct MacTitlebarTitle: View {
    let title: String
    var subtitle = ""
    var dot: StatusDotKind? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("page-title")
            if !subtitle.isEmpty {
                HStack(spacing: 5) {
                    if let dot { StatusDot(dot, size: 6) }
                    Text(subtitle)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("page-status")
            }
        }
        .animation(.snappy, value: subtitle)
    }
}

/// The Mac: the page's identity in the middle of the title bar row, over
/// its column (clear of the sidebar's button and the toolbar's items).
struct MacTitlebarItems<Center: View>: ViewModifier {
    @ViewBuilder let center: () -> Center

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            center()
                .padding(.horizontal, 120)
                .frame(maxWidth: .infinity)
                .frame(height: MacTitlebar.height)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}

/// The Mac: a conversation page under the title bar row has no band and no
/// line where it meets it: the system's soft scroll edge, set explicitly
/// (never the hard one).
struct MacTitlebarFade: ViewModifier {
    func body(content: Content) -> some View {
        // With the navigation bar hidden the soft edge had nothing to sit
        // under, so it never showed: an empty bar stands in for one.
        content
            .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: 1).accessibilityHidden(true) }
            .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

extension View {
    /// The Mac: the page's identity in the title bar row (MacTitlebarItems).
    func macTitlebarCenter<C: View>(@ViewBuilder _ center: @escaping () -> C) -> some View {
        modifier(MacTitlebarItems(center: center))
    }

    /// The Mac: the soft scroll edge under the title bar row in place of the band (MacTitlebarFade).
    func macTitlebarFade() -> some View {
        modifier(MacTitlebarFade())
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

/// A floating round glass button. Catalyst draws `.buttonStyle(.glass)` as an
/// opaque dark fill, so on the Mac the button is plain with the glass applied
/// outside it, the way the page strips do it (MacStripButton); the system
/// glass style stays everywhere else.
struct GlassCircleButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.isMac {
            content
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
    }
}

extension View {
    func glassCircleButton() -> some View { modifier(GlassCircleButtonStyle()) }
}
