import SwiftUI

/// Text that streams in character by character: each letter rises 4pt, un-blurs
/// and fades in over 340ms, staggered by up to 15ms. Whole strings arrive in
/// under half a second however long they are.
struct StreamText: View {
    let text: String
    let style: TextStyle
    var color: Color = .white
    var delay: Double = 0
    let reduce: Bool

    @State private var start = Date()
    @State private var finished = false

    private var stagger: Double { min(0.015, 0.48 / Double(max(1, text.count))) }
    var total: Double { delay + Double(text.count) * stagger + 0.34 }

    var body: some View {
        Group {
            if reduce || finished {
                Text(text).font(style.font).foregroundStyle(color)
            } else {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSince(start)
                    HStack(spacing: 0) {
                        ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                            let p = easeOutCubic((t - delay - Double(i) * stagger) / 0.34)
                            Text(String(ch))
                                .font(style.font)
                                .foregroundStyle(color)
                                .opacity(p)
                                .blur(radius: 3 * (1 - p))
                                .offset(y: 4 * (1 - p))
                        }
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .task(id: text) {
            try? await Task.sleep(nanoseconds: UInt64(total * 1e9))
            finished = true
        }
    }
}

/// One line of detail text with the prototype's long-text rules:
/// - paths are middle-truncated folder by folder, always keeping the filename;
/// - sentences and commands that overflow glide through once (hold → scroll →
///   hold → fade back), with soft fades at both edges, then repeat.
struct DetailLine: View {
    let text: String
    let kind: DetailKind
    let width: CGFloat
    var color: Color = .white.opacity(0.62)
    var prefix: String? = nil          // e.g. the amber "$" on the question row
    var revealDelay: Double = 0.14
    /// Room on the left for the soft edge, so the first letter is never faded.
    var inset: CGFloat = 8
    let active: Bool
    let reduce: Bool

    private var style: TextStyle { kind == .text ? .detail : .detailMono }

    private var shown: String {
        kind == .path ? Self.fitPath(text, width: width, style: style) : text
    }

    private var fullWidth: CGFloat {
        style.width(shown) + (prefix.map { TextStyle.detailMono.width($0 + " ") } ?? 0)
    }

    private var overflow: CGFloat { fullWidth - width }

    @State private var start = Date()

    var body: some View {
        let scrolls = kind != .path && overflow > 1 && !reduce
        let reveal = 0.14 + Double(shown.count) * min(0.015, 0.48 / Double(max(1, shown.count))) + 0.34
        ZStack(alignment: .leading) {
            if scrolls {
                TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
                    let (x, o) = marquee(t: ctx.date.timeIntervalSince(start) - reveal, dist: overflow + 24)
                    content.offset(x: x).opacity(o)
                }
            } else if reduce && overflow > 1 {
                Text((prefix.map { $0 + " " } ?? "") + shown)
                    .font(style.font).foregroundStyle(color)
                    .lineLimit(1).truncationMode(kind == .path ? .middle : .tail)
            } else {
                content
            }
        }
        .padding(.leading, inset)
        .frame(width: width + inset, alignment: .leading)
        .clipped()
        .mask(scrolls ? AnyView(edgeFade) : AnyView(Rectangle()))
        .onChange(of: text) { start = Date() }
    }

    private var content: some View {
        HStack(spacing: 0) {
            if let prefix {
                Text(prefix + " ").font(TextStyle.detailMono.font).foregroundStyle(Theme.amber)
            }
            StreamText(text: shown, style: style, color: color, delay: revealDelay, reduce: reduce)
        }
        .fixedSize()
    }

    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 8 / (width + inset)),
            .init(color: .black, location: 1 - 22 / (width + inset)),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    /// pause 0.7s → glide at 64pt/s → hold 1.3s → fade out → jump back → fade in.
    private func marquee(t: Double, dist: CGFloat) -> (CGFloat, Double) {
        guard t > 0 else { return (0, 1) }
        let hold0 = 0.7, travel = Double(dist) / 64, hold1 = 1.3, fade = 0.26
        let total = hold0 + travel + hold1 + fade * 2
        let p = t.truncatingRemainder(dividingBy: total)
        if p < hold0 { return (0, 1) }
        if p < hold0 + travel {
            let e = Self.easeInOut((p - hold0) / travel)
            return (-dist * CGFloat(e), 1)
        }
        if p < hold0 + travel + hold1 { return (-dist, 1) }
        if p < hold0 + travel + hold1 + fade { return (-dist, 1 - (p - hold0 - travel - hold1) / fade) }
        return (0, (p - hold0 - travel - hold1 - fade) / fade)
    }

    /// ≈ cubic-bezier(.45, 0, .4, 1)
    static func easeInOut(_ x: Double) -> Double {
        let x = clamp01(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Drop folders from the middle until it fits: src/…/_components/PricingTable.tsx
    static func fitPath(_ path: String, width: CGFloat, style: TextStyle) -> String {
        if style.width(path) <= width { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2 else { return path }
        for drop in 1...(parts.count - 2) {
            let cand = parts[0] + "/…/" + parts[(1 + drop)...].joined(separator: "/")
            if style.width(cand) <= width { return cand }
        }
        return "…/" + parts.last!
    }
}

/// Rolling digits, readable while they climb.
///
/// The number advances in whole steps at most ~9 times a second, so every value
/// stays on screen long enough to read. Each digit wheel then eases (~300ms) to
/// its new digit, always rolling forward: 9 → 0 continues into an extra 0 at the
/// bottom of the strip instead of spinning back.
final class OdoSim {
    var shown: Int?
    var shownAt = Date.distantPast
    var pos: [Double] = []
    var last: Date?

    func step(value: Double, cols: Int, date: Date, reduce: Bool) -> (positions: [Double], significant: Int) {
        let n = Int(value.rounded())
        if shown == nil || (n != shown && date.timeIntervalSince(shownAt) > 0.11) { shown = n; shownAt = date }
        let digits = Array(String(shown!).leftPadded(to: cols))
        if pos.count != cols { pos = digits.map { Double(String($0)) ?? 0 } }
        let dt = min(0.05, last.map { date.timeIntervalSince($0) } ?? 0)
        last = date
        let ease = reduce || dt == 0 ? 1 : 1 - exp(-dt * 11)
        for i in 0..<cols {
            let d = Double(String(digits[i])) ?? 0
            var dist = (d - pos[i] + 10).truncatingRemainder(dividingBy: 10)   // forward only
            if dist < 0 { dist += 10 }
            pos[i] += dist < 0.002 ? dist : dist * ease
            if pos[i] >= 10 { pos[i] -= 10 }
        }
        return (pos, String(shown!).count)
    }
}

private extension String {
    func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

struct Odometer: View {
    let target: Int
    let start: Date
    let active: Bool
    let reduce: Bool
    @State private var sim = OdoSim()
    @State private var settled = false

    private var cols: Int { String(max(0, target)).count }
    private static let lineH: CGFloat = 15.6
    private static let digitW = TextStyle.metaDigits.width("0")

    private func value(at d: Date) -> Double {
        // A gentle ease-out over 0.9s from 0 to the result.
        let p = clamp01(d.timeIntervalSince(start) / 0.9)
        return (1 - (1 - p) * (1 - p)) * Double(target)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: settled || !active)) { ctx in
            let date = settled ? Date.distantFuture : ctx.date
            let (pos, sig) = sim.step(value: settled ? Double(target) : value(at: date), cols: cols, date: ctx.date, reduce: reduce || settled)
            HStack(spacing: 0) {
                ForEach(0..<cols, id: \.self) { i in
                    let lead = i < cols - sig
                    VStack(spacing: 0) {
                        ForEach(0..<11, id: \.self) { d in
                            Text("\(d % 10)").font(TextStyle.metaDigits.font)
                                .frame(width: Self.digitW, height: Self.lineH)
                        }
                    }
                    .offset(y: -CGFloat(pos[i]) * Self.lineH)
                    .frame(width: lead ? 0 : Self.digitW, height: Self.lineH, alignment: .top)
                    .clipped()
                    .opacity(lead ? 0 : 1)
                    .animation(Theme.easeOut(0.4), value: lead)
                }
            }
            .foregroundStyle(.white.opacity(0.88))
        }
        .task(id: start) {
            settled = false
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            settled = true
        }
        .accessibilityLabel("\(target)")
    }
}

/// The three soft dots after "Thinking".
struct ThinkingDots: View {
    let active: Bool
    let reduce: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduce)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    let p = ((t - Double(i) * 0.15) / 1.2).truncatingRemainder(dividingBy: 1)
                    let o = p < 0.4 ? 0.25 + 0.75 * (p / 0.4) : 1 - 0.75 * ((p - 0.4) / 0.6)
                    Text(".").opacity(reduce ? 0.6 : o)
                }
            }
            .font(TextStyle.verb.font)
        }
    }
}
