import PaloAllyKit
import SwiftUI

/// The status dot of a title capsule; while the owner holds to talk to this
/// conversation, a small live level bar in its place (workbench-prd §11).
/// `owner` is the tile's session id; nil on a single session page. Reads the
/// controller's own level (`dictation.level`), no second audio tap.
struct VoiceLevelDot: View {
    let kind: StatusDotKind
    let owner: String?
    @Environment(VoiceInputController.self) private var voice

    init(_ kind: StatusDotKind, owner: String?) { self.kind = kind; self.owner = owner }

    var body: some View {
        if voice.isActive && voice.owner == owner {
            LevelBars(level: voice.dictation.level, bars: 3, barWidth: 2.5, tallest: 12)
                .tint(.primary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            StatusDot(kind, size: 8)
        }
    }
}

/// A tile's border glowing softly with the voice while it is the one spoken
/// to. A separate view so only it follows the level.
struct TileVoiceGlow<S: InsettableShape>: View {
    let owner: String
    let shape: S
    @Environment(VoiceInputController.self) private var voice

    var body: some View {
        if voice.isActive && voice.owner == owner {
            let level = Double(min(max(voice.dictation.level, 0), 1))
            shape.strokeBorder(Color.accentColor.opacity(0.35 + 0.65 * level), lineWidth: 1.5 + 1.5 * level)
                .shadow(color: Color.accentColor.opacity(0.15 + 0.35 * level), radius: 6 + 8 * level)
                .animation(.easeOut(duration: 0.12), value: level)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
