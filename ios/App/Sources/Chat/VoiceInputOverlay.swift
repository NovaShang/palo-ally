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
    }
    let dictation = SpeechDictation()

    /// The composer capsule's size (measured by it).
    var capsuleSize: CGSize = .zero

    /// Finger down, before we know it's a hold: warm the audio path.
    func prewarm() { dictation.prewarm() }

    func begin() {
        guard !isActive else { return }
        isActive = true
        target = .send
        dictation.start()
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
        guard isActive else { return }
        isActive = false
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

/// Hold-to-talk panel in our glass language (after bento's VoiceGlassPanel):
/// a glass transcript bubble and two glass drop zones, floating just above
/// the composer, which is itself the "release to send" zone. Drawn by the
/// composer (anchored to it), purely visual — the composer's gesture keeps
/// tracking the finger.
struct VoiceInputPanel: View {
    let voice: VoiceInputController
    @State private var shown = false

    var body: some View {
        VStack(spacing: 14) {
            VoiceBubble(text: voice.transcript,
                        error: voice.dictation.errorMessage,
                        level: voice.dictation.level,
                        cancelling: voice.target == .cancel)
                .frame(maxWidth: 420)
                .scaleEffect(shown ? 1 : 0.86, anchor: .bottom)
                .offset(y: shown ? 0 : 30)
                .opacity(shown ? 1 : 0)
            HStack(spacing: 16) {
                VoiceZone(icon: "xmark", title: "取消", tint: .red, hot: voice.target == .cancel)
                VoiceZone(icon: "character.cursor.ibeam", title: "编辑", tint: .accentColor, hot: voice.target == .edit)
            }
            .frame(height: 50)
            .padding(.horizontal, 6)
            .scaleEffect(shown ? 1 : 0.7, anchor: .bottom)
            .offset(y: shown ? 0 : 20)
            .opacity(shown ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { shown = true } }
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

/// The glass live-transcript bubble: newest lines pinned at the bottom.
private struct VoiceBubble: View {
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(cancelling ? Color.red : .secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                LevelBars(level: level).frame(height: 16)
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
            .font(.title3)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Window the newest lines, like a log tail.
            .frame(maxHeight: 200, alignment: .bottom)
            .clipped()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .modifier(VoiceGlassChrome(shape: .roundedRect)) // bento's voice glass
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .opacity(cancelling ? 0.55 : 1)
        .animation(.snappy, value: text)
        .animation(.snappy, value: cancelling)
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
