import os
import PaloAllyKit
import PaloAllyVoice
import SwiftUI

/// State for hold-to-talk. The composer drives it with the finger position;
/// the scrim, the words in the middle of the screen and the drop zones only
/// render it.
@MainActor
@Observable
final class VoiceInputController {
    enum Target: Equatable { case send, cancel, edit }

    /// Where the words go once the finger lifts (design §3.7).
    enum Exit: Equatable {
        /// Into the message just placed, unseen under the scrim, where it
        /// stays in the conversation (at the top of the view).
        case send(cid: String)
        /// Into the composer's field.
        case edit
        /// Toward 取消, dissolving.
        case cancel
        /// Nothing was recognized: 没听清 (or why not), then gone. `edit`:
        /// the finger was on 编辑, so the field opens after.
        case unheard(edit: Bool)
    }

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
    /// drives the whole transition — capsule glow, the zones growing out of
    /// the capsule, the screen scrim, the orb dropping out of the bar — so
    /// arming, committing, and going back are one continuous motion. Set
    /// inside `withAnimation` by the composer (and by the exit, below).
    var presence: CGFloat = 0
    /// The zones and the scrim stay up while `presence` animates back to 0.
    var panelMounted = false {
        didSet { if panelMounted { stageDown = false } }
    }
    /// The scrim and the words are down, a frame ahead of the zones (`done`).
    private var stageDown = false
    let dictation = SpeechDictation()

    /// The composer capsule's size (measured by it).
    var capsuleSize: CGSize = .zero
    /// The capsule in global coordinates. Held still while the words leave
    /// (the field growing with dictated words mustn't move the words).
    private(set) var capsuleFrame: CGRect = .zero

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
        guard MicPermission.micAuthorizedSync() || Self.drillAudio else {
            Task { _ = await MicPermission.ensureMic() }
            return false
        }
        // A new hold (its panel is already going up): the last one's words are gone.
        interruptExit(keepsPanel: true)
        isArmed = true
        target = .send
        dictation.start()
        return true
    }

    /// The voice drill feeds its own audio, or its own words (no mic needed).
    private static var drillAudio: Bool {
        #if DEBUG
        VoiceDrill.syntheticAudio || SpeechDictation.drillScript != nil
        #else
        false
        #endif
    }

    /// Held past the threshold: the same recording becomes the hold-to-talk session.
    func commit() {
        guard isArmed, !isActive else { return }
        isArmed = false
        isActive = true
        target = .send
        #if DEBUG
        VoiceFrames.shared.warm()
        #endif
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
        interruptExit()
        guard isActive || isArmed else { return }
        isActive = false
        isArmed = false
        dictation.cancel()
    }

    // MARK: after release: the words' way out (design §3.7)

    /// What the words are doing now that the finger has lifted; nil while
    /// listening, and once they're gone.
    private(set) var exit: Exit?
    /// The words as they were when they started to leave (the live
    /// transcript may still change, or be cleared).
    private(set) var exitWords = ""
    /// The way out: false → true in one animation with `presence`.
    private(set) var landed = false
    /// Released with nothing heard yet: the final words are being worked
    /// out (识别中…). The zones and the orb have gone; the scrim stays.
    private(set) var resolving = false
    /// The scrim stays up even as `presence` falls (while resolving).
    private(set) var holdsScrim = false
    /// The message (its client id) kept invisible in the conversation while
    /// its words fly into it. The flying copy takes its place at landing.
    private(set) var hiddenEcho: String?
    /// The message whose flying copy is drawn (a frame longer than it's
    /// hidden: at landing the two are one, then the copy goes).
    private(set) var copyOf: String?
    /// The composer's field is blank while the words fly into it (`.edit`)
    /// and fades in as they land.
    private(set) var veilsField = false
    /// Where the hidden message is, in global coordinates: its whole row and
    /// its bubble.
    private(set) var echoRow: CGRect?
    private(set) var echoBubble: CGRect?
    /// The composer's text field, in global coordinates.
    private(set) var fieldFrame: CGRect = .zero
    /// The words on screen, in global coordinates: what's visible of the
    /// text itself, and the block they're laid out in. Held still once they
    /// start to leave (their own motion would move them).
    private(set) var wordsFrame: CGRect = .zero
    private(set) var wordsBlock: CGRect = .zero

    /// Anything of voice on screen: the zones, the scrim, the words.
    var mounted: Bool { (panelMounted && !stageDown) || exit != nil || resolving }
    var scrimOpacity: CGFloat { holdsScrim ? 1 : presence }

    /// Told when an exit is over (the composer opens the keyboard after `.edit`).
    @ObservationIgnored var onExitDone: ((Exit) -> Void)?
    /// Counts exits, so a late completion of an interrupted one does nothing.
    @ObservationIgnored private var exitGeneration = 0
    /// Waiting for the hidden message to have its place.
    @ObservationIgnored private var awaitingEcho = false

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    /// The way out, all of it in one motion: the words, the scrim, the zones,
    /// the capsule's glow and the orb going back into the bar. With Reduce
    /// Motion a cross-fade: nothing moves.
    static var exitMotion: Animation { reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.45) }

    /// Released with nothing heard yet: the zones and the orb go back, the
    /// scrim stays, 识别中….
    func resolve() {
        resolving = true
        holdsScrim = true
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { presence = 0 }
    }

    /// The words leave. `.send` waits for the hidden message to be laid out
    /// (a frame, at most a quarter of a second) and `.edit` a frame for the
    /// field to take the words; `.unheard` shows a moment first.
    func leave(_ e: Exit, words: String) {
        exitGeneration += 1
        let g = exitGeneration
        exit = e
        exitWords = words
        landed = false
        resolving = false
        let flies = !Self.reduceMotion
        switch e {
        case .send(let cid):
            if flies {
                hiddenEcho = cid
                copyOf = cid
                awaitingEcho = true
            }
            // A reply being written below doesn't move the list while the
            // words fly (the place they land on stays put).
            DisplayLinkRevealClock.hold(seconds: 0.6)
        case .edit:
            if flies { veilsField = true }
            debugLog("[voice] exit edit: the field was at y \(Int(fieldFrame.minY))…\(Int(fieldFrame.maxY))")
        case .cancel, .unheard:
            break
        }
        debugLog("[voice] exit \(Self.name(e)): \(words.count) characters\(flies ? "" : " (cross-fade)")")
        ChatSignposts.chat.emitEvent("voice", "exit")
        #if DEBUG
        VoiceFrames.shared.start(Self.name(e))
        #endif
        Task { @MainActor [weak self] in
            switch e {
            case .send:
                guard flies else { break }
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, g == self.exitGeneration, self.awaitingEcho else { return }
                // Never laid out where it can be seen: no flight, a fade.
                debugLog("[voice] exit send: the message had no place on screen after 250 ms, fading")
                self.awaitingEcho = false
                self.hiddenEcho = nil
                self.copyOf = nil
            case .edit:
                // At once: the field's place, once it has taken the
                // words, retargets the flight (`placeField`).
                break
            case .unheard:
                try? await Task.sleep(for: .seconds(0.8))
            case .cancel:
                break
            }
            guard let self, g == self.exitGeneration else { return }
            self.go(g)
        }
    }

    /// Until the words have gone (at most a second and a half).
    func whenGone() async {
        for _ in 0..<90 where exit != nil {
            try? await Task.sleep(for: .milliseconds(17))
        }
    }

    /// The hidden message's place (its row, its bubble), from the
    /// conversation: once it's on screen, the words fly to it; if it moves
    /// on the way, they follow it.
    func placeEcho(row: CGRect? = nil, bubble: CGRect? = nil) {
        let set = {
            if let row { self.echoRow = row }
            if let bubble { self.echoBubble = bubble }
        }
        if landed { withAnimation(.smooth(duration: 0.25), set) } else { set() }
        guard awaitingEcho, let r = echoRow, echoBubble != nil else { return }
        // Not there yet: the list is still on its way back to the end.
        guard r.maxY > 0, r.minY < (capsuleFrame.height > 0 ? capsuleFrame.minY : .greatestFiniteMagnitude) else { return }
        awaitingEcho = false
        // A turn later: the list may still be settling it in the same
        // update (the Mac reported it at the bottom first, then at the top).
        let g = exitGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, g == self.exitGeneration, let r = self.echoRow else { return }
            debugLog("[voice] exit send: the message is at y \(Int(r.minY)), \(Int(r.height)) pt tall; the words are at y \(Int(self.wordsFrame.minY))")
            self.go(g)
        }
    }

    func placeField(_ frame: CGRect) {
        guard Self.moved(fieldFrame, frame) else { return }
        if exit == .edit { debugLog("[voice] exit edit: the field is at y \(Int(frame.minY))…\(Int(frame.maxY)); the words at y \(Int(wordsFrame.minY))") }
        if exit == .edit, landed { withAnimation(.smooth(duration: 0.25)) { fieldFrame = frame } } else { fieldFrame = frame }
    }

    func placeWords(text: CGRect, block: CGRect) {
        guard exit == nil else { return }
        if text != wordsFrame { wordsFrame = text }
        if block != wordsBlock { wordsBlock = block }
    }

    func placeCapsule(_ frame: CGRect) {
        guard exit == nil, !resolving, Self.moved(capsuleFrame, frame) else { return }
        capsuleFrame = frame
    }

    /// Really moved, not just the capsule swelling as it listens (its scale
    /// shows in the frames measured inside it, every frame of the motion).
    private static func moved(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) > 2 || abs(a.midY - b.midY) > 2
            || abs(a.width - b.width) > max(2, a.width * 0.05) || abs(a.height - b.height) > max(2, a.height * 0.05)
    }

    private func go(_ g: Int) {
        ChatSignposts.chat.emitEvent("voice", "go")
        withAnimation(Self.exitMotion) {
            presence = 0
            holdsScrim = false
            landed = true
            veilsField = false
        } completion: { [weak self] in
            self?.done(g)
        }
    }

    /// Over: the message shows under its flying copy (the same place, so
    /// nothing moves), and everything of voice comes down — all of it
    /// invisible or identical by now, a piece per frame so no one frame
    /// does it all: the copy, then the scrim and the words, then the zones
    /// (and the orb's label comes back).
    private func done(_ g: Int) {
        guard g == exitGeneration, let e = exit else { return }
        ChatSignposts.chat.emitEvent("voice", "swap")
        if hiddenEcho != nil { quietly { hiddenEcho = nil } }
        debugLog("[voice] exit \(Self.name(e)) done")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(17))
            guard let self, g == self.exitGeneration else { return }
            if self.copyOf != nil {
                self.quietly { self.copyOf = nil }
                try? await Task.sleep(for: .milliseconds(17))
                guard g == self.exitGeneration else { return }
            }
            ChatSignposts.chat.emitEvent("voice", "down")
            self.quietly {
                self.stageDown = true
                self.resetExit()
            }
            try? await Task.sleep(for: .milliseconds(17))
            guard !self.isArmed, !self.isActive, self.exit == nil, !self.resolving else { return }
            self.quietly {
                self.panelMounted = false
                self.presence = 0
            }
            #if DEBUG
            VoiceFrames.shared.stop()
            #endif
            self.onExitDone?(e)
        }
    }

    /// A new press, the app leaving: whatever was leaving is gone at once.
    func interruptExit(keepsPanel: Bool = false) {
        guard exit != nil || resolving || holdsScrim else { return }
        exitGeneration += 1
        quietly {
            resetExit()
            if !keepsPanel && !isArmed && !isActive {
                panelMounted = false
                presence = 0
            }
        }
        debugLog("[voice] exit interrupted")
    }

    private func resetExit() {
        hiddenEcho = nil
        copyOf = nil
        exit = nil
        landed = false
        resolving = false
        holdsScrim = false
        veilsField = false
        awaitingEcho = false
        echoRow = nil
        echoBubble = nil
    }

    private func quietly(_ body: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, body)
    }

    static func name(_ e: Exit) -> String {
        switch e {
        case .send: "send"
        case .edit: "edit"
        case .cancel: "cancel"
        case .unheard(let edit): edit ? "unheard (edit)" : "unheard"
        }
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

/// Hold-to-talk drop zones: two glass capsules floating just above the
/// composer — which is itself the "release to send" zone. They grow out of
/// the capsule as `voice.presence` rises and fold back into it as it falls.
/// Drawn by the composer (anchored to it), purely visual — the composer's
/// gesture keeps tracking the finger. The words are in the middle of the
/// screen (`VoiceWordsLayer`).
struct VoiceInputPanel: View {
    let voice: VoiceInputController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = voice.presence
        // With Reduce Motion they only fade.
        let grow = reduceMotion ? 1 : p
        HStack(spacing: 16) {
            VoiceZone(icon: "xmark", title: "取消", tint: .red, hot: voice.target == .cancel)
            VoiceZone(icon: "character.cursor.ibeam", title: "编辑", tint: .accentColor, hot: voice.target == .edit)
        }
        .frame(height: Self.zoneHeight)
        .padding(.horizontal, 6)
        // The zones rise out of the capsule's top edge.
        .scaleEffect(x: 0.55 + 0.45 * grow, y: 0.4 + 0.6 * grow, anchor: .bottom)
        .offset(y: (1 - grow) * 34)
        .opacity(Double(min(1, p * 1.6)))
        .allowsHitTesting(false)
        .sensoryFeedback(.selection, trigger: voice.target)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在听你说话，\(hint)")
    }

    static let zoneHeight: CGFloat = 50
    /// Between the zones and the capsule.
    static let gap: CGFloat = 18

    private var hint: String {
        switch voice.target {
        case .send: "松开 发送"
        case .cancel: "松开 取消"
        case .edit: "松开 编辑"
        }
    }
}

/// The whole screen behind the recording UI, evenly: the listening orb
/// covers the top of the conversation anyway, and an even scrim is what lets
/// the message be placed under it unseen at release (its words then fly into
/// it). The screen's own background, so it follows light / dark mode.
struct VoiceScrim: View {
    let opacity: CGFloat

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .opacity(Double(opacity))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The live words, large, in the middle of the screen between the listening
/// orb and the drop zones (design §3.7), up to about half the screen; longer
/// dictation scrolls like a log tail under a soft top edge. After release
/// they leave in one motion with the scrim, the zones and the orb:
/// - send: they shrink and move into the message, which was placed (unseen,
///   under the scrim) where it stays — at the top of the view — and a copy of
///   that message grows out of them on the way, so at landing the copy and
///   the message are one;
/// - edit: into the composer's field, which fades in under them;
/// - cancel: toward 取消, dissolving;
/// - nothing heard: 没听清 (or why), then they fade.
/// With Reduce Motion they only fade. Above the composer, below the orb.
struct VoiceWordsLayer: View {
    /// Where the phone bar's middle is: the listening orb hangs below it.
    let orbPlacement: OrbPlacement
    @Environment(VoiceInputController.self) private var voice

    var body: some View {
        if voice.mounted {
            GeometryReader { proxy in
                VoiceWordsStage(voice: voice, layer: proxy.frame(in: .global),
                                safeTop: proxy.safeAreaInsets.top, barCenterY: orbPlacement.slot.width > 0 ? orbPlacement.slot.midY : nil)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct VoiceWordsStage: View {
    let voice: VoiceInputController
    /// This layer, in global coordinates (the whole column).
    let layer: CGRect
    let safeTop: CGFloat
    let barCenterY: CGFloat?
    @Environment(AppStore.self) private var store

    /// Words this big become the conversation's body text as they land.
    private static let shrink: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize
        / UIFont.preferredFont(forTextStyle: .title2).pointSize

    var body: some View {
        let motion = !VoiceInputController.reduceMotion
        let landed = voice.landed
        // Between the listening orb and the zones.
        let orbBottom = FloatingTitleOrb.listeningBottom(barCenterY: barCenterY, columnTop: layer.minY + safeTop,
                                                         columnWidth: layer.width)
        let capsule = voice.capsuleFrame
        let zonesTop = capsule.height > 0 ? capsule.minY - VoiceInputPanel.gap - VoiceInputPanel.zoneHeight : layer.maxY - 180
        let top = orbBottom + 20, bottom = max(top + 80, zonesTop - 20)
        let width = min(layer.width - 52, 520)
        let words = VoiceWords(text: shownText, style: style, maxHeight: min(bottom - top, layer.height * 0.5)) {
            voice.placeWords(text: $0, block: $1)
        }
        .frame(width: width)
        let src = voice.wordsFrame, block = voice.wordsBlock
        let way = exitWay(src: src, capsule: capsule)
        ZStack(alignment: .topLeading) {
            words
                // About the words' own middle (they may not fill their block).
                .scaleEffect(landed && motion ? way.scale : 1,
                             anchor: block.width > 0 && block.height > 0
                                ? UnitPoint(x: (src.midX - block.minX) / block.width, y: (src.midY - block.minY) / block.height)
                                : .center)
                .blur(radius: landed && motion && voice.exit == .cancel ? 6 : 0)
                .offset(landed && motion ? way.offset : .zero)
                // They give way to the message's copy as they shrink into
                // it (a long dictation wraps differently there, so the two
                // overlap as little as possible).
                .animation(motion ? .easeIn(duration: 0.24) : VoiceInputController.exitMotion) {
                    $0.opacity(landed ? 0 : 1)
                }
                // Cancelling, the words dissolve faster than the rest goes.
                .transaction(value: landed) { t in
                    if voice.exit == .cancel, motion { t.animation = .easeIn(duration: 0.24) }
                }
                .position(x: layer.width / 2, y: (top + bottom) / 2 - layer.minY)
            if case .send(let cid) = voice.exit, voice.copyOf == cid, motion,
               let row = voice.echoRow, let bubble = voice.echoBubble,
               let echo = store.messages.last(where: { $0.clientMsgId == cid }) {
                let focal = Self.visibleCenter(of: bubble, top: layer.minY + safeTop, bottom: capsule.height > 0 ? capsule.minY : layer.maxY)
                // The message's copy grows out of the words: it starts as
                // big as they are, where they are, and lands on the message.
                MessageRow(message: echo)
                    .environment(\.isVoiceCopy, true)
                    .frame(width: row.width, height: row.height)
                    .scaleEffect(landed ? 1 : 1 / Self.shrink,
                                 anchor: UnitPoint(x: (focal.x - row.minX) / max(1, row.width), y: (focal.y - row.minY) / max(1, row.height)))
                    .offset(landed ? .zero : CGSize(width: src.midX - focal.x, height: src.midY - focal.y))
                    // Gone the frame the message shows (they'd add up), out
                    // of the tree the next.
                    .animation(.easeOut(duration: 0.26).delay(0.1)) { $0.opacity(landed && voice.hiddenEcho == cid ? 1 : 0) }
                    .position(x: row.midX - layer.minX, y: row.midY - layer.minY)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: layer.width, height: layer.height, alignment: .topLeading)
    }

    private var shownText: String {
        switch voice.exit {
        case .unheard: return voice.exitWords
        case .some: return voice.exitWords.isEmpty ? "说吧，我在听…" : voice.exitWords
        case nil:
            if voice.resolving { return "识别中…" }
            let t = voice.transcript
            if let error = voice.dictation.errorMessage, t.isEmpty { return error }
            return t.isEmpty ? "说吧，我在听…" : t
        }
    }

    private var style: VoiceWords.Style {
        switch voice.exit {
        case .unheard: return .note
        case .some: return voice.exitWords.isEmpty ? .placeholder : (voice.exit == .cancel ? .dimmed : .words)
        case nil:
            if voice.resolving { return .placeholder }
            if voice.transcript.isEmpty { return voice.dictation.errorMessage == nil ? .placeholder : .note }
            return voice.target == .cancel ? .dimmed : .words
        }
    }

    /// How the words move and shrink on their way out.
    private func exitWay(src: CGRect, capsule: CGRect) -> (offset: CGSize, scale: CGFloat) {
        func toward(_ p: CGPoint) -> CGSize { CGSize(width: p.x - src.midX, height: p.y - src.midY) }
        switch voice.exit {
        case .send:
            guard let bubble = voice.echoBubble else { return (.zero, 1) }
            let focal = Self.visibleCenter(of: bubble, top: layer.minY + safeTop, bottom: capsule.height > 0 ? capsule.minY : layer.maxY)
            return (toward(focal), Self.shrink)
        case .edit:
            let f = voice.fieldFrame
            guard f.width > 0 else { return (.zero, Self.shrink) }
            return (toward(CGPoint(x: f.midX, y: f.midY)), Self.shrink)
        case .cancel:
            guard capsule.width > 0 else { return (.zero, 0.4) }
            let zone = CGPoint(x: capsule.minX + capsule.width * 0.25,
                               y: capsule.minY - VoiceInputPanel.gap - VoiceInputPanel.zoneHeight / 2)
            return (toward(zone), 0.4)
        case .unheard, nil:
            return (.zero, 0.96)
        }
    }

    /// The middle of what's visible of `r` between `top` and `bottom` (a long
    /// message runs past the screen; the words land on what shows of it).
    static func visibleCenter(of r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPoint {
        let lo = max(r.minY, top), hi = min(r.maxY, bottom)
        return CGPoint(x: r.midX, y: hi > lo ? (lo + hi) / 2 : r.midY)
    }
}

/// The words themselves: large, the newest at the bottom; past `maxHeight`
/// the oldest scroll away under a soft top edge.
private struct VoiceWords: View {
    enum Style { case words, dimmed, placeholder, note }
    let text: String
    let style: Style
    let maxHeight: CGFloat
    /// Where they are (global): what shows of the text itself, and the block.
    let place: (CGRect, CGRect) -> Void
    @State private var natural: CGFloat = 0
    /// Not state: while the words leave, their frames change every frame,
    /// and that mustn't re-render them.
    @State private var frames = Frames()
    private final class Frames {
        var text: CGRect = .zero
        var block: CGRect = .zero
    }

    var body: some View {
        let overflows = natural > maxHeight + 0.5
        Text(text)
            .font(.title2.weight(.medium))
            .lineSpacing(4)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            // The text itself (as wide as its longest line). Its height from
            // its own size: the global frame also carries the words' motion.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                frames.text = f
                report()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // As tall as the words, up to `maxHeight` (the newest at the bottom).
            .frame(height: natural > 0 ? min(natural, maxHeight) : nil, alignment: .bottom)
            .clipped()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                frames.block = f
                report()
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? 48 : 0)
                    Color.black
                }
            }
            .animation(.snappy, value: text)
            .animation(.snappy, value: style)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("voiceWords")
    }

    private func report() {
        let t = frames.text, block = frames.block
        guard block.width > 0 else { return }
        let lo = max(t.minY, block.minY), hi = min(t.maxY, block.maxY)
        place(CGRect(x: t.minX, y: lo, width: t.width, height: max(0, hi - lo)), block)
    }

    private var color: Color {
        switch style {
        case .words: .primary
        case .dimmed: .primary.opacity(0.4)
        case .placeholder: Color(.tertiaryLabel)
        case .note: .secondary
        }
    }
}

extension EnvironmentValues {
    /// A message drawn as the flying copy of itself (`VoiceWordsLayer`):
    /// never hidden by `VoiceEchoSlot`.
    @Entry var isVoiceCopy = false
}

/// On each message sent from here: kept invisible while its words fly into
/// it (`VoiceInputController.hiddenEcho`), telling the flight where it is.
/// Reads only the hidden id, so a voice send re-renders this, not the rows.
struct VoiceEchoSlot: ViewModifier {
    let cid: String?
    /// The bubble itself (its place is where the words land), or the whole row.
    var bubble = false
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.isVoiceCopy) private var isCopy

    func body(content: Content) -> some View {
        let hidden = !isCopy && cid != nil && voice.hiddenEcho == cid
        content
            .opacity(hidden && !bubble ? 0 : 1)
            .background {
                if hidden {
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                        if bubble { voice.placeEcho(bubble: f) } else { voice.placeEcho(row: f) }
                    }
                }
            }
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

#if DEBUG
/// `-frameTrace YES`: how late each frame came from a release until the
/// words have gone and the voice UI is down. One `[frames] voice …` line per
/// release: the first frame (the release's own update, which also lays out
/// the message placed under the scrim) apart, then every later frame over
/// 20 ms. Then a second line for the 0.4 s after (the final words going
/// out, the keyboard for 编辑): not the motion, but it's measured too.
@MainActor
final class VoiceFrames {
    static let shared = VoiceFrames()
    private var link: CADisplayLink?
    private var measuring = false
    private var label = ""
    private var began: CFTimeInterval = 0
    private var last: CFTimeInterval?
    private var gaps: [(at: Double, ms: Double)] = []
    private var after: [(at: Double, ms: Double)]?

    /// Made when a hold commits, so it runs (warm) before the release.
    func warm() {
        guard FrameWatch.on, link == nil else { return }
        let link = CADisplayLink(target: LinkTarget { [weak self] in self?.frame() }, selector: #selector(LinkTarget.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func start(_ label: String) {
        guard FrameWatch.on else { return }
        warm()
        self.label = label
        began = CACurrentMediaTime()
        gaps = []
        after = nil
        measuring = true
    }

    /// The voice UI is down.
    func stop() {
        guard measuring else { return }
        measuring = false
        let first = gaps.first
        let later = gaps.dropFirst()
        debugLog(String(format: "[frames] voice %@: %d frames over %.2f s, first %.0f ms; later worst %.0f ms, over 20 ms: %@",
                        label, gaps.count, CACurrentMediaTime() - began, first?.ms ?? 0, later.map(\.ms).max() ?? 0,
                        Self.slow(later)))
        after = []
        let label = label
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let after = self.after else { return }
            self.after = nil
            debugLog(String(format: "[frames] voice %@, the 0.4 s after: worst %.0f ms, over 20 ms: %@",
                            label, after.map(\.ms).max() ?? 0, Self.slow(after[...])))
        }
    }

    private static func slow(_ g: ArraySlice<(at: Double, ms: Double)>) -> String {
        let s = g.filter { $0.ms > 20 }.map { String(format: "%.0f ms at %.2f s", $0.ms, $0.at) }
        return s.isEmpty ? "none" : s.joined(separator: ", ")
    }

    private func frame() {
        guard let link else { return }
        defer { last = link.timestamp }
        guard let last, link.timestamp > began else { return }
        // From the release on (the first gap spans it).
        let gap = (max(0, last - began), (link.timestamp - last) * 1000)
        if measuring { gaps.append(gap) } else if after != nil { after?.append(gap) }
    }
}
#endif
