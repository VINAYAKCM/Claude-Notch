import SwiftUI

/// The 8-ray spark. Each kind of work gets its own movement, ported from the prototype:
/// thinking breathes, reading/searching sweeps like a scanner, editing strikes ray
/// by ray like keys, running sends a dot orbiting, committing gathers then bursts,
/// waiting pulses amber, done draws a check.
final class SparkSim {
    static let variation: [Double] = [1, 0.8, 0.94, 0.76, 1, 0.84, 0.9, 0.78]   // organic, uneven rays
    static let inner = 2.1

    var len = [Double](repeating: 8, count: 8)
    var op = [Double](repeating: 1, count: 8)
    var rot = 0.0, rotV = 0.0, orb = 0.0, t = 0.0
    var color = Theme.accentRGB
    var check = 0.0
    var doneSince: Double?
    var last: Date?

    func target(_ mode: GlyphMode, _ t: Double, _ i: Int) -> (Double, Double, Double) {
        let a = Double(i) / 8
        switch mode {
        case .think:
            return (5.8 + 3.4 * (0.5 + 0.5 * sin(t * 2.2 - Double(i) * 0.785)), 1, 16)
        case .read, .search:
            let sweep = (t * (mode == .read ? 1.05 : 1.9)).truncatingRemainder(dividingBy: 1)
            var d = abs(a - sweep); d = min(d, 1 - d)
            let k = exp(-pow(d * 7, 2))
            return (4.6 + 5 * k, 0.35 + 0.65 * k, mode == .search ? 50 : 0)
        case .edit:
            let since = ((t * 7).truncatingRemainder(dividingBy: 8) - Double(i) + 8).truncatingRemainder(dividingBy: 8)
            let k = exp(-since * 0.9)
            return (4.4 + 5.2 * k, 0.4 + 0.6 * k, 0)
        case .run:
            return (4.3 + 0.5 * sin(t * 6 + Double(i)), 0.85, -24)
        case .commit:
            let p = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            let L: Double
            if p < 0.45 { let e = p / 0.45; L = 8.5 - 6 * e * e }
            else if p < 0.58 { let e = (p - 0.45) / 0.13; L = 2.5 + 8.5 * (1 - pow(1 - e, 3)) }
            else { let e = (p - 0.58) / 0.42; L = 11 - 2.5 * e }
            return (L, 1, 0)
        case .wait:
            return (7 + 1.1 * sin(t * 3.2), 0.78 + 0.22 * sin(t * 3.2), 0)
        case .done:
            return (Self.inner, 0, 0)
        }
    }

    func step(to date: Date, mode: GlyphMode, reduce: Bool) {
        let dt = min(0.05, last.map { date.timeIntervalSince($0) } ?? 0.016)
        last = date
        t += dt
        let ease = 1 - exp(-dt * 14)
        var rv = 0.0
        for i in 0..<8 {
            let (L, o, r) = (reduce && mode != .done) ? (8.0, 1.0, 0.0) : target(mode, t, i)
            rv = r
            len[i] += (L * (mode == .commit ? 1 : Self.variation[i]) - len[i]) * ease
            op[i] += (o - op[i]) * ease
        }
        rotV += (rv - rotV) * ease
        rot = (rot + rotV * dt).truncatingRemainder(dividingBy: 360)
        orb += ((mode == .run && !reduce ? 1 : 0) - orb) * ease

        let goal: SIMD3<Double> = mode == .wait ? Theme.amberRGB : (mode == .done ? Theme.greenRGB : Theme.accentRGB)
        color += (goal - color) * (1 - exp(-dt / 0.15))

        if mode == .done {
            if doneSince == nil { doneSince = t }
            check = easeOutCubic((t - doneSince! - 0.15) / 0.5)
        } else {
            doneSince = nil
            check = 0
        }
    }
}

struct SparkGlyph: View {
    let mode: GlyphMode
    let active: Bool
    let reduce: Bool
    @State private var sim = SparkSim()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
            Canvas { gc, size in
                sim.step(to: ctx.date, mode: mode, reduce: reduce)
                draw(&gc, size, date: ctx.date)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, date: Date) {
        let s = sim
        gc.translateBy(x: size.width / 2, y: size.height / 2)
        gc.scaleBy(x: size.width / 24, y: size.height / 24)   // the prototype's viewBox is -12…12
        var color = Color(rgb: s.color)
        // Reduced motion: no ray movement, just a soft pulse.
        if reduce && mode != .done {
            let pulse = 0.775 + 0.225 * cos(date.timeIntervalSinceReferenceDate * .pi * 2 / 1.8)
            color = color.opacity(pulse)
        }

        var rays = gc
        rays.rotate(by: .degrees(s.rot))
        for i in 0..<8 {
            let ang = Double(i) / 8 * .pi * 2 - .pi / 2
            let c = cos(ang), sn = sin(ang), L = max(SparkSim.inner + 0.01, s.len[i])
            var p = Path()
            p.move(to: CGPoint(x: c * SparkSim.inner, y: sn * SparkSim.inner))
            p.addLine(to: CGPoint(x: c * L, y: sn * L))
            rays.stroke(p, with: .color(color.opacity(s.op[i])), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
        }

        if s.orb > 0.01 {
            let oa = s.t * .pi * 2 * 0.85
            let pt = CGPoint(x: cos(oa) * 9.4, y: sin(oa) * 9.4)
            gc.fill(Path(ellipseIn: CGRect(x: pt.x - 1.7, y: pt.y - 1.7, width: 3.4, height: 3.4)), with: .color(color.opacity(s.orb)))
        }

        if s.check > 0 {
            var p = Path()
            p.move(to: CGPoint(x: -6, y: 0.5))
            p.addLine(to: CGPoint(x: -2, y: 4.5))
            p.addLine(to: CGPoint(x: 6, y: -4))
            gc.stroke(p.trimmedPath(from: 0, to: s.check), with: .color(color),
                      style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
    }
}
