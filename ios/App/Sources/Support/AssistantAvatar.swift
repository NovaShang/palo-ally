import SwiftUI

/// The assistant's face: a code-drawn blob of liquid glass, tinted by the
/// theme color. Still when idle; it breathes and ripples gently while the
/// assistant is working. No image assets — each style is a few harmonics on
/// a circle, so it scales to any size and follows the theme.
struct AvatarStyle: Identifiable, Hashable {
    /// One wobble around the rim: k lobes, how deep, where, how fast it drifts.
    struct Wave: Hashable { var k: Double; var amp: Double; var phase: Double; var speed: Double }

    let id: String
    let name: String
    let waves: [Wave]
    var stretch: CGSize = CGSize(width: 1, height: 1)
    var twin = false

    static let all: [AvatarStyle] = [
        AvatarStyle(id: "drop", name: "水滴", waves: [.init(k: 1, amp: 0.10, phase: 0.6, speed: 0.7), .init(k: 2, amp: 0.06, phase: 1.2, speed: 1.1), .init(k: 3, amp: 0.03, phase: 0.2, speed: 1.6)],
                    stretch: CGSize(width: 0.95, height: 1.05)),
        AvatarStyle(id: "orb", name: "圆球", waves: [.init(k: 2, amp: 0.035, phase: 0, speed: 0.8), .init(k: 3, amp: 0.025, phase: 1, speed: 1.3), .init(k: 5, amp: 0.012, phase: 2, speed: 1.9)]),
        AvatarStyle(id: "petal", name: "花瓣", waves: [.init(k: 5, amp: 0.11, phase: 0, speed: 0.5), .init(k: 10, amp: 0.018, phase: 1, speed: 1.2)]),
        AvatarStyle(id: "wave", name: "涟漪", waves: [.init(k: 3, amp: 0.09, phase: 0.4, speed: 0.9), .init(k: 7, amp: 0.032, phase: 1.7, speed: 1.5)]),
        AvatarStyle(id: "pebble", name: "卵石", waves: [.init(k: 2, amp: 0.12, phase: 0.8, speed: 0.6), .init(k: 3, amp: 0.04, phase: 0.1, speed: 1.1)],
                    stretch: CGSize(width: 1.06, height: 0.94)),
        AvatarStyle(id: "bloom", name: "绽放", waves: [.init(k: 6, amp: 0.07, phase: 0, speed: 0.7), .init(k: 12, amp: 0.014, phase: 0.5, speed: 1.4)]),
        AvatarStyle(id: "comet", name: "彗星", waves: [.init(k: 1, amp: 0.17, phase: 2.3, speed: 0.6), .init(k: 2, amp: 0.07, phase: 0.4, speed: 1.0), .init(k: 4, amp: 0.02, phase: 1, speed: 1.7)]),
        AvatarStyle(id: "twin", name: "双生", waves: [.init(k: 2, amp: 0.04, phase: 0.3, speed: 0.9), .init(k: 3, amp: 0.03, phase: 1.4, speed: 1.4)], twin: true),
    ]

    static let `default` = all[0]

    /// "" or an unknown id → the default form.
    static func named(_ id: String) -> AvatarStyle { all.first { $0.id == id } ?? .default }
}

struct AssistantAvatar: View {
    var style: AvatarStyle
    var tint: Color
    /// Working: the form breathes and its rim drifts.
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ id: String, tint: Color, active: Bool = false) {
        self.style = AvatarStyle.named(id)
        self.tint = tint
        self.active = active
    }

    var body: some View {
        let moving = active && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { ctx in
            let t = moving ? ctx.date.timeIntervalSinceReferenceDate : 0
            Canvas { g, size in draw(in: &g, size: size, t: t) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func draw(in g: inout GraphicsContext, size: CGSize, t: Double) {
        let s = min(size.width, size.height)
        let breathe = 1 + (t == 0 ? 0 : 0.025 * sin(t * 1.6))
        let light = tint.mix(with: .white, by: 0.5)
        let deep = tint.mix(with: .black, by: 0.28)
        if style.twin {
            // A smaller companion behind, down and to the right.
            let c2 = CGPoint(x: s * 0.62, y: s * 0.6)
            let p2 = blob(center: c2, radius: s * 0.26 * breathe, t: t + 2.1)
            glass(&g, path: p2, size: s * 0.6, light: light.mix(with: tint, by: 0.4), deep: deep.mix(with: .black, by: 0.1))
            let c1 = CGPoint(x: s * 0.42, y: s * 0.42)
            glass(&g, path: blob(center: c1, radius: s * 0.3 * breathe, t: t), size: s * 0.7, light: light, deep: deep)
        } else {
            let c = CGPoint(x: s / 2, y: s / 2)
            glass(&g, path: blob(center: CGPoint(x: c.x, y: c.y - s * 0.02), radius: s * 0.36 * breathe, t: t), size: s, light: light, deep: deep)
        }
    }

    /// One glass body: soft shadow, a lit-from-top-left gradient, an inner
    /// glow, a specular glint and a bright rim.
    private func glass(_ g: inout GraphicsContext, path: Path, size s: CGFloat, light: Color, deep: Color) {
        let r = path.boundingRect
        g.drawLayer { l in
            l.addFilter(.shadow(color: tint.opacity(0.35), radius: s * 0.05, x: 0, y: s * 0.03))
            l.fill(path, with: .color(tint))
        }
        g.fill(path, with: .linearGradient(Gradient(colors: [light, tint, deep]),
                                           startPoint: CGPoint(x: r.minX, y: r.minY),
                                           endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        g.drawLayer { l in
            l.clip(to: path)
            // Light pooled in the upper left, a faint bounce in the lower right.
            l.fill(Path(ellipseIn: r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1).offsetBy(dx: -r.width * 0.28, dy: -r.height * 0.3)),
                   with: .radialGradient(Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                                         center: CGPoint(x: r.minX + r.width * 0.32, y: r.minY + r.height * 0.28),
                                         startRadius: 0, endRadius: r.width * 0.6))
            l.fill(Path(ellipseIn: r),
                   with: .radialGradient(Gradient(colors: [.white.opacity(0.18), .white.opacity(0)]),
                                         center: CGPoint(x: r.maxX - r.width * 0.2, y: r.maxY - r.height * 0.18),
                                         startRadius: 0, endRadius: r.width * 0.35))
        }
        let glint = CGRect(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.16, width: r.width * 0.3, height: r.height * 0.15)
        let rotated = Path(ellipseIn: glint).applying(
            CGAffineTransform(translationX: glint.midX, y: glint.midY).rotated(by: -0.5).translatedBy(x: -glint.midX, y: -glint.midY))
        g.fill(rotated, with: .color(.white.opacity(0.7)))
        g.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: max(0.8, s * 0.018))
    }

    /// A closed wobbly circle: r(θ) = R · (1 + Σ amp · sin(kθ + phase + t·speed)).
    private func blob(center c: CGPoint, radius R: CGFloat, t: Double) -> Path {
        var path = Path()
        let n = 120
        for i in 0...n {
            let th = Double(i) / Double(n) * 2 * .pi
            var f = 1.0
            for w in style.waves { f += w.amp * sin(w.k * th + w.phase + t * w.speed) }
            let p = CGPoint(x: c.x + CGFloat(cos(th) * f) * R * style.stretch.width,
                            y: c.y + CGFloat(sin(th) * f) * R * style.stretch.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// Pick a form: a grid of the eight, the chosen one ringed.
struct AvatarPicker: View {
    @Binding var selection: String
    var tint: Color

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
            ForEach(AvatarStyle.all) { style in
                let on = AvatarStyle.named(selection).id == style.id
                Button { selection = style.id } label: {
                    VStack(spacing: 6) {
                        AssistantAvatar(style.id, tint: tint, active: on)
                            .frame(width: 56, height: 56)
                            .padding(4)
                            .overlay { Circle().strokeBorder(on ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5) }
                        Text(style.name)
                            .font(.caption)
                            .foregroundStyle(on ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack { ForEach(AvatarStyle.all.prefix(4)) { AssistantAvatar($0.id, tint: .pink, active: true).frame(width: 70) } }
        HStack { ForEach(AvatarStyle.all.suffix(4)) { AssistantAvatar($0.id, tint: .pink).frame(width: 70) } }
    }.padding()
}
