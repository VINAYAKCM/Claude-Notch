import AppKit
import SwiftUI

/// A borderless, see-through panel pinned to the top of the screen, above the menu bar,
/// on every Space. It ignores the mouse except while the pointer is over the notch,
/// so it never blocks the menu bar underneath.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: NotchController.canvas),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Let the window sit over the menu bar instead of being nudged below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func place(_ m: NotchMetrics) {
        let size = NotchController.canvas
        setFrame(NSRect(x: m.centerX - size.width / 2, y: m.top - size.height, width: size.width, height: size.height), display: true)
    }
}

/// Hosting view that takes the first click (no "activate first" click) and reports
/// pointer movement over the window, even when another app is active.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onMouse: ((NSPoint) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); onMouse?(NSEvent.mouseLocation) }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onMouse?(NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onMouse?(NSEvent.mouseLocation) }
}
