import SwiftUI

/// The real MacBook notch outline: concave fillets where it meets the top edge,
/// straight sides, round bottom corners. Drawn fresh from the springs every frame,
/// so the corners never distort the way scaling a fixed shape would.
struct NotchShape: Shape {
    var w: CGFloat
    var h: CGFloat
    var r: CGFloat
    /// Radius of the concave "shoulders" at the top.
    var shoulder: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let x0 = cx - w / 2, x1 = cx + w / 2
        let sh = shoulder
        let r = max(0, min(r, h - sh, w / 2))
        var p = Path()
        p.move(to: CGPoint(x: x0 - sh, y: 0))
        // concave shoulder, left
        p.addArc(center: CGPoint(x: x0 - sh, y: sh), radius: sh, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: x0, y: h - r))
        // convex bottom-left
        p.addArc(center: CGPoint(x: x0 + r, y: h - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: x1 - r, y: h))
        // convex bottom-right
        p.addArc(center: CGPoint(x: x1 - r, y: h - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: x1, y: sh))
        // concave shoulder, right
        p.addArc(center: CGPoint(x: x1 + sh, y: sh), radius: sh, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
