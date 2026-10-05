import simd
import SwiftUI

/// The two drops as the user sees them: system Liquid Glass shapes — which
/// bend what's really behind them and melt into each other where they meet —
/// with our shader laid over them for what system glass doesn't have: color
/// that deepens with thickness, the inner light, the glints.
///
/// Both follow the same frame of TwoDropsState (`uniforms`): the glass takes
/// the drops' projected outlines, the shader (in overlay mode) the full 3D
/// shape. `canvas` is the drawing's side in points.
struct GlassDropsView: View {
    var uniforms: [Float]
    var canvas: CGFloat
    /// The title orb answers a press with the glass's own give.
    var interactive = false

    /// How strong the overlay is over the glass.
    static let overlayOpacity: Float = 0.72

    @Namespace private var glassSpace

    var body: some View {
        let layout = DropLayout(uniforms, canvas: canvas)
        ZStack {
            GlassEffectContainer(spacing: layout.spacing) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.blobs) { blob in
                        Color.clear
                            .frame(width: blob.box.width, height: blob.box.height)
                            .glassEffect(glass(blob.tint, layout), in: blob.shape)
                            .glassEffectID(blob.id, in: glassSpace)
                            .offset(x: blob.box.minX, y: blob.box.minY)
                    }
                }
                .frame(width: canvas, height: canvas, alignment: .topLeading)
            }
            Rectangle()
                .fill(.black)
                .colorEffect(ShaderLibrary.twoDrops(.float2(CGSize(width: canvas, height: canvas)),
                                                    .floatArray(Self.overlay(uniforms))))
                .allowsHitTesting(false)
        }
        .frame(width: canvas, height: canvas)
    }

    /// The shader's uniforms switched to overlay mode.
    static func overlay(_ u: [Float]) -> [Float] {
        var u = u
        if u.count > 58 { u[57] = 1; u[58] = overlayOpacity }
        return u
    }

    /// Tinted glass; offline it turns gray and frosted, in quiet hours pale.
    private func glass(_ tint: Color, _ layout: DropLayout) -> Glass {
        let gray = Color(white: 0.62)
        let color = layout.frost > 0.01 ? tint.mix(with: gray, by: Double(layout.frost)) : tint
        let opacity = (0.52 + 0.22 * Double(layout.frost)) * (1 - 0.45 * Double(layout.clarity))
        return Glass.regular.tint(color.opacity(opacity)).interactive(interactive)
    }
}

/// Where TwoDrops.metal puts the drops, projected onto the canvas (points):
/// the same camera — eye at z 4.2, focal 3.05, `zoom` — and the same shapes
/// (A squashed and stretched toward B as it reaches, with an arm of liquid;
/// B squashed; the droplet A spits out).
struct DropLayout {
    struct Blob: Identifiable {
        let id: String
        let shape: BlobShape
        let box: CGRect
        let tint: Color
    }

    var blobs: [Blob] = []
    /// How near the glass shapes start melting together (the bridge).
    var spacing: CGFloat = 0
    var frost: Float = 0
    var clarity: Float = 0

    init(_ u: [Float], canvas: CGFloat) {
        guard u.count >= 60 else { return }
        let zoom = max(u[3], 0.05)
        let half = canvas / 2
        func v(_ i: Int) -> SIMD3<Float> { SIMD3(u[i], u[i + 1], u[i + 2]) }
        func scale(_ c: SIMD3<Float>) -> CGFloat { CGFloat(3.05 / (max(4.2 - c.z, 0.5) * zoom)) * half }
        func point(_ c: SIMD3<Float>) -> CGPoint {
            let k = scale(c)
            return CGPoint(x: half + CGFloat(c.x) * k, y: half - CGFloat(c.y) * k)
        }

        frost = min(max(u[31], 0), 1)
        clarity = min(max(u[56], 0), 1)

        // Colors, part way through a color spreading in (fillR > 0).
        let fillT = u[47] > 0.001 ? min(u[47] / 1.2, 1) : 0
        let sat = min(max(u[7], 0), 1.2)
        func color(_ from: Int, _ to: Int) -> Color {
            let c = simd_mix(v(from), v(to), SIMD3(repeating: fillT))
            let luma = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
            let s = simd_mix(SIMD3(repeating: luma), c, SIMD3(repeating: sat))
            return Color(red: Double(s.x), green: Double(s.y), blue: Double(s.z))
        }
        let tintA = color(4, 44), tintB = color(8, 48)

        let cA = v(12), rA = u[15], cB = v(16), rB = u[19]
        let axis = v(20), reach = u[23]
        let sqA = u[24], sqB = u[25], k = u[26]
        let wobA = u[27], wobPhase = u[28], shiver = u[38], shiverPhase = u[51], wobB = u[55]
        let px = scale(cA)  // points per world unit near the drops

        spacing = CGFloat(max(k * 2.0, 0.3)) * px

        // A: leaning toward B along the axis (stretch sr), squashed vertically.
        let sr = max(1 + (reach > 0 ? 0.35 * reach : reach), 0.55)
        let axis2 = SIMD2(axis.x, axis.y)
        let along = simd_length(axis2)
        let srEff = 1 + (sr - 1) * min(along, 1)
        let angle = along > 1e-3 ? atan2(-Double(axis.y), Double(axis.x)) : 0
        let bodyA = cA + simd_normalize(axis == .zero ? SIMD3(1, 0, 0) : axis) * (rA * (sr - 1) * 0.55)
        let breathe = 1 + CGFloat(0.03 * wobA * sin(wobPhase * 1.3))
        let tremble = CGFloat(rA * 0.012 * shiver * sin(shiverPhase * 37)) * px
        add("a", center: point(bodyA), radius: CGFloat(rA) * scale(bodyA) * breathe,
            stretch: CGFloat(srEff), angle: angle, squash: CGFloat(exp(-sqA)), tint: tintA, shift: tremble)

        // A's arm of liquid while it reaches.
        if reach > 0.01 {
            let armC = cA + simd_normalize(axis) * rA * (0.25 + 1.25 * reach)
            let armR = rA * (0.46 + 0.10 * min(reach, 1))
            add("arm", center: point(armC), radius: CGFloat(armR) * scale(armC), tint: tintA)
        }

        // B, the owner.
        let breatheB = 1 + CGFloat(0.035 * wobB * sin(wobPhase * 1.6 + 1.7))
        add("b", center: point(cB), radius: CGFloat(rB) * scale(cB) * breatheB,
            squash: CGFloat(exp(-sqB)), tint: tintB)

        // The droplet A spits toward 成果, or the blob the owner sends in.
        if u[43] > 0.003 {
            let cC = v(40)
            add("c", center: point(cC), radius: CGFloat(u[43]) * scale(cC), tint: tintA)
        }
    }

    private mutating func add(_ id: String, center: CGPoint, radius: CGFloat,
                              stretch: CGFloat = 1, angle: Double = 0, squash: CGFloat = 1,
                              tint: Color, shift: CGFloat = 0) {
        let shape = BlobShape(stretch: stretch, angle: angle, squash: squash)
        // Room for the stretched, rotated ellipse.
        let reachOut = radius * max(stretch, 1) * max(squash, 1 / squash.squareRoot(), 1) * 1.05
        let box = CGRect(x: center.x - reachOut + shift, y: center.y - reachOut,
                         width: reachOut * 2, height: reachOut * 2)
        blobs.append(Blob(id: id, shape: shape, box: box, tint: tint))
    }
}

/// A circle filling the middle of its square, stretched by `stretch` along
/// `angle` (radians, screen coordinates) — and thinner across, so it keeps
/// its volume — then squashed vertically (`squash` > 1 taller), like the
/// shader's drops.
struct BlobShape: Shape {
    var stretch: CGFloat = 1
    var angle: Double = 0
    var squash: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        // The box is ~5% bigger than the shape at its largest; the radius is
        // what's left after that and the stretches.
        let side = min(rect.width, rect.height)
        let r = side / 2 / (max(stretch, 1) * max(squash, 1 / squash.squareRoot(), 1) * 1.05)
        let unit = Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        let a = CGFloat(angle)
        let t = CGAffineTransform(rotationAngle: -a)
            .concatenating(CGAffineTransform(scaleX: stretch, y: 1 / stretch.squareRoot()))
            .concatenating(CGAffineTransform(rotationAngle: a))
            .concatenating(CGAffineTransform(scaleX: 1 / squash.squareRoot(), y: squash))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return unit.applying(t)
    }
}
