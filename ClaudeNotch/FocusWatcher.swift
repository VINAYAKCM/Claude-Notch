import AppKit
import Darwin

/// Tracks which app is frontmost, so the notch can step aside while you're
/// already looking at the terminal Claude is running in.
@MainActor
final class FocusWatcher {
    private(set) var frontPID: pid_t?
    var onChange: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    init() {
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(app?.processIdentifier) }
        })
        // Switching Spaces changes what's in front without always posting an activation.
        tokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(NSWorkspace.shared.frontmostApplication?.processIdentifier) }
        })
    }

    private func update(_ pid: pid_t?) {
        guard pid != frontPID else { return }
        frontPID = pid
        onChange?()
    }

    func isFrontmost(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return pid == frontPID
    }

    /// Walk up the process tree from the hook (shell → claude → zsh → login → Terminal)
    /// until we reach a regular GUI app. That's the window Claude lives in.
    static func hostApp(for pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<64 {
            if p <= 1 { return nil }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return app
            }
            p = parentPID(of: p)
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}
