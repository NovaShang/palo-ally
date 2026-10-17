import PaloAllyKit
import SwiftUI

/// The Mac app is installed from a DMG and doesn't update itself, while the
/// computer's host does. So the host's version (from hello) is the latest
/// release in practice, and when it is ahead of this app's, the Mac app says
/// so, quietly: a small capsule at the foot of the sidebar and a row in
/// Settings. No network call. Phones and iPads never show it.
enum MacUpdate {
    /// What the release workflow uploads (scripts/release-mac.sh).
    static let downloadURL = URL(string: "https://github.com/NovaShang/palo-ally/releases/latest/download/PaloAlly.dmg")!
    /// The newest version the owner closed the hint for.
    static let dismissedKey = "dismissedMacUpdate"

    /// The host's version when this Mac app is behind it (and, with
    /// `dismissed`, the owner hasn't closed that version); else nil.
    static func newerVersion(app: String, host: String, dismissed: String = "") -> String? {
        guard Platform.isMac else { return nil }
        return AppVersion.updateHint(app: app, host: host, dismissed: dismissed)
    }
}

/// The sidebar's foot: 「Mac 版有新版本 0.1.9」, 下载, and a close that lasts
/// until a newer version comes out. Plain glass; the theme color isn't used.
struct MacUpdateHint: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @AppStorage(MacUpdate.dismissedKey) private var dismissed = ""

    var body: some View {
        if let version = MacUpdate.newerVersion(app: model.clientVersion, host: store.hostVersion, dismissed: dismissed) {
            HStack(spacing: 8) {
                Text("Mac 版有新版本 \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button("下载") { openURL(MacUpdate.downloadURL) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("mac-update-download")
                Button {
                    withAnimation(.snappy) { dismissed = version }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("忽略这个版本")
                .accessibilityIdentifier("mac-update-dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(minHeight: 34)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac-update-hint")
        }
    }
}
