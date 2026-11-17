import SwiftUI

/// The whole notch: black shape, wings either side of the camera, and three
/// layers (peek row, open panel, question row) that cross-blur in and out.
struct NotchView: View {
    @ObservedObject var c: NotchController
    @ObservedObject var model: NotchModel

    var body: some View {
        let H = c.metrics.height
        let s = model.current
        let visible = c.ui != .hidden

        ZStack(alignment: .top) {
            NotchShape(w: c.w, h: c.h, r: c.r)
                .fill(Color.black)
                .frame(width: NotchController.canvas.width, height: NotchController.canvas.height, alignment: .top)

            ZStack(alignment: .top) {
                wings(H: H, s: s, visible: visible)

                if let s {
                    PeekRow(step: s.step, epoch: c.peekEpoch, active: c.ui == .peek, reduce: c.reduceMotion)
                        .frame(width: 360, height: 38)
                        .padding(.top, H)
                        .layer(on: c.ui == .peek, reduce: c.reduceMotion)

                    OpenPanel(c: c, s: s, active: c.ui == .open)
                        .frame(width: 420)
                        .padding(.top, H + 6)
                        .layer(on: c.ui == .open, reduce: c.reduceMotion)

                    QuestionRow(c: c, pending: s.pending, active: c.ui == .question)
                        .frame(width: 380, height: 44)
                        .padding(.top, H)
                        .layer(on: c.ui == .question, reduce: c.reduceMotion)
                }
            }
            .frame(width: max(0, c.w), height: max(0, c.h), alignment: .top)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: c.r, bottomTrailingRadius: c.r))
            .contentShape(Rectangle())
            .onTapGesture { c.clickNotch() }
        }
        .frame(width: NotchController.canvas.width, height: NotchController.canvas.height, alignment: .top)
        .opacity(c.shapeOpacity)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Code activity")
    }

    @ViewBuilder
    private func wings(H: CGFloat, s: Session?, visible: Bool) -> some View {
        let showStep = c.ui == .peek || c.ui == .open
        HStack(spacing: 0) {
            // left wing: spark + elapsed time
            HStack(spacing: 5) {
                SparkGlyph(mode: c.glyphMode, active: visible, reduce: c.reduceMotion)
                Text(c.timerText)
                    .font(TextStyle.timer.font)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
            }
            .padding(.leading, 10)

            Spacer(minLength: 0)

            // right wing: the current verb (compact / question) or step number (peek / open)
            ZStack(alignment: .trailing) {
                WingWord(word: c.wingWord, tone: c.wingTone, reduce: c.reduceMotion)
                    .modifier(BlurFade(on: !showStep, dy: 5))
                Text(stepLabel(s))
                    .font(TextStyle.wingStep.font)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
                    .modifier(BlurFade(on: showStep, dy: -5))
            }
            .animation(Theme.easeOut(0.35), value: showStep)
            .padding(.trailing, 10)
        }
        .frame(width: max(0, c.w), height: H)
        .opacity(visible ? 1 : 0)
        .animation(visible ? .easeOut(duration: 0.3).delay(0.1) : .easeOut(duration: 0.18), value: visible)
    }

    private func stepLabel(_ s: Session?) -> String {
        guard let s else { return "" }
        return s.stepCount == 0 ? "" : "step \(s.stepCount)"
    }
}

// MARK: - Wing word

/// One word in the right wing, swapped with a small rise and blur.
struct WingWord: View {
    let word: String
    let tone: Tone
    let reduce: Bool
    var body: some View {
        ZStack(alignment: .trailing) {
            Text(word)
                .font(TextStyle.wingVerb.font)
                .foregroundStyle(tone == .normal ? Color.white : Theme.toneColor(tone))
                .fixedSize()
                .id(word + "\(tone)")
                .transition(reduce ? .opacity : .asymmetric(
                    insertion: .modifier(active: BlurFade(on: false, dy: 6), identity: BlurFade(on: true, dy: 6)),
                    removal: .modifier(active: BlurFade(on: false, dy: -7), identity: BlurFade(on: true, dy: -7))))
        }
        .animation(reduce ? .easeOut(duration: 0.2) : Theme.easeOut(0.35), value: word + "\(tone)")
    }
}

struct BlurFade: ViewModifier {
    let on: Bool
    var dy: CGFloat = 6
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).blur(radius: on ? 0 : 3).offset(y: on ? 0 : dy)
    }
}

// MARK: - Layers

private struct LayerModifier: ViewModifier {
    let on: Bool
    let reduce: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .blur(radius: on || reduce ? 0 : 6)
            .scaleEffect(on || reduce ? 1 : 0.97, anchor: .top)
            .offset(y: on || reduce ? 0 : -6)
            // In: wait a beat for the shape to start growing. Out: get out of the way fast.
            .animation(on ? Theme.easeOut(0.36).delay(0.08) : .easeOut(duration: 0.14), value: on)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
    }
}

extension View {
    func layer(on: Bool, reduce: Bool) -> some View { modifier(LayerModifier(on: on, reduce: reduce)) }
}

// MARK: - Peek: one line of live text

struct PeekRow: View {
    let step: Step
    let epoch: Int
    let active: Bool
    let reduce: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            row
                .id("\(step.id)-\(epoch)")
                .transition(reduce ? .opacity : .asymmetric(
                    insertion: .identity,
                    removal: .modifier(active: BlurFade(on: false, dy: -7), identity: BlurFade(on: true, dy: -7))))
        }
        .animation(.easeOut(duration: 0.2), value: "\(step.id)-\(epoch)")
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var metaWidth: CGFloat {
        if let m = step.metaText { return TextStyle.meta.width(m) }
        if let n = step.count { return TextStyle.metaDigits.width(String(n)) + TextStyle.meta.width(" " + step.unit) }
        return 0
    }

    private var row: some View {
        let verbColor = Theme.toneColor(step.tone)
        let verbW = TextStyle.verb.width(step.verb)
        let thinking = step.mode == .think && step.detail.isEmpty
        let detailW = max(0, 360 - 36 - verbW - 2 - (metaWidth > 0 ? metaWidth + 8 : 0) - 8)
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                StreamText(text: step.verb, style: .verb, color: verbColor, reduce: reduce)
                if thinking { ThinkingDots(active: active, reduce: reduce) }
            }
            if !step.detail.isEmpty {
                DetailLine(text: step.detail, kind: step.kind, width: detailW, active: active, reduce: reduce)
                    .padding(.leading, -6)   // the 8pt inner inset holds the soft left edge
            }
            Spacer(minLength: 0)
            if let m = step.metaText {
                Text(m).font(TextStyle.meta.font).foregroundStyle(.white.opacity(0.45)).fixedSize()
            } else if let n = step.count, let start = step.countStart {
                HStack(spacing: 0) {
                    Odometer(target: n, start: start, active: active, reduce: reduce)
                    Text(" " + step.unit).font(TextStyle.meta.font).foregroundStyle(.white.opacity(0.45))
                }
                .fixedSize()
                .frame(minWidth: metaWidth, alignment: .trailing)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Open: the full picture

struct OpenPanel: View {
    @ObservedObject var c: NotchController
    let s: Session
    let active: Bool

    var body: some View {
        let tone = Theme.toneColor(s.step.tone)
        VStack(alignment: .leading, spacing: 0) {
            Text(s.prompt.isEmpty ? " " : "“\(s.prompt)”")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1).truncationMode(.tail)

            nowText(tone: tone)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 39, alignment: .topLeading)
                .padding(.top, 10)

            ProgressLine(status: s.status, active: active, reduce: c.reduceMotion)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                ForEach(s.history) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green)
                        Text(item.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .transition(.modifier(active: BlurFade(on: false, dy: 4), identity: BlurFade(on: true, dy: 4)))
                }
            }
            .animation(Theme.easeOut(0.35), value: s.history)
            .frame(height: 66, alignment: .bottom)
            .padding(.top, 12)

            HStack {
                Text(footText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                PillButton(title: "Open \(s.hostName ?? "Terminal")") { c.openHost() }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func nowText(tone: Color) -> Text {
        let verb = Text(s.step.verb).foregroundStyle(tone)
        guard !s.step.detail.isEmpty else { return verb.font(.system(size: 14, weight: .semibold)) }
        let detail = Text(s.step.detail)
            .font(s.step.kind == .text ? .system(size: 14) : .system(size: 12.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.66))
        return Text("\(verb) \(detail)").font(.system(size: 14, weight: .semibold))
    }

    private var footText: String {
        let n = s.stepCount
        if s.status == .done, let t0 = s.startedAt, let t1 = s.endedAt {
            return "\(n) step\(n == 1 ? "" : "s") · \(formatLong(t1.timeIntervalSince(t0)))"
        }
        return n == 0 ? "Starting" : "Step \(n)"
    }
}

/// We don't know how many steps a run will take, so while running the bar is a
/// soft travelling glow; it fills green when the run is done.
struct ProgressLine: View {
    let status: RunStatus
    let active: Bool
    let reduce: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                switch status {
                case .done:
                    Capsule().fill(Theme.green).transition(.opacity)
                case .permission, .waiting:
                    Capsule().fill(Theme.amber.opacity(0.55)).transition(.opacity)
                default:
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduce)) { ctx in
                        let p = (ctx.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1)
                        let segW = geo.size.width * 0.28
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent, Theme.accent.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: segW)
                            .offset(x: reduce ? (geo.size.width - segW) / 2 : -segW + (geo.size.width + segW) * DetailLine.easeInOut(p))
                    }
                    .clipShape(Capsule())
                }
            }
            .animation(.easeOut(duration: 0.4), value: status)
        }
        .frame(height: 3)
    }
}

// MARK: - Question: one row, the one time the notch opens itself

struct QuestionRow: View {
    @ObservedObject var c: NotchController
    let pending: PendingPermission?
    let active: Bool

    var body: some View {
        let label = pending?.label ?? ""
        let detail = pending?.detail ?? ""
        let buttons: CGFloat = 60 + 62 + 12
        HStack(spacing: 6) {
            DetailLine(text: detail, kind: .mono, width: max(40, 380 - 25 - buttons - 8),
                       color: .white.opacity(0.82), prefix: label, revealDelay: 0, active: active, reduce: c.reduceMotion)
                .id(pending?.id)
            PillButton(title: "Deny", small: true) { c.model.answer(allow: false) }
                .keyboardShortcut(.cancelAction)
            PillButton(title: "Allow", primary: true, small: true) { c.model.answer(allow: true) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude wants to run \(label) \(detail)")
    }
}

// MARK: - Pill button

struct PillButton: View {
    let title: String
    var primary = false
    var small = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: small ? 11.5 : 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(PillStyle(primary: primary, small: small, hovering: hovering))
        .onHover { hovering = $0 }
    }
}

struct PillStyle: ButtonStyle {
    let primary: Bool
    let small: Bool
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, small ? 11 : 13)
            .padding(.vertical, small ? 5 : 7)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(Capsule().fill(primary
                ? Color(white: hovering ? 0.914 : 1)
                : Color.white.opacity(hovering ? 0.16 : 0.1)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.easeOut(0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Capsule())
    }
}
