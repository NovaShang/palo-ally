#if DEBUG
import simd
import SwiftUI

/// A comparison sample, not shipped: the two drops drawn two ways over a
/// busy conversation, following the same TwoDropsState motion.
///   A — our TwoDrops shader alone (colored glass, thickness-based see-through).
///   C — what the app uses: system Liquid Glass (GlassDropsView) with the
///       shader over it for depth and highlights.
/// Open with `-demoScreen glassDrops`, or long-press the 「它」 header avatar.
struct GlassDropsDemo: View {
    var theme: AppTheme
    var close: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var engine: GlassDemoEngine
    @State private var appearance: ColorScheme?

    init(theme: AppTheme, close: (() -> Void)? = nil) {
        self.theme = theme
        self.close = close
        _engine = State(initialValue: GlassDemoEngine(theme: theme))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
            let frame = engine.frame(at: ctx.date.timeIntervalSinceReferenceDate,
                                     dark: scheme == .dark, scale: Float(displayScale))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(phase: frame.phase)
                    // Side by side where there's room (iPad, Mac); stacked on a phone.
                    ViewThatFits(in: .horizontal) {
                        grid(frame.uniforms)
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(Variant.allCases) { v in section(v, frame.uniforms) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(appearance)
    }

    private func grid(_ u: [Float]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    ForEach(Variant.allCases) { v in
                        Text(v.title).font(.subheadline.bold()).frame(width: 240, alignment: .leading)
                    }
                }
                GridRow {
                    ForEach(Variant.allCases) { v in
                        cell(v, u, size: 56)
                            .frame(width: 240, height: 120)
                            .background { ChatBackdrop() }
                            .clipShape(.rect(cornerRadius: 14))
                    }
                }
                GridRow {
                    ForEach(Variant.allCases) { v in
                        cell(v, u, size: 150)
                            .frame(width: 240, height: 240)
                            .background { ChatBackdrop() }
                            .clipShape(.rect(cornerRadius: 14))
                    }
                }
            }
            ForEach(Variant.allCases) { v in
                Text("\(v.title)：\(v.note)").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func header(phase: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("两滴 · 两种做法").font(.title3.bold())
                Spacer()
                if let close {
                    Button("完成", action: close).buttonStyle(.glass)
                }
            }
            HStack {
                Text("现在：\(phase)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Picker("外观", selection: $appearance) {
                    Text("跟随").tag(ColorScheme?.none)
                    Text("浅").tag(ColorScheme?.some(.light))
                    Text("深").tag(ColorScheme?.some(.dark))
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
    }

    private func section(_ v: Variant, _ u: [Float]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(v.title).font(.headline)
            Text(v.note).font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 0) {
                cell(v, u, size: 56).frame(maxWidth: .infinity)
                cell(v, u, size: 150).frame(maxWidth: .infinity)
            }
            .frame(height: 230)
            .background { ChatBackdrop() }
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    /// One drawing at a given size; the canvas spills past it like the app's
    /// orb does (bleed 1.33), so motion never clips.
    @ViewBuilder
    private func cell(_ v: Variant, _ u: [Float], size: CGFloat) -> some View {
        let canvas = size * 1.33
        ZStack {
            switch v {
            case .shader:
                shader(u, canvas: canvas)
            case .glass:
                GlassDropsView(uniforms: u, canvas: canvas)
            }
        }
        .frame(width: canvas, height: canvas)
        .frame(width: size, height: size)
    }

    private func shader(_ u: [Float], canvas: CGFloat) -> some View {
        Rectangle()
            .fill(.black)
            .colorEffect(ShaderLibrary.twoDrops(.float2(CGSize(width: canvas, height: canvas)), .floatArray(u)))
            .frame(width: canvas, height: canvas)
    }

    enum Variant: Int, CaseIterable, Identifiable {
        case shader, glass
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .shader: "A · 只用 shader"
            case .glass: "C · 现用"
            }
        }
        var note: String {
            switch self {
            case .shader: "立体、厚薄深浅、自己画的高光；背后只按透明度透一点，不折射。"
            case .glass: "系统玻璃负责折射、边缘光和融合，shader 叠在上面补颜色深浅和高光。"
            }
        }
    }
}

/// Drives one TwoDropsState through a loop: rest, a send, thinking (orbit),
/// a streamed reply, done (merge), rest again.
@MainActor
final class GlassDemoEngine {
    private let state: TwoDropsState
    private var last: Double?
    private var start: Double?
    private var fired = Set<Int>()
    private var loop = -1

    init(theme: AppTheme) {
        let c = theme.glass
        state = TwoDropsState(primary: c.primary, partner: c.partner)
    }

    func frame(at now: Double, dark: Bool, scale: Float) -> (uniforms: [Float], phase: String) {
        let dt = Float(min(max(now - (last ?? now), 0), 1.0 / 20))
        last = now
        if start == nil { start = now }
        let t = (now - start!).truncatingRemainder(dividingBy: 12)
        let n = Int((now - start!) / 12)
        if n != loop { loop = n; fired = [] }
        func once(_ id: Int, at time: Double, _ e: TwoDropsState.Event) {
            if t >= time, !fired.contains(id) { fired.insert(id); state.send(e) }
        }
        var i = TwoDropsState.Inputs()
        let phase: String
        switch t {
        case ..<3: phase = "空闲 · 贴在一起"
        case ..<3.6: phase = "你发出消息"; once(0, at: 3, .send)
        case ..<7: phase = "思考中 · 分开绕圈"; i.thinking = true; i.busyness = 0.7
        case ..<8.5: phase = "回复中"; i.streaming = true
        case ..<9.5: phase = "回复完成 · 撞合"; once(1, at: 8.5, .done)
        default: phase = "空闲"
        }
        state.inputs = i
        state.advance(by: dt)
        return (state.uniforms(dark: dark, scale: scale), phase)
    }
}

/// A slice of conversation to sit behind the drops, so what the glass does
/// with the content under it shows.
private struct ChatBackdrop: View {
    var body: some View {
        // Taller than the cell on purpose: lines wrap in full, start at the
        // top and the cell clips the rest.
        Color(.systemBackground)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<3) { _ in
                        Text("好嘞，周六上午 10 点提醒你给妈妈打电话。顺便把下周去上海的机票和酒店也比较了一下，东航和春秋的退改规则差别挺大。")
                        HStack {
                            Spacer(minLength: 40)
                            Text("帮我把下周去上海的机票和酒店比较一下")
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 17))
                        }
                        Text("最便宜的是周二早上的春秋 ¥486，但不能退；东航 ¥620 可以免费改一次。全季（静安寺）¥538，亚朵（南京西路）¥612。")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            }
            .clipped()
    }
}

#endif
