import AppKit
import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focus: FocusWatcher!
    private var model: NotchModel!
    private var controller: NotchController!
    private var panel: NotchPanel!
    private let server = SocketServer()
    private var statusItem: NSStatusItem!
    private var monitors: [Any] = []
    private var serverError: String?
    private var demo: DemoRun?

    func applicationDidFinishLaunching(_ note: Notification) {
        focus = FocusWatcher()
        model = NotchModel(focus: focus)
        controller = NotchController(model: model)
        focus.onChange = { [weak self] in self?.model.focusChanged() }

        panel = NotchPanel()
        let host = NotchHostingView(rootView: NotchView(c: controller, model: model))
        host.onMouse = { [weak self] p in self?.controller.pointerMoved(p) }
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

        setupStatusItem()
    }

    func applicationWillTerminate(_ note: Notification) { server.stop() }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Notch")
        let menu = NSMenu()
        let title = NSMenuItem(title: serverError == nil ? "Claude Notch · listening" : "Claude Notch · socket error", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Play Demo Run", #selector(playDemo), "d"))
        menu.addItem(item("Copy Hooks Settings JSON", #selector(copyHooks), "c"))
        menu.addItem(item("Reveal Hook Script", #selector(revealHook), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Claude Notch", #selector(quit), "q"))
        statusItem.menu = menu
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
        case "/debug/state":
            let s = model.current
            respond("ui=\(controller.ui) w=\(Int(controller.w)) h=\(Int(controller.h)) status=\(String(describing: s?.status)) verb=\(s?.step.verb ?? "-") detail=\(s?.step.detail ?? "-") count=\(String(describing: s?.step.count)) host=\(s?.hostName ?? "-") metrics=\(controller.metrics)")
        default: respond("?")
        }
    }
    #endif
}

enum HookSettings {
    /// The hook script lives in the repo; the settings use $HOME so they stay portable.
    static let scriptPath = NSHomeDirectory() + "/Documents/claude-notch-app/hooks/notch-hook.sh"
    static let command = "\"$HOME/Documents/claude-notch-app/hooks/notch-hook.sh\""

    static var json: String {
        func entry(_ event: String, timeout: Int) -> String {
            """
                "\(event)": [
                  { "hooks": [ { "type": "command", "command": "\(command.replacingOccurrences(of: "\"", with: "\\\"")) \(event)", "timeout": \(timeout) } ] }
                ]
            """
        }
        let events = [("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5),
                      ("PermissionRequest", 40), ("Notification", 5), ("Stop", 5), ("SessionEnd", 5)]
        return "{\n  \"hooks\": {\n" + events.map { entry($0.0, timeout: $0.1) }.joined(separator: ",\n") + "\n  }\n}\n"
    }
}
