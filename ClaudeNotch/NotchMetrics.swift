import AppKit

/// Where the camera housing is, measured from the real screen.
///
/// On a notched MacBook, `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are
/// the usable menu-bar strips either side of the notch, so the notch is whatever
/// is left in between. `safeAreaInsets.top` is its height. On a Mac without a
/// notch those are nil, and we fall back to a small pill at the top centre.
struct NotchMetrics: Equatable {
    var screenFrame: NSRect
    var hasNotch: Bool
    /// Width of the area we can't draw content in (the camera housing).
    var cameraWidth: CGFloat
    /// Height of the notch / menu bar.
    var height: CGFloat

    var centerX: CGFloat
    var top: CGFloat { screenFrame.maxY }

    static func current() -> NotchMetrics {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
        let screen = notched ?? NSScreen.main ?? screens.first!
        let f = screen.frame

        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            let w = f.width - l.width - r.width
            return NotchMetrics(screenFrame: f, hasNotch: true, cameraWidth: w,
                                height: screen.safeAreaInsets.top, centerX: f.minX + l.width + w / 2)
        }
        let menuBar = f.maxY - screen.visibleFrame.maxY
        return NotchMetrics(screenFrame: f, hasNotch: false, cameraWidth: 24,
                            height: menuBar > 10 ? menuBar : 24, centerX: f.midX)
    }
}
