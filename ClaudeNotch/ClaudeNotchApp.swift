import AppKit
import ServiceManagement
import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var focus: FocusWatcher!
    private var model: NotchModel!
    private var controller: NotchController!
    private var panel: NotchPanel!
    private let server = SocketServer()
    private var menu: NSMenu!
    private var monitors: [Any] = []
    private var serverError: String?
    private var demo: DemoRun?
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        HookSettings.installScript()
        LoginItem.setUpOnFirstInstalledLaunch()
        focus = FocusWatcher()
        model = NotchModel(focus: focus)
        controller = NotchController(model: model)
        focus.onChange = { [weak self] in self?.model.focusChanged() }

        panel = NotchPanel()
        let host = NotchHostingView(rootView: NotchView(c: controller, model: model))
        host.onMouse = { [weak self] p in self?.controller.pointerMoved(p) }
        host.onRightClick = { [weak self] e in self?.showMenu(rightClick: e) }
        panel.contentView = host
        panel.place(controller.metrics)
        panel.orderFrontRegardless()
        controller.panel = panel

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.screenChanged()
                self.panel.place(self.controller.metrics)
            }
        }

        // Pointer tracking while other apps are active (no Accessibility permission needed for mouse moves).
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.pointerMoved(NSEvent.mouseLocation) }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.clickOutside() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                if e.type == .keyDown, e.keyCode == 53 { self?.controller.escape(); return nil }   // Esc
                if e.type == .mouseMoved { self?.controller.pointerMoved(NSEvent.mouseLocation) }
                return e
            }
        } as Any)

        server.onRequest = { [weak self] req, respond in
            MainActor.assumeIsolated {
                guard let self else { respond(""); return }
                #if DEBUG
                if req.path.hasPrefix("/debug/") { self.debug(req, respond); return }
                #endif
                let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
                let pid = req.headers["x-claude-pid"].flatMap { pid_t($0) }
                self.model.handle(json, pid: pid, reply: respond)
            }
        }
        do { try server.start() } catch { serverError = "\(error)"; NSLog("ClaudeNotch: socket failed: \(error)") }

        buildMenu()
    }

    func applicationWillTerminate(_ note: Notification) { server.stop() }

    // MARK: - Menu bar item

    // MARK: - Menu (no menu-bar icon)
    //
    // There's deliberately no icon in the menu bar. The menu opens when you
    // right-click the notch while it's showing, or open Claude Notch again
    // (Spotlight, Launchpad or /Applications) while it's already running.

    private func buildMenu() {
        menu = NSMenu()
        let title = NSMenuItem(title: serverError == nil ? "Claude Notch · listening" : "Claude Notch · socket error", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Play Demo Run", #selector(playDemo), "d"))
        menu.addItem(item("Copy Hooks Settings JSON", #selector(copyHooks), "c"))
        menu.addItem(item("Reveal Hook Script", #selector(revealHook), ""))
        menu.addItem(.separator())
        loginItem = item("Start at Login", #selector(toggleLogin), "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Claude Notch", #selector(quit), "q"))
        menu.delegate = self
    }

    /// Opening the app again while it's running shows its menu, just under the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu(rightClick: nil)
        return false
    }

    private func showMenu(rightClick: NSEvent?) {
        if let e = rightClick, let view = panel.contentView {
            NSMenu.popUpContextMenu(menu, with: e, for: view)
            return
        }
        let m = controller.metrics
        let width = max(menu.size.width, 220)
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSPoint(x: m.centerX - width / 2, y: m.top - m.height - 6), in: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = LoginItem.isOn ? .on : .off
        loginItem.title = LoginItem.needsApproval ? "Start at Login (approve in System Settings)" : "Start at Login"
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isOn)
    }

    private func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func playDemo() {
        demo = DemoRun(model: model)
        demo?.start()
    }

    @objc private func copyHooks() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HookSettings.json, forType: .string)
    }

    @objc private func revealHook() {
        NSWorkspace.shared.selectFile(HookSettings.scriptPath, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    #if DEBUG
    /// Debug-only hooks for testing without screen-recording permission:
    /// /debug/snapshot (body = output PNG path), /debug/hover, /debug/click, /debug/leave, /debug/demo, /debug/state
    private func debug(_ req: SocketServer.Request, _ respond: (String) -> Void) {
        let arg = String(decoding: req.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch req.path {
        case "/debug/snapshot":
            guard let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { respond("no view"); return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))) != nil
            respond(ok ? "ok" : "write failed")
        case "/debug/hover": controller.debugPointer(inside: true); respond("ok")
        case "/debug/leave": controller.debugPointer(inside: false); respond("ok")
        case "/debug/click": controller.clickNotch(); respond("ok")
        case "/debug/demo": playDemo(); respond("ok")
        case "/debug/allow": model.answer(allow: true); respond("ok")
        case "/debug/deny": model.answer(allow: false); respond("ok")
        case "/debug/sleep": model.debugSleepCurrent(); respond("ok")
        case "/debug/state":
            let s = model.current
            respond("ui=\(controller.ui) start=\(s?.startedAt.map { Int($0.timeIntervalSince1970) } ?? 0) steps=\(s?.stepCount ?? 0) hist=\(s?.history.map(\.text) ?? []) running=\(s?.toolsRunning ?? 0) w=\(Int(controller.w)) h=\(Int(controller.h)) status=\(String(describing: s?.status)) verb=\(s?.step.verb ?? "-") detail=\(s?.step.detail ?? "-") count=\(String(describing: s?.step.count)) host=\(s?.hostName ?? "-") metrics=\(controller.metrics)")
        default: respond("?")
        }
    }
    #endif
}

enum HookSettings {
    /// The app copies its bundled hook script here on every launch. Claude Code's
    /// settings point at this path, so moving or deleting the repo can't break them.
    static let scriptPath = NSHomeDirectory() + "/Library/Application Support/ClaudeNotch/notch-hook.sh"
    static let command = "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\""

    static let events: [(String, Int)] = [
        ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5), ("PostToolUseFailure", 5),
        ("PermissionRequest", 40), ("Notification", 5), ("Stop", 5), ("SessionEnd", 5),
    ]

    static var json: String {
        var hooks: [String: Any] = [:]
        for (event, timeout) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "\(command) \(event)", "timeout": timeout]]]]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Copy the bundled script into place if it's missing or out of date.
    /// Written to a temp file and renamed, so a hook running right now never reads half a file.
    static func installScript() {
        guard let src = Bundle.main.url(forResource: "notch-hook", withExtension: "sh"),
              let data = try? Data(contentsOf: src) else { NSLog("ClaudeNotch: hook script missing from bundle"); return }
        let dst = URL(fileURLWithPath: scriptPath)
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if (try? Data(contentsOf: dst)) == data, fm.isExecutableFile(atPath: dst.path) { return }
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".notch-hook.\(getpid()).tmp")
        do {
            try data.write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            if rename(tmp.path, dst.path) != 0 { throw POSIXError(.EIO) }
        } catch {
            try? fm.removeItem(at: tmp)
            NSLog("ClaudeNotch: couldn't install hook script: \(error)")
        }
    }
}

/// Start at Login, via the system's Login Items (System Settings → General → Login Items).
@MainActor
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudeNotch: login item \(on ? "register" : "unregister") failed: \(error)")
        }
        if on && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Turn it on once, the first time the installed copy (in /Applications) runs.
    /// Builds run from Xcode never register themselves.
    static func setUpOnFirstInstalledLaunch() {
        let key = "didSetUpLoginItem"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
