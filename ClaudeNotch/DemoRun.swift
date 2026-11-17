import Foundation

/// Plays a scripted run through the same event pipeline real hooks use,
/// so you can see every state without starting Claude Code.
/// It has no host app, so it shows even while this app's menu is in front.
@MainActor
final class DemoRun {
    private let model: NotchModel
    private let sid = "demo-\(UUID().uuidString.prefix(6))"
    private let cwd = NSHomeDirectory() + "/acme-site"

    init(model: NotchModel) { self.model = model }

    private func send(_ name: String, _ extra: [String: Any] = [:], reply: ((String) -> Void)? = nil) {
        var e: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": cwd]
        e.merge(extra) { $1 }
        model.handle(e, pid: nil, reply: reply)
    }

    func start() {
        let p1 = cwd + "/src/app/(marketing)/pricing/_components/PricingTable.tsx"
        let p2 = cwd + "/src/app/(marketing)/pricing/_components/BillingToggle.tsx"
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping @MainActor () -> Void) { t += dt; after(t, f) }

        at(0.2) { self.send("UserPromptSubmit", ["prompt": "Redesign the pricing page and add a yearly billing toggle"]) }
        at(2.4) { self.send("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": p1]]) }
        at(2.6) { self.send("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": p1], "tool_response": ["file": ["numLines": 219]]]) }
        at(1.4) { self.send("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "billingCycle", "path": self.cwd + "/src"]]) }
        at(1.8) { self.send("PostToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "billingCycle"], "tool_response": ["numFiles": 6]]) }
        at(2.8) { self.send("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": p1]]) }
        at(2.8) { self.send("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": p1],
                                             "tool_response": ["structuredPatch": [["lines": Array(repeating: "+x", count: 42) + Array(repeating: "-y", count: 9)]]]]) }
        at(1.4) { self.send("PreToolUse", ["tool_name": "Write", "tool_input": ["file_path": p2, "content": String(repeating: "line\n", count: 64)]]) }
        at(2.2) { self.send("PostToolUse", ["tool_name": "Write", "tool_input": ["file_path": p2, "content": String(repeating: "line\n", count: 64)]]) }
        let cmd = "npm run test -- pricing --reporter=dot && npm run lint -- --fix src/app/(marketing)/pricing"
        at(1.4) { self.send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": cmd]]) }
        at(3.6) { self.send("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": cmd], "duration_ms": 1830]) }
        let commit = "git commit -m \"feat(pricing): add yearly billing toggle\""
        at(1.4) { self.send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": commit]]) }
        at(0.6) {
            self.send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": commit]]) { [weak self] answer in
                guard let self else { return }
                // Continue the story either way once someone answers (or it times out).
                after(0.4) {
                    if answer.contains("\"allow\"") || answer.isEmpty {
                        self.send("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": commit], "duration_ms": 240])
                    }
                    after(2.4) { self.send("Stop") }
                }
            }
        }
    }
}
