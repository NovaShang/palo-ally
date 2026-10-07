import PaloAllyKit
import SwiftUI
import UIKit

/// The theme color, which is also the assistant's color — the main thing
/// the owner makes their own. Each assistant (paired computer) has one, kept
/// on that computer (settings.color) and picked when naming it, in 设置 →
/// 主题色 or in 我的助理; the app takes the current assistant's color.
/// 洋红 is the default — the owner's color (#D156A7). The app icon follows
/// the first assistant (alternate icons rendered by scripts/make_icons.sh
/// from these colors).
enum AppTheme: String, CaseIterable, Identifiable {
    case magenta, orchid, rose, berry, blue, violet, teal, orange, graphite

    static let storageKey = "themeColor"
    static let `default` = AppTheme.magenta

    var id: String { rawValue }

    var name: String {
        switch self {
        case .magenta: "洋红"
        case .orchid: "品红"
        case .rose: "玫红"
        case .berry: "深洋红"
        case .blue: "蓝"
        case .violet: "紫"
        case .teal: "青绿"
        case .orange: "橙"
        case .graphite: "石墨"
        }
    }

    /// Light-mode color, and a slightly more luminous one of the same hue for dark mode.
    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .magenta: (0xD156A7, 0xE06BB8)
        case .orchid: (0xA84FD0, 0xC27BE6)
        case .rose: (0xDE4A7C, 0xEE6E98)
        case .berry: (0xA3307F, 0xC9509F)
        case .blue: (0x2F6FE0, 0x5B8FF0)
        case .violet: (0x6E4BD8, 0x8E72EA)
        case .teal: (0x0F8F84, 0x2BB5A6)
        case .orange: (0xEC7355, 0xF99073)
        case .graphite: (0x4A5260, 0x7C8697)
        }
    }

    /// The avatar's second drop — 「你」, beside the assistant's own color —
    /// picked per preset to stay vivid where the two liquids meet (no muddy
    /// mixes). The app icons use the same pairs (scripts/make_icons.sh).
    private var partnerHex: UInt32 {
        switch self {
        case .magenta: 0x8B6BFF   // violet
        case .orchid: 0xF0609E    // pink
        case .rose: 0xFFB547      // amber
        case .berry: 0xFF7A5C     // coral
        case .blue: 0x2FD3C6      // aqua
        case .violet: 0xFF6FB5    // pink
        case .teal: 0xC6E04A      // lime
        case .orange: 0xFFC93D    // sunflower
        case .graphite: 0x8EC5FF  // ice blue
        }
    }

    /// The two glass colors for the avatar shader (sRGB 0…1): the assistant's
    /// (the light theme color — the glass is the same in both appearances)
    /// and the owner's partner color.
    var glass: (primary: SIMD3<Float>, partner: SIMD3<Float>) {
        (Self.rgb(hex.light), Self.rgb(partnerHex))
    }

    private static func rgb(_ h: UInt32) -> SIMD3<Float> {
        SIMD3(Float((h >> 16) & 0xFF) / 255, Float((h >> 8) & 0xFF) / 255, Float(h & 0xFF) / 255)
    }

    /// The accent: tints, icons, outlines. Adapts to light / dark.
    var color: Color { Color(uiColor: uiColor) }

    /// The same, for UIKit. One instance per preset, made once: a dynamic
    /// UIColor never equals another made the same way, so a fresh one per
    /// call read as "the color changed" on every update — and each chat text
    /// view re-rendered its whole reply on every streamed chunk or scroll.
    var uiColor: UIColor { Self.uiColors[self] ?? .tintColor }

    private static let uiColors: [AppTheme: UIColor] = Dictionary(uniqueKeysWithValues: allCases.map { t in
        let (light, dark) = (UIColor(hex: t.hex.light), UIColor(hex: t.hex.dark))
        return (t, UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    })

    /// The alternate icon for this theme (nil = the primary AppIcon).
    var iconName: String? { self == .default ? nil : "AppIcon-\(rawValue)" }

    /// The single app-wide choice older builds stored; migrated to the first assistant.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .default
    }

    /// Switches the home-screen icon to match (iOS shows its own confirmation).
    @MainActor static func applyIcon(_ theme: AppTheme) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != theme.iconName else { return }
        app.setAlternateIconName(theme.iconName) { error in
            if let error { debugLog("icon switch failed: \(error.localizedDescription)") }
        }
    }
}

/// The color swatches (naming sheet, 设置 → 主题色): a plain circle per
/// preset, ringed with a check on the current one.
struct ThemeSwatches: View {
    @Binding var selection: AppTheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 14) {
            ForEach(AppTheme.allCases) { t in
                let selected = t == selection
                Button {
                    withAnimation(.snappy) { selection = t }
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(t.color.gradient)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(4)
                            .overlay(Circle().strokeBorder(t.color, lineWidth: selected ? 2 : 0))
                        Text(t.name)
                            .font(.caption)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.default
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies the theme app-wide: `.tint` / `.tint` shape styles and
    /// `Color.accentColor` both follow it, and views can read `\.appTheme`.
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
            .tint(theme.color)
            .accentColor(theme.color) // Color.accentColor resolves from this, not from .tint
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
