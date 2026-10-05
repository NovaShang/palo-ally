import Foundation
import simd

/// The avatar's motion: two drops of liquid glass — 「它」 (big, the theme
/// color) and 「你」 (small, the partner color) — whose relationship shows
/// what's going on. A handful of spring-driven parameters chase targets set
/// by the current mode; events add kicks and short scripted overrides on top;
/// slow noise runs through everything, so no moment looks like another.
///
/// Drive it once per frame: set `inputs`, call `send(_:)` for events,
/// `advance(by:)`, then hand `uniforms(...)` to the `twoDrops` shader
/// (TwoDrops.metal). Plain Foundation + simd, no UI dependencies.
public final class TwoDropsState {
    public enum Mode: Int, CaseIterable, Sendable {
        case idle, quiet, background, thinking, streaming, typing, approval, speaking, offline
    }

    /// What the app knows right now. Several can hold at once; `mode` picks by
    /// priority: offline > speaking > approval > typing > streaming > thinking
    /// > background > quiet > idle (an error is an event and wins while it
    /// plays, unless offline).
    public struct Inputs: Sendable, Equatable {
        public var offline = false
        public var speaking = false
        public var approval = false
        public var typing = false
        public var streaming = false
        public var thinking = false
        public var background = false
        public var quiet = false
        /// 0…1 while the owner speaks: the waveform's level.
        public var voiceLevel: Float = 0
        /// 0…1 how hard a turn is working (e.g. tool calls per second, normalized).
        public var busyness: Float = 0.5
        public init() {}
    }

    public enum Event: Sendable {
        case send, done, deliverable, approve, reject, error, reconnect, appOpen, keystroke, chunk
        /// Colors are sRGB 0…1.
        case hostSwitch(primary: SIMD3<Float>, partner: SIMD3<Float>)
        case colorChange(primary: SIMD3<Float>, partner: SIMD3<Float>)
    }

    public static let uniformCount = 60

    public var inputs = Inputs()
    /// Static poses only: no noise, no events, springs land at once.
    public var reduceMotion = false
    public private(set) var primary: SIMD3<Float>
    public private(set) var partner: SIMD3<Float>
    public private(set) var time: Float = 0

    public var mode: Mode {
        let i = inputs
        if i.offline { return .offline }
        if i.speaking { return .speaking }
        if i.approval { return .approval }
        if i.typing { return .typing }
        if i.streaming { return .streaming }
        if i.thinking { return .thinking }
        if i.background { return .background }
        if i.quiet { return .quiet }
        return .idle
    }

    public init(primary: SIMD3<Float>, partner: SIMD3<Float>, seed: UInt64 = 0x9A10) {
        self.primary = primary
        self.partner = partner
        noise = SlowNoise(seed: seed)
        springs = P.allCases.map { Spring(Self.idle[$0.rawValue], P.feel[$0.rawValue]) }
        az = 0.6
    }

    // MARK: Parameters

    /// Everything that moves. Each is a spring with its own feel.
    enum P: Int, CaseIterable {
        case sep, el, azVel, orbitMix, anchor, ratio, size, k, wobA, wobB, wobSpeed, reach,
             sqA, sqB, swellA, swellB, sat, bright, frost, flow, flowSpeed, glowB, comY, zoom, life, shiver, clarity

        /// (stiffness, damping ratio): low damping = bouncy, jelly-like.
        static let feel: [(Float, Float)] = [
            (60, 0.42),   // sep — overshoots, so splitting and merging feel liquid
            (30, 0.70),   // el
            (8, 1.0),     // azVel
            (10, 1.0),    // orbitMix
            (6, 1.0),     // anchor
            (20, 0.8),    // ratio
            (50, 0.55),   // size
            (25, 0.9),    // k (bridge softness)
            (20, 0.8),    // wobA
            (60, 0.55),   // wobB (follows the voice)
            (6, 1.0),     // wobSpeed
            (70, 0.28),   // reach (the knock)
            (90, 0.17),   // sqA (jelly)
            (120, 0.20),  // sqB
            (80, 0.30),   // swellA
            (90, 0.45),   // swellB
            (6, 1.0),     // sat
            (8, 1.0),     // bright
            (5, 1.0),     // frost
            (4, 1.0),     // flow
            (4, 1.0),     // flowSpeed
            (30, 0.8),    // glowB
            (40, 0.38),   // comY
            (4, 1.0),     // zoom
            (3, 1.0),     // life (noise and wobble on/off)
            (6, 1.0),     // shiver
            (3, 1.0),     // clarity (thinner glass: quiet hours)
        ]
    }

    /// Idle targets; every mode starts from these.
    static let idle: [Float] = {
        var t = [Float](repeating: 0, count: P.allCases.count)
        t[P.sep.rawValue] = 0.62; t[P.el.rawValue] = 0.45; t[P.azVel.rawValue] = 0.14
        t[P.ratio.rawValue] = 0.55; t[P.size.rawValue] = 1; t[P.k.rawValue] = 0.20
        t[P.wobA.rawValue] = 0.35; t[P.wobB.rawValue] = 0.35; t[P.wobSpeed.rawValue] = 0.55
        t[P.sat.rawValue] = 1; t[P.bright.rawValue] = 1; t[P.flowSpeed.rawValue] = 0.4
        t[P.comY.rawValue] = 0.02; t[P.zoom.rawValue] = 0.82; t[P.life.rawValue] = 1
        return t
    }()

    /// Where B sits when a mode holds it in place (azimuth; π/2 = toward the viewer).
    private var anchorAz: Float = .pi / 2

    private func targets(for m: Mode) -> [Float] {
        var t = Self.idle
        func set(_ p: P, _ v: Float) { t[p.rawValue] = v }
        let b = min(max(inputs.busyness, 0), 1)
        let L = min(max(inputs.voiceLevel, 0), 1)
        switch m {
        case .idle:
            break
        case .quiet:
            // asleep: one soft drop of thin, pale glass — calm and airy, never heavy
            set(.sep, 0.10); set(.ratio, 0.52); set(.k, 0.22); set(.wobA, 0.08); set(.wobB, 0.08)
            set(.wobSpeed, 0.14); set(.bright, 1.0); set(.sat, 0.68); set(.clarity, 1); set(.azVel, 0.03)
            set(.life, 0.32); set(.zoom, 0.86); set(.comY, -0.02); set(.flowSpeed, 0.2)
        case .background:
            set(.flow, 0.75); set(.flowSpeed, 0.8)
        case .thinking:
            set(.sep, 1.12 + 0.16 * b); set(.orbitMix, 1); set(.azVel, 1.2 + 1.8 * b); set(.k, 0.30)
            set(.wobA, 0.55 + 0.3 * b); set(.wobB, 0.5); set(.wobSpeed, 1.1 + 0.6 * b)
            set(.flow, 0.45); set(.flowSpeed, 1.2 + b); set(.zoom, 1.16); set(.el, 0)
        case .streaming:
            set(.sep, 0.92); set(.orbitMix, 1); set(.azVel, 0.6); set(.k, 0.34)
            set(.wobA, 0.45); set(.wobB, 0.45); set(.flow, 0.3); set(.flowSpeed, 0.9); set(.zoom, 1.05)
        case .typing:
            set(.anchor, 1); anchorAz = .pi / 2
            set(.el, -0.6); set(.sep, 0.68); set(.azVel, 0); set(.comY, -0.08); set(.k, 0.24)
            set(.wobA, 0.3); set(.zoom, 0.88)
        case .speaking:
            set(.anchor, 1); anchorAz = .pi / 2 - 0.45
            set(.el, -0.15); set(.azVel, 0); set(.sep, 0.70 + 0.34 * L); set(.k, 0.24 + 0.18 * L)
            set(.swellB, 0.26 * L); set(.wobB, 0.4 + 1.2 * L); set(.wobSpeed, 0.9 + 1.4 * L)
            set(.glowB, 0.5 * L); set(.sqA, -0.05); set(.zoom, 0.92)
        case .approval:
            set(.anchor, 1); anchorAz = 0.45
            set(.el, -0.1); set(.azVel, 0); set(.sep, 1.02); set(.reach, 0.22); set(.glowB, 0.3)
            set(.k, 0.26); set(.wobA, 0.3); set(.zoom, 1.0)
        case .offline:
            set(.anchor, 1); anchorAz = 0.2
            set(.el, 0.02); set(.azVel, 0); set(.sep, 1.12); set(.wobA, 0); set(.wobB, 0); set(.life, 0)
            set(.frost, 1); set(.sat, 0.06); set(.bright, 0.8); set(.k, 0.18); set(.zoom, 1.02); set(.comY, 0)
        }
        if m != .typing && m != .speaking && m != .approval && m != .offline { set(.anchor, 0) }
        return t
    }

    // MARK: State

    private struct Spring {
        var x: Float, v: Float = 0, target: Float
        let k: Float, c: Float
        init(_ x: Float, _ feel: (Float, Float)) {
            self.x = x; target = x; k = feel.0; c = 2 * feel.1 * feel.0.squareRoot()
        }
        mutating func step(_ dt: Float) { v += (k * (target - x) - c * v) * dt; x += v * dt }
    }

    private var springs: [Spring]
    private subscript(_ p: P) -> Spring {
        get { springs[p.rawValue] }
        set { springs[p.rawValue] = newValue }
    }
    private func x(_ p: P) -> Float { springs[p.rawValue].x }
    private func kick(_ p: P, _ dv: Float) { if !reduceMotion { springs[p.rawValue].v += dv } }

    private var az: Float
    private var wobPhase: Float = 0, flowPhase: Float = 0, shiverPhase: Float = 0
    private var noiseT: Float = 0
    private let noise: SlowNoise
    private var knockClock: Float = 0
    private var lastKeystroke: Float = -1, lastChunk: Float = -1

    // the latest geometry, kept for events that aim at it
    private var cA = SIMD3<Float>(0, 0, 0), cB = SIMD3<Float>(0.5, 0, 0), dir = SIMD3<Float>(1, 0, 0)
    private var rA: Float = 0.52, rB: Float = 0.3

    // transient things events create
    private var ripple = (c: SIMD3<Float>(0, 0, 0), amp: Float(0), age: Float(0))
    private var droplet = (p: SIMD3<Float>(0, 0, 0), v: SIMD3<Float>(0, 0, 0), r: Float(0))
    private var shakeX: Float = 0
    private var fill = (on: false, c: SIMD3<Float>(0, 0, 0), r: Float(0),
                        fromA: SIMD3<Float>(0, 0, 0), fromB: SIMD3<Float>(0, 0, 0),
                        toA: SIMD3<Float>(0, 0, 0), toB: SIMD3<Float>(0, 0, 0))

    private struct Running { var event: Event; var age: Float = 0; var fired = Set<Int>() }
    private var running: [Running] = []

    // MARK: Events

    public func send(_ event: Event) {
        if reduceMotion {
            switch event {
            case .hostSwitch(let p, let q), .colorChange(let p, let q): primary = p; partner = q
            default: break
            }
            return
        }
        if mode == .offline {
            switch event {
            case .reconnect, .hostSwitch, .colorChange: break
            default: return
            }
        }
        switch event {
        case .keystroke:
            guard time - lastKeystroke >= 0.07 else { return }
            lastKeystroke = time
            // capped: a fast typist reads as attention, not a bounce
            let room = max(0, 1 - abs(x(.sqB)) / 0.3)
            kick(.sqB, -1.1 * room)
            kick(.el, 1.4 * room)
            return
        case .chunk:
            guard time - lastChunk >= 0.12 else { return }
            lastChunk = time
            kick(.swellA, 0.45)
            kick(.wobA, 0.5)
            return
        default:
            running.removeAll { same($0.event, event) }
            running.append(Running(event: event))
        }
    }

    private func same(_ a: Event, _ b: Event) -> Bool {
        switch (a, b) {
        case (.send, .send), (.done, .done), (.deliverable, .deliverable), (.approve, .approve),
             (.reject, .reject), (.error, .error), (.reconnect, .reconnect), (.appOpen, .appOpen),
             (.hostSwitch, .hostSwitch), (.colorChange, .colorChange): return true
        default: return false
        }
    }

    private func splash(at c: SIMD3<Float>, _ amp: Float) { ripple = (c, amp, 0) }

    /// Plays one running event: overrides targets, fires kicks at set ages.
    /// Returns false when it's over.
    private func play(_ r: inout Running, _ t: inout [Float]) -> Bool {
        let a = r.age
        func set(_ p: P, _ v: Float) { t[p.rawValue] = v }
        func once(_ id: Int, at age: Float, _ body: () -> Void) {
            if a >= age && !r.fired.contains(id) { r.fired.insert(id); body() }
        }
        switch r.event {
        case .send:
            // 你 pushes a little of itself into 它, which swells
            if a < 0.22 { set(.sep, 0.22); set(.k, 0.36) }
            once(0, at: 0) { kick(.sqB, -1.6) }
            once(1, at: 0.16) { kick(.swellA, 1.3); splash(at: cA + dir * rA * 0.9, 0.03) }
            return a < 0.9
        case .done:
            // they collide and become one, squash, ripple — then 你 comes back out
            if a < 0.30 { set(.sep, 0.0); set(.k, 0.34) } else if a < 0.95 { set(.sep, 0.04) }
            once(0, at: 0.26) {
                kick(.sqA, 3.4); kick(.sqB, 2.0); kick(.comY, -0.9)
                splash(at: cA + SIMD3(0, rA, 0), 0.045)
            }
            once(1, at: 0.95) { kick(.sep, 2.6) }
            return a < 1.7
        case .deliverable:
            // 它 spits a droplet off toward 成果 (the right), then closes
            once(0, at: 0) {
                kick(.sqA, -1.6)
                droplet = (cA + SIMD3(rA * 0.55, 0.06, 0.04), SIMD3(1.25, 0.95, 0.25), 0.001)
            }
            once(1, at: 0.12) { splash(at: cA + SIMD3(rA * 0.9, 0.08, 0), 0.04); kick(.swellA, -0.6) }
            droplet.r = a < 0.2 ? 0.13 * a / 0.2 : max(0, 0.13 * (1 - (a - 0.2) / 1.1))
            return a < 1.4
        case .approve:
            // a happy merge with a hop
            if a < 0.55 { set(.sep, 0.08) }
            once(0, at: 0.17) { kick(.comY, 1.8); kick(.sqA, 2.2); kick(.glowB, 3) }
            once(1, at: 0.55) { kick(.sep, 2.2) }
            return a < 1.2
        case .reject:
            // 它 pulls its reach back and shivers
            if a < 0.4 { set(.reach, -0.22); t[P.sep.rawValue] += 0.12 }
            once(0, at: 0) { springs[P.shiver.rawValue].x = 1 }
            once(1, at: 0.05) { kick(.sqA, -1.2) }
            return a < 1.1
        case .error:
            // they snap apart, shrink, dim and shake; then drift back
            once(0, at: 0) { kick(.sep, 5.0) }
            once(1, at: 0.05) { kick(.sqA, -1.5); kick(.sqB, -1.5) }
            if a < 0.9 { set(.sep, 1.55) }
            if a < 1.3 { set(.size, 0.82); set(.bright, 0.6); set(.sat, 0.75) }
            shakeX = 0.07 * sin(a * 42) * exp(-a * 3.2)
            if a >= 2.0 { shakeX = 0 }
            return a < 2.0
        case .reconnect:
            // the color fills back in from the middle, then they find each other
            once(0, at: 0) {
                springs[P.sat.rawValue].x = 1; springs[P.sat.rawValue].v = 0
                let g = { (c: SIMD3<Float>) -> SIMD3<Float> in
                    let l = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)); return SIMD3(repeating: l * 0.9 + 0.05)
                }
                fill = (true, cA, 0, g(primary), g(partner), primary, partner)
            }
            fill.r = 2.4 * easeOut(min(a / 1.0, 1))
            if a >= 1.0 { fill.on = false }
            if a >= 1.0 && a < 1.35 { set(.sep, 0.18) }
            once(1, at: 1.35) { kick(.sep, 1.5) }
            return a < 1.8
        case .appOpen:
            // waking up: one drop, then a half-turn hello, then home
            once(0, at: 0) { springs[P.sep.rawValue].x = 0.1; springs[P.bright.rawValue].x = 0.7 }
            if a >= 0.12 && a < 1.35 { set(.sep, 0.98); set(.orbitMix, 1); set(.azVel, .pi / 1.2); set(.anchor, 0) }
            else if a >= 1.35 && a < 1.75 { set(.sep, 0.25) }
            return a < 2.2
        case .hostSwitch(let p, let q):
            // the pair draws together into one drop (shrinking only a little, so
            // it stays readable at 30 pt), the new colors spread through it from
            // the middle, then it splits again as the other assistant
            if a < 1.2 { set(.sep, 0.03); set(.size, 0.86) }
            once(0, at: 0.3) { fill = (true, cA, 0, primary, partner, p, q) }
            if a >= 0.3 && a < 1.2 { fill.r = 1.4 * easeInOut(min((a - 0.3) / 0.85, 1)) }
            once(1, at: 1.2) { primary = p; partner = q; fill.on = false; kick(.sep, 2.2); kick(.sqA, 1.2) }
            return a < 2.2
        case .colorChange(let p, let q):
            // the new color spreads out from the bridge
            once(0, at: 0) {
                fill = (true, cA + dir * rA, 0, primary, partner, p, q)
                kick(.swellA, 0.6)
            }
            fill.r = 1.8 * easeInOut(min(a / 1.1, 1))
            if a >= 1.25 { primary = p; partner = q; fill.on = false }
            return a < 1.25
        case .keystroke, .chunk:
            return false
        }
    }

    // MARK: Time

    public func advance(by dt: Float) {
        let dt = min(max(dt, 0), 0.1)
        time += dt
        let m = mode
        var t = targets(for: m)

        // noise: never the same twice (scaled down when quiet, frozen offline)
        let life = x(.life)
        if !reduceMotion {
            noiseT += dt * life
            let n = { (ch: Int) -> Float in self.noise.value(ch, self.noiseT) }
            let free: Float = t[P.anchor.rawValue] > 0.5 ? 0.25 : 1
            t[P.sep.rawValue] += 0.06 * n(0) * life
            t[P.el.rawValue] += 0.32 * n(1) * life * free
            t[P.ratio.rawValue] += 0.035 * n(2) * life
            t[P.k.rawValue] += 0.05 * n(3) * life
            t[P.wobA.rawValue] += 0.12 * n(4) * life
            t[P.comY.rawValue] += 0.025 * n(5) * life
            t[P.azVel.rawValue] += 0.15 * n(6) * life * free
            t[P.sqA.rawValue] += 0.035 * n(7) * life
            t[P.sqB.rawValue] += 0.05 * n(8) * life
            t[P.reach.rawValue] += 0.03 * n(9) * life
        }
        if m == .quiet { t[P.swellA.rawValue] += 0.025 * sin(time * 2 * .pi * 0.12) }

        // approval: 它 knocks twice every few seconds
        if m == .approval && !reduceMotion {
            let period: Float = 3.0
            let prev = knockClock
            knockClock = (knockClock + dt).truncatingRemainder(dividingBy: period)
            let wrapped = knockClock < prev
            for hit: Float in [0.35, 0.59] where wrapped ? (prev < hit || knockClock >= hit) : (prev < hit && knockClock >= hit) {
                kick(.reach, 2.4); kick(.glowB, 1.2)
            }
        } else { knockClock = 0 }

        // events on top
        if !reduceMotion {
            for i in running.indices.reversed() {
                running[i].age += dt
                if !play(&running[i], &t) { running.remove(at: i) }
            }
        } else { running.removeAll() }

        for i in springs.indices { springs[i].target = t[i] }
        springs[P.shiver.rawValue].target = 0
        if reduceMotion {
            for i in springs.indices { springs[i].x = springs[i].target; springs[i].v = 0 }
        } else {
            let n = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
            let h = dt / Float(n)
            for _ in 0..<n { for i in springs.indices { springs[i].step(h) } }
        }

        // where 你 sits around 它
        let anchor = min(max(x(.anchor), 0), 1)
        // drifting freely, 你 lingers at 它's sides (where the bridge shows)
        // and passes quickly in front of / behind it
        let drift = (1 - min(max(x(.orbitMix), 0), 1)) * (1 - anchor)
        az += x(.azVel) * dt * (1 + drift * (1.6 * abs(sin(az)) - 0.45))
        if anchor > 0 {
            var delta = (anchorAz - az).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            az += delta * (1 - exp(-3.5 * dt)) * anchor
        }
        if reduceMotion { az = anchor > 0.5 ? anchorAz : 0.6 }
        az = az.truncatingRemainder(dividingBy: 2 * .pi)

        if !reduceMotion {
            wobPhase += dt * x(.wobSpeed) * life
            flowPhase += dt * x(.flowSpeed)
            shiverPhase += dt
            ripple.age += dt
            ripple.amp *= exp(-2.4 * dt)
            if droplet.r > 0 {
                droplet.p += droplet.v * dt
                droplet.v.y -= 3.2 * dt
            }
        } else {
            ripple.amp = 0; droplet.r = 0
        }
        updateGeometry()
    }

    private func updateGeometry() {
        let size = max(x(.size), 0.05)
        rA = 0.52 * size * max(1 + x(.swellA), 0.6)
        rB = 0.52 * size * max(x(.ratio), 0.2) * max(1 + x(.swellB), 0.6)
        let om = min(max(x(.orbitMix), 0), 1)
        let drift = (1 - om) * (1 - min(max(x(.anchor), 0), 1))
        // drifting behind 它, 你 rises to peek over its shoulder instead of vanishing
        let el = x(.el) + 0.75 * max(0, -sin(az)) * drift
        let sph = SIMD3<Float>(cos(el) * cos(az), sin(el), cos(el) * sin(az))
        let incl: Float = 0.42
        let orb = SIMD3<Float>(cos(az), -sin(az) * sin(incl), sin(az) * cos(incl))
        let d = sph * (1 - om) + orb * om
        dir = simd_length(d) > 1e-4 ? simd_normalize(d) : SIMD3(1, 0, 0)
        dir = offCenter(dir)
        let mA = rA * rA * rA, mB = rB * rB * rB
        let sep = max(x(.sep), 0) * size
        let com = SIMD3<Float>(shakeX, x(.comY), 0)
        cA = com - dir * sep * mB / (mA + mB)
        let sh = max(x(.shiver), 0)
        cA += SIMD3(0.028 * sin(shiverPhase * 57), 0.012 * sin(shiverPhase * 43), 0) * sh
        cB = com + dir * sep * mA / (mA + mB)
    }

    /// Seen from the front, one drop centered over the other reads as an eye
    /// (a round lens with a disc in it). When 你 is in front of or behind 它,
    /// keep it pushed out toward an edge in screen space: it passes around the
    /// side or peeks over the shoulder, never through the middle.
    private func offCenter(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let depth = abs(d.z)
        let need = 0.80 * smoothstep(0.15, 0.6, depth)
        let flat = SIMD2<Float>(d.x, d.y)
        let len = simd_length(flat)
        guard len < need else { return d }
        let side = len > 1e-3 ? flat / len : simd_normalize(SIMD2<Float>(0.9, 0.45))
        let f = side * need
        let z = (1 - need * need).squareRoot() * (d.z >= 0 ? 1 : -1)
        return SIMD3(f.x, f.y, z)
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Output

    /// The shader's uniform array (60 floats). `time` in seconds, `dark` 0/1,
    /// `scale` = pixels per point.
    public func uniforms(dark: Bool, scale: Float) -> [Float] {
        var u = [Float](repeating: 0, count: Self.uniformCount)
        func put(_ i: Int, _ v: SIMD3<Float>) { u[i] = v.x; u[i + 1] = v.y; u[i + 2] = v.z }
        u[0] = time; u[1] = dark ? 1 : 0; u[2] = scale; u[3] = x(.zoom)
        put(4, primary); u[7] = min(max(x(.sat), 0), 1.2)
        put(8, partner); u[11] = max(x(.bright), 0)
        put(12, cA); u[15] = rA
        put(16, cB); u[19] = rB
        put(20, dir); u[23] = x(.reach)
        u[24] = x(.sqA); u[25] = x(.sqB); u[26] = max(x(.k), 0.02); u[27] = max(x(.wobA), 0) * x(.life).clamped
        u[28] = wobPhase; u[29] = max(x(.flow), 0); u[30] = flowPhase; u[31] = min(max(x(.frost), 0), 1)
        put(32, ripple.c); u[35] = ripple.amp
        u[36] = ripple.age * 14; u[37] = max(x(.glowB), 0); u[38] = max(x(.shiver), 0); u[39] = -0.98
        put(40, droplet.p); u[43] = droplet.r
        if fill.on {
            put(4, fill.fromA); put(8, fill.fromB)
            put(44, fill.toA); u[47] = max(fill.r, 0.001)
            put(48, fill.toB)
        } else {
            put(44, primary); u[47] = 0; put(48, partner)
        }
        u[51] = shiverPhase
        put(52, fill.c); u[55] = max(x(.wobB), 0) * x(.life).clamped
        u[56] = x(.clarity).clamped
        return u
    }

    private func easeOut(_ x: Float) -> Float { 1 - pow(1 - x, 3) }
    private func easeInOut(_ x: Float) -> Float { x * x * (3 - 2 * x) }
}

private extension Float {
    var clamped: Float { Swift.min(Swift.max(self, 0), 1) }
}

/// A few slow sines per channel with seeded, incommensurate frequencies.
struct SlowNoise {
    let seed: UInt64
    func value(_ channel: Int, _ t: Float) -> Float {
        var acc: Float = 0, norm: Float = 0
        for o in 0..<3 {
            let h = hash(UInt64(channel) &* 31 &+ UInt64(o))
            let f = 0.05 + 0.22 * unit(h) * (o == 0 ? 0.6 : (o == 1 ? 1.0 : 1.7))
            let ph = 6.2832 * unit(h >> 20)
            let a: Float = o == 0 ? 1 : (o == 1 ? 0.6 : 0.35)
            acc += a * sin(t * f * 6.2832 + ph)
            norm += a
        }
        return acc / norm
    }
    private func hash(_ x: UInt64) -> UInt64 {
        var z = x &+ seed &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    private func unit(_ h: UInt64) -> Float { Float(h & 0xFFFFF) / Float(0xFFFFF) }
}
