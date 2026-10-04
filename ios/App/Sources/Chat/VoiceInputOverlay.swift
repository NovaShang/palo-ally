import PaloAllyVoice
import SwiftUI

/// State for hold-to-talk. The composer drives it with the finger position;
/// the overlay (drawn over the whole screen) only renders it.
@MainActor
@Observable
final class VoiceInputController {
    enum Target: Equatable { case send, cancel, edit }

    private(set) var isActive = false
    private(set) var target: Target = .send
    /// Static screenshot mode (`-demoScreen voice`): fixed text, no audio.
    private(set) var previewText: String?

    var transcript: String { previewText ?? dictation.transcript }

    func showPreview(_ text: String, target: Target = .send) {
        previewText = text
        self.target = target
        isActive = true
        presence = 1
        panelMounted = true
    }

    /// 0…1: how far the composer has turned into the recording UI. One value
    /// drives the whole transition — capsule glow, the panel growing out of
    /// the capsule, the screen scrim — so arming, committing, and going back
    /// (early release, send, cancel) are one continuous motion. Set inside
    /// `withAnimation` by the composer.
    var presence: CGFloat = 0
    /// The panel and scrim stay up while `presence` animates back to 0.
    var panelMounted = false
    let dictation = SpeechDictation()

    /// The composer capsule's size (measured by it).
    var capsuleSize: CGSize = .zero

    /// Recording, but the hold hasn't committed yet (finger just landed).
    private(set) var isArmed = false

    /// Finger down, before we know it's a hold: warm the audio path.
    func prewarm() { dictation.prewarm() }

    /// Finger landed on the field: start recording right away, so words
    /// spoken before the hold threshold aren't lost. Returns false (and asks
    /// for the mic once) when permission isn't granted yet — nothing records.
    @discardableResult
    func arm() -> Bool {
        guard !isActive, !isArmed else { return isArmed }
        guard MicPermission.micAuthorizedSync() else {
            Task { _ = await MicPermission.ensureMic() }
            return false
        }
        isArmed = true
        target = .send
        dictation.start()
        return true
    }

    /// Held past the threshold: the same recording becomes the hold-to-talk session.
    func commit() {
        guard isArmed, !isActive else { return }
        isArmed = false
        isActive = true
        target = .send
    }

    /// Released or scrolled before the threshold: it was a tap — throw the audio away.
    func disarm() {
        guard isArmed else { return }
        isArmed = false
        dictation.cancel()
    }

    /// `point` is in the composer capsule's coordinates.
    func track(_ point: CGPoint) {
        guard isActive else { return }
        let t = VoiceLayout(size: capsuleSize).target(at: point)
        if t != target { target = t }
    }

    /// Finger lifted. Returns where it was released and the recognized text
    /// ("" when cancelled or nothing was heard).
    func end() async -> (Target, String) {
        let t = target
        isActive = false
        if t == .cancel {
            dictation.cancel()
            return (t, "")
        }
        return (t, await dictation.finish())
    }

    /// Gesture interrupted (e.g. app went to background).
    func abort() {
        guard isActive || isArmed else { return }
        isActive = false
        isArmed = false
        dictation.cancel()
    }
}

/// Hit-testing in the composer capsule's own coordinates: above its top edge
/// the left half is 取消 and the right half 编辑; on it, release sends.
struct VoiceLayout {
    let size: CGSize

    func target(at p: CGPoint) -> VoiceInputController.Target {
        guard size.width > 0, p.y < -10 else { return .send }
        return p.x < size.width / 2 ? .cancel : .edit
    }
}

/// Hold-to-talk panel: the live transcript (bare text over the screen
/// scrim) and two glass drop zones, floating above the composer — which is
/// itself the "release to send" zone. It grows out of the capsule as
/// `voice.presence` rises and folds back into it as it falls. Drawn by the
/// composer (anchored to it), purely visual — the composer's gesture keeps
/// tracking the finger.
struct VoiceInputPanel: View {
    let voice: VoiceInputController

    var body: some View {
        let p = voice.presence
        VStack(spacing: 18) {
            VoiceTranscript(text: voice.transcript,
                            error: voice.dictation.errorMessage,
                            level: voice.dictation.level,
                            cancelling: voice.target == .cancel)
                .frame(maxWidth: 520)
                .opacity(Double(max(0, p * 1.4 - 0.4)))
                .offset(y: (1 - p) * 36)
            HStack(spacing: 16) {
                VoiceZone(icon: "xmark", title: "取消", tint: .red, hot: voice.target == .cancel)
                VoiceZone(icon: "character.cursor.ibeam", title: "编辑", tint: .accentColor, hot: voice.target == .edit)
            }
            .frame(height: 50)
            .padding(.horizontal, 6)
            // The zones rise out of the capsule's top edge.
            .scaleEffect(x: 0.55 + 0.45 * p, y: 0.4 + 0.6 * p, anchor: .bottom)
            .offset(y: (1 - p) * 34)
            .opacity(Double(min(1, p * 1.6)))
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.selection, trigger: voice.target)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在听你说话，\(hint)")
    }

    private var hint: String {
        switch voice.target {
        case .send: "松开 发送"
        case .cancel: "松开 取消"
        case .edit: "松开 编辑"
        }
    }
}

/// The live transcript, straight on the screen (the scrim behind keeps it
/// readable): a small 「在听」 line with the level, then the words, large,
/// newest lines pinned at the bottom.
private struct VoiceTranscript: View {
    let text: String
    let error: String?
    let level: Float
    let cancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(cancelling ? Color.secondary : .red).frame(width: 7, height: 7)
                    .opacity(cancelling ? 1 : 0.6 + 0.4 * Double(level))
                Text(cancelling ? "松开 取消" : "在听")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(cancelling ? Color.red : .secondary)
                    .contentTransition(.opacity)
                LevelBars(level: level, bars: 5).frame(height: 14)
                Spacer(minLength: 0)
            }
            Group {
                if let error, text.isEmpty {
                    Text(error).foregroundStyle(.secondary)
                } else if text.isEmpty {
                    Text("说吧，我在听…").foregroundStyle(.tertiary)
                } else {
                    Text(text).foregroundStyle(.primary)
                }
            }
            .font(.title2.weight(.medium))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Window the newest lines, like a log tail.
            .frame(maxHeight: 260, alignment: .bottom)
            .clipped()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .opacity(cancelling ? 0.4 : 1)
        .animation(.snappy, value: text)
        .animation(.snappy, value: cancelling)
    }
}

/// Full-screen scrim behind the recording UI: the screen's own background
/// rising from the bottom (strong where the transcript and zones sit, clear
/// toward the top), so the live words never blend into the conversation.
/// Follows light / dark mode.
struct VoiceScrim: View {
    let presence: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(.systemBackground).opacity(0), location: 0),
                .init(color: Color(.systemBackground).opacity(0.6), location: 0.28),
                .init(color: Color(.systemBackground).opacity(0.94), location: 0.5),
                .init(color: Color(.systemBackground).opacity(0.98), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .opacity(Double(presence))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One drop zone: a glass capsule that inflates and tints while the finger
/// is over it, so you see where release lands before letting go.
private struct VoiceZone: View {
    let icon: String
    let title: String
    let tint: Color
    let hot: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold))
                .foregroundStyle(hot ? Color.white : tint)
            Text(title).font(.body.weight(.semibold))
                .foregroundStyle(hot ? Color.white : .primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(VoiceGlassChrome(shape: .capsule, tint: hot ? tint : nil)) // bento's zone chrome
        .shadow(color: hot ? tint.opacity(0.45) : .black.opacity(0.15), radius: hot ? 12 : 5, y: 3)
        .scaleEffect(hot ? 1.08 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hot)
    }
}

/// Live input level as a few soft bars.
struct LevelBars: View {
    let level: Float
    var bars = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = (sin(t * 10 + Double(i) * 1.1) + 1) / 2
                    let h = 0.22 + 0.78 * Double(level) * (0.4 + 0.6 * wobble)
                    Capsule().frame(width: 3, height: max(3, 16 * h))
                }
            }
            .foregroundStyle(.tint)
            .frame(maxHeight: .infinity)
        }
    }
}
