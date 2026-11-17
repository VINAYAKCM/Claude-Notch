import AppKit
import Combine
import SwiftUI

/// The notch's visible states (the prototype called peek "live" and open "expanded").
enum UIState: Equatable { case hidden, compact, peek, open, question }

/// Owns the notch's shape and which state it's in. Drives three springs
/// (width, height, corner radius) and decides hover / click / pin behaviour.
@MainActor
final class NotchController: ObservableObject {
    @Published private(set) var ui: UIState = .hidden
    @Published private(set) var w: CGFloat = 186
    @Published private(set) var h: CGFloat = 32
    @Published private(set) var r: CGFloat = 10
    @Published private(set) var shapeOpacity: Double = 0
    @Published private(set) var timerText = "0:00"
    /// Bumps each time peek opens from compact, so the live row replays its text.
    @Published private(set) var peekEpoch = 0
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published private(set) var metrics = NotchMetrics.current()

    let model: NotchModel
    weak var panel: NSPanel?

    private var sw = Spring(186), sh = Spring(32), sr = Spring(10)
    private var frameTimer: Timer?
    private var clockTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var bag = Set<AnyCancellable>()

    private(set) var hover = false
    private(set) var pinned = false
    private var pointerInside = false
    private var enterWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?

    /// Size of the window that hosts the notch. Big enough for the open state.
    static let canvas = CGSize(width: 640, height: 360)

    init(model: NotchModel) {
        self.model = model
        let m = metrics
        sw = Spring(m.cameraWidth); sh = Spring(m.height)
        w = m.cameraWidth; h = m.height
        model.isHovering = { [weak self] in (self?.hover ?? false) || (self?.pinned ?? false) }
        model.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            .store(in: &bag)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
    }

    func screenChanged() {
        metrics = NotchMetrics.current()
        // Re-target for the new geometry without animating from stale numbers.
        let d = dims(ui)
        sw.to(d.w, k: 680, c: 52); sh.to(d.h, k: 760, c: 55); sr.to(d.r, k: 680, c: 52)
        sw.snap(); sh.snap(); sr.snap()
        publish()
    }

    // MARK: - What to show

    private func desired() -> UIState {
        guard let s = model.current else { return .hidden }
        if model.hostIsFrontmost(s) { return .hidden }
        let level: UIState = pinned ? .open : (hover ? .peek : .compact)
        switch s.status {
        case .running, .waiting: return level
        case .permission: return .question
        case .done: return model.showDone ? level : .hidden
        case .idle: return .hidden
        }
    }

    var canOpen: Bool { ui == .compact || ui == .peek || ui == .open }

    func apply() {
        let next = desired()
        if next == .hidden { hover = false; pinned = false }
        updateClock()
        guard next != ui else { refitCompact(); return }
        let prev = ui
        ui = next
        if next == .peek && prev != .open { peekEpoch += 1 }

        let d = dims(next)
        let grow = d.w * d.h > sw.target * sh.target
        if grow {
            // Opening: a little bounce (ζ ≈ 0.78). Width leads, height follows a beat behind.
            sw.to(d.w, k: 420, c: 32); sh.to(d.h, k: 300, c: 27); sr.to(d.r, k: 420, c: 32)
        } else {
            // Closing: critically damped (ζ ≈ 1), no wobble on the way home.
            sw.to(d.w, k: 680, c: 52); sh.to(d.h, k: 760, c: 55); sr.to(d.r, k: 680, c: 52)
        }
        if reduceMotion { sw.snap(); sh.snap(); sr.snap() }

        if next != .hidden {
            if metrics.hasNotch || reduceMotion { shapeOpacity = 1 }
            else { withAnimation(.easeOut(duration: 0.18)) { shapeOpacity = 1 } }
        } else if !metrics.hasNotch {
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.25)) { shapeOpacity = 0 }
        }
        if next != .open, panel?.isKeyWindow == true { panel?.resignKey() }
        kick()
        pointerMoved(NSEvent.mouseLocation)
    }

    struct Dims { var w: CGFloat; var h: CGFloat; var r: CGFloat }

    func dims(_ s: UIState) -> Dims {
        let H = metrics.height
        switch s {
        case .hidden:   return metrics.hasNotch ? Dims(w: metrics.cameraWidth, h: H, r: 10) : Dims(w: compactWidth() * 0.7, h: H, r: 10)
        case .compact:  return Dims(w: compactWidth(), h: H, r: 10)
        case .peek:     return Dims(w: max(360, metrics.cameraWidth + 120), h: H + 38, r: 22)
        case .open:     return Dims(w: max(420, metrics.cameraWidth + 160), h: H + 248, r: 30)
        case .question: return Dims(w: max(380, metrics.cameraWidth + 140), h: H + 44, r: 22)
        }
    }

    /// The compact state hugs its content. Each wing is as wide as the larger of
    /// [padding · spark · timer] and [verb · padding], and both wings match so the
    /// shape stays centred on the camera.
    func compactWidth() -> CGFloat {
        let left = 10 + 16 + 5 + TextStyle.timer.width(timerText)
        let right = 4 + TextStyle.wingVerb.width(wingWord) + 10
        return metrics.cameraWidth + 2 * ceil(max(left, right))
    }

    private func refitCompact() {
        guard ui == .compact else { return }
        let w = compactWidth()
        guard abs(w - sw.target) >= 0.5 else { return }
        sw.to(w, k: 300, c: 35)
        if reduceMotion { sw.snap() }
        kick()
    }

    var wingWord: String {
        guard let s = model.current else { return "" }
        switch s.status {
        case .permission: return "Permission"
        default: return s.step.verb
        }
    }

    var wingTone: Tone {
        guard let s = model.current else { return .normal }
        if s.status == .permission { return .wait }
        return s.step.tone
    }

    var glyphMode: GlyphMode {
        guard let s = model.current else { return .think }
        switch s.status {
        case .permission, .waiting: return .wait
        case .done: return .done
        default: return s.step.mode
        }
    }

    private func updateClock() {
        guard let s = model.current, let t0 = s.startedAt else { return }
        let t = formatClock((s.endedAt ?? Date()).timeIntervalSince(t0))
        if t != timerText {
            let grew = t.count != timerText.count
            timerText = t
            if grew { refitCompact() }   // 9:59 → 10:00 needs a little more room
        }
    }

    // MARK: - Frame loop (runs only while a spring is moving)

    private func kick() {
        guard frameTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastTick)
        lastTick = now
        // Small fixed sub-steps keep stiff springs stable at any frame rate.
        let n = max(1, Int(ceil(dt / (1.0 / 240))))
        for _ in 0..<n { sw.step(dt / Double(n)); sh.step(dt / Double(n)); sr.step(dt / Double(n)) }
        publish()
        if sw.atRest && sh.atRest && sr.atRest {
            sw.snap(); sh.snap(); sr.snap(); publish()
            frameTimer?.invalidate(); frameTimer = nil
            // Back in the hardware: stop drawing so nothing peeks out around the real notch.
            if ui == .hidden && metrics.hasNotch { shapeOpacity = 0 }
        }
    }

    private func publish() {
        w = sw.value; h = max(metrics.height - 2, sh.value); r = max(0, sr.value)
    }

    // MARK: - Pointer: hover intent, click to pin

    /// The area that reacts to the pointer, in screen coordinates.
    private func hitRect() -> NSRect {
        guard ui != .hidden else { return .zero }
        let d = dims(ui)
        return NSRect(x: metrics.centerX - d.w / 2 - 2, y: metrics.top - d.h - 4, width: d.w + 4, height: d.h + 10)
    }

    #if DEBUG
    private var debugPointerOverride = false
    #endif

    func pointerMoved(_ p: NSPoint) {
        #if DEBUG
        if debugPointerOverride { panel?.ignoresMouseEvents = !pointerInside; return }
        #endif
        let inside = hitRect().contains(p)
        panel?.ignoresMouseEvents = !inside
        guard inside != pointerInside else { return }
        pointerInside = inside
        inside ? pointerEntered() : pointerLeft()
    }

    private func pointerEntered() {
        leaveWork?.cancel()
        guard !hover, canOpen else { return }
        enterWork = after(0.11) { [weak self] in   // hover intent: ignore a pointer just passing through
            guard let self, self.pointerInside else { return }
            self.hover = true
            self.apply()
        }
    }

    private func pointerLeft() {
        enterWork?.cancel()
        leaveWork = after(0.14) { [weak self] in
            guard let self, !self.pointerInside else { return }
            self.hover = false
            self.apply()
            if self.model.pendingHide && !self.pinned { self.model.pendingHide = false; self.model.scheduleHide() }
        }
    }

    #if DEBUG
    /// Simulate the pointer entering / leaving the notch (for automated checks).
    func debugPointer(inside: Bool) {
        debugPointerOverride = true
        guard inside != pointerInside else { return }
        pointerInside = inside
        inside ? pointerEntered() : pointerLeft()
    }
    #endif

    func clickNotch() {
        guard canOpen else { return }
        if hover && !pinned { pinned = true }
        else { pinned.toggle(); if !pinned { hover = pointerInside } }
        if pinned { panel?.makeKey() }
        apply()
        if !pinned && model.pendingHide { model.pendingHide = false; model.scheduleHide() }
    }

    func clickOutside() {
        guard pinned else { return }
        pinned = false
        apply()
        if model.pendingHide { model.pendingHide = false; model.scheduleHide() }
    }

    func escape() {
        pinned = false; hover = false
        apply()
    }

    func openHost() {
        pinned = false; hover = false
        model.activateHost()
        apply()
    }
}
