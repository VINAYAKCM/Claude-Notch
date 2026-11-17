import AppKit
import SwiftUI

/// Colours, fonts and motion constants, matching the web prototype's CSS variables.
enum Theme {
    static let accentRGB = SIMD3<Double>(0xD9, 0x77, 0x57) / 255   // --accent
    static let amberRGB  = SIMD3<Double>(0xF2, 0xB2, 0x52) / 255   // --amber
    static let greenRGB  = SIMD3<Double>(0x5D, 0xD3, 0x9E) / 255   // --green

    static let accent = Color(rgb: accentRGB)
    static let amber  = Color(rgb: amberRGB)
    static let green  = Color(rgb: greenRGB)

    /// The prototype's `--ease-out: cubic-bezier(.2, .8, .2, 1)`.
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }

    static func toneColor(_ tone: Tone) -> Color {
        switch tone {
        case .normal: return .white
        case .wait: return amber
        case .done: return green
        }
    }
}

extension Color {
    init(rgb: SIMD3<Double>) { self.init(red: rgb.x, green: rgb.y, blue: rgb.z) }
}

/// Paired SwiftUI / AppKit fonts, so we can measure text exactly as it will render.
struct TextStyle {
    let font: Font
    let ns: NSFont

    static let timer     = TextStyle(font: .system(size: 11).monospacedDigit(), ns: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    static let wingVerb  = TextStyle(font: .system(size: 11, weight: .semibold), ns: .systemFont(ofSize: 11, weight: .semibold))
    static let wingStep  = TextStyle(font: .system(size: 11.5).monospacedDigit(), ns: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular))
    static let verb      = TextStyle(font: .system(size: 13, weight: .semibold), ns: .systemFont(ofSize: 13, weight: .semibold))
    static let detail    = TextStyle(font: .system(size: 12.5), ns: .systemFont(ofSize: 12.5))
    static let detailMono = TextStyle(font: .system(size: 11.5, design: .monospaced), ns: .monospacedSystemFont(ofSize: 11.5, weight: .regular))
    static let metaDigits = TextStyle(font: .system(size: 12, weight: .medium).monospacedDigit(), ns: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
    static let meta      = TextStyle(font: .system(size: 12), ns: .systemFont(ofSize: 12))

    func width(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: ns]).width)
    }
}

/// Run something on the main actor after a delay. Returns the work item so it can be cancelled.
@discardableResult
func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> DispatchWorkItem {
    let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    return item
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

/// `cubic-bezier(.2,.8,.2,1)`-ish ease-out for hand-driven tweens.
func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }

func formatClock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

func formatLong(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}
