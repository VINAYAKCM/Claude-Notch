import Foundation

/// A damped spring, the same one the web prototype uses.
///
/// Every frame we nudge `value` toward `target` with a force proportional to the
/// distance (stiffness `k`) minus a drag proportional to the speed (damping `c`).
/// Because position *and* velocity persist, changing the target mid-flight never
/// jumps: the motion just bends toward the new goal. That's what makes it
/// "interruptible".
///
/// Damping ratio ζ = c / (2√k). Below 1 it overshoots a little (bounce);
/// at 1 it settles as fast as possible with no overshoot (critically damped).
struct Spring {
    var value: Double
    var target: Double
    var velocity: Double = 0
    var k: Double = 400
    var c: Double = 40

    init(_ v: Double) { value = v; target = v }

    mutating func to(_ t: Double, k: Double, c: Double) {
        target = t; self.k = k; self.c = c
    }

    mutating func snap() { value = target; velocity = 0 }

    mutating func step(_ dt: Double) {
        let a = -k * (value - target) - c * velocity
        velocity += a * dt
        value += velocity * dt
    }

    var atRest: Bool { abs(value - target) < 0.02 && abs(velocity) < 0.02 }
}
