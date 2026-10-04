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
    private var startTask: Task<Void, Never>?

    /// Overlay size in the window's coordinate space (set by the overlay).
    var containerSize: CGSize = .zero
    var bottomInset: CGFloat = 0

    /// Finger down, before we know it's a hold: warm the audio path.
    func prewarm() { dictation.prewarm() }

    func begin() {
        guard !isActive else { return }
        isActive = true
        target = .send
        dictation.errorMessage = nil
        let d = dictation
        startTask = Task { await d.start() }
    }

    /// `point` is in global (window) coordinates.
    func track(_ point: CGPoint) {
        guard isActive else { return }
        let t = VoiceLayout(size: containerSize, bottomInset: bottomInset).target(at: point)
        if t != target { target = t }
    }

    /// Finger lifted. Returns where it was released and the recognized text
    /// ("" when cancelled or nothing was heard).
    func end() async -> (Target, String) {
        let t = target
        isActive = false
        await startTask?.value
        startTask = nil
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

/// Geometry shared by hit-testing and drawing.
struct VoiceLayout {
    let size: CGSize
    let bottomInset: CGFloat

    /// Top of the light "press" arc where the finger starts.
    var pressTop: CGFloat { size.height - (120 + bottomInset) }
    /// Cancel / edit arc buttons sit just above the press area.
    var buttonsBottom: CGFloat { pressTop - 22 }
    var buttonsTop: CGFloat { buttonsBottom - 84 }

    func target(at p: CGPoint) -> VoiceInputController.Target {
        guard size.width > 0 else { return .send }
        if p.y >= pressTop - 8 { return .send }
        return p.x < size.width / 2 ? .cancel : .edit
    }
}

/// WeChat-style "hold to talk" screen: dimmed backdrop, a big bubble with the
/// live transcription, a hint, two arc targets (取消 / 编辑) and the press
/// area under the finger. Purely visual — hit testing is off so the
/// composer's gesture keeps tracking the finger.
struct VoiceInputOverlay: View {
    let voice: VoiceInputController

    var body: some View {
        GeometryReader { geo in
            // The reader ignores the safe area, so its size is the whole
            // window (matching the global coordinates the gesture reports).
            let full = geo.size
            let layout = VoiceLayout(size: full, bottomInset: geo.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                Color.black.opacity(0.62)

                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    TranscriptBubble(text: voice.transcript,
                                     error: voice.dictation.errorMessage,
                                     level: voice.dictation.level,
                                     cancelling: voice.target == .cancel)
                        .padding(.horizontal, 24)
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                        .animation(.snappy, value: voice.target)
                }
                .frame(height: layout.buttonsTop - 24)

                ArcButton(title: "取消", side: .leading, highlighted: voice.target == .cancel)
                    .frame(width: full.width / 2 - 14, height: layout.buttonsBottom - layout.buttonsTop)
                    .position(x: full.width / 4 - 2, y: (layout.buttonsTop + layout.buttonsBottom) / 2)

                ArcButton(title: "编辑", side: .trailing, highlighted: voice.target == .edit)
                    .frame(width: full.width / 2 - 14, height: layout.buttonsBottom - layout.buttonsTop)
                    .position(x: full.width * 3 / 4 + 2, y: (layout.buttonsTop + layout.buttonsBottom) / 2)

                PressArc(highlighted: voice.target == .send, level: voice.dictation.level)
                    .frame(width: full.width, height: full.height - layout.pressTop)
                    .position(x: full.width / 2, y: (layout.pressTop + full.height) / 2)
            }
            .frame(width: full.width, height: full.height)
            .onAppear { voice.containerSize = full; voice.bottomInset = geo.safeAreaInsets.bottom }
            .onChange(of: full) { _, s in voice.containerSize = s }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .sensoryFeedback(.selection, trigger: voice.target)
        .transition(.opacity)
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

private struct TranscriptBubble: View {
    let text: String
    let error: String?
    let level: Float
    let cancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error, text.isEmpty {
                Text(error).font(.title3)
            } else if text.isEmpty {
                Text("在听…").font(.title2).opacity(0.6)
            } else {
                Text(text)
                    .font(.title2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Waveform(level: level)
                .frame(height: 18)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(cancelling ? Color.primary : Color.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cancelling ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(Color.accentColor.gradient),
                    in: .rect(cornerRadius: 28, style: .continuous))
        .animation(.snappy, value: text)
        .animation(.snappy, value: cancelling)
    }
}

/// Small live bar meter.
private struct Waveform: View {
    let level: Float
    private let bars = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = (sin(t * 9 + Double(i) * 0.8) + 1) / 2
                    let h = 0.18 + 0.82 * Double(level) * (0.35 + 0.65 * wobble)
                    Capsule().frame(width: 3, height: max(3, 18 * h))
                }
            }
            .opacity(0.85)
        }
    }
}

/// One of the two curved targets above the press area.
private struct ArcButton: View {
    enum Side { case leading, trailing }
    let title: String
    let side: Side
    let highlighted: Bool

    var body: some View {
        ArcShape(side: side)
            .fill(highlighted ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(.ultraThinMaterial))
            .overlay {
                Text(title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(highlighted ? Color.black : Color.white)
                    .rotationEffect(.degrees(side == .leading ? -7 : 7))
                    .offset(y: 6)
            }
            .scaleEffect(highlighted ? 1.06 : 1)
            .animation(.snappy(duration: 0.18), value: highlighted)
    }
}

/// Pill tilted like a slice of a big circle: the outer end dips down.
private struct ArcShape: Shape {
    let side: ArcButton.Side

    func path(in r: CGRect) -> Path {
        let dip = r.height * 0.32
        var p = Path()
        // Top edge bows upward toward the screen centre.
        let outerTop = CGPoint(x: side == .leading ? r.minX : r.maxX, y: r.minY + dip)
        let innerTop = CGPoint(x: side == .leading ? r.maxX - r.height / 2 : r.minX + r.height / 2, y: r.minY)
        let outerBottom = CGPoint(x: outerTop.x, y: r.maxY)
        let innerBottom = CGPoint(x: innerTop.x, y: r.maxY - dip)
        p.move(to: outerTop)
        p.addQuadCurve(to: innerTop, control: CGPoint(x: (outerTop.x + innerTop.x) / 2, y: r.minY + dip * 0.2))
        // Rounded inner end.
        let endCenter = CGPoint(x: innerTop.x, y: (innerTop.y + innerBottom.y) / 2)
        let radius = (innerBottom.y - innerTop.y) / 2
        p.addArc(center: endCenter, radius: radius,
                 startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: side != .leading)
        p.addQuadCurve(to: outerBottom, control: CGPoint(x: (outerTop.x + innerTop.x) / 2, y: r.maxY - dip * 0.8))
        p.closeSubpath()
        return p
    }
}

/// The big light arc under the finger.
private struct PressArc: View {
    let highlighted: Bool
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: 0, y: h * 0.42))
                p.addQuadCurve(to: CGPoint(x: w, y: h * 0.42), control: CGPoint(x: w / 2, y: -h * 0.36))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color(white: highlighted ? 0.92 : 0.7), Color(white: highlighted ? 0.8 : 0.6)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .center) {
                Image(systemName: "waveform")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(highlighted ? 0.55 : 0.3))
                    .symbolEffect(.variableColor.iterative, isActive: highlighted)
                    .offset(y: h * 0.12)
            }
        }
        .animation(.snappy(duration: 0.18), value: highlighted)
    }
}
