import AppKit
import Combine

enum RunStatus: Equatable { case idle, running, permission, waiting, done }

/// A permission question waiting on the notch. `reply` writes the hook's answer.
struct PendingPermission {
    let id = UUID()
    let label: String
    let detail: String
    /// When the notch gives up and hands the question back to the terminal.
    let deadline: Date
    let reply: (String) -> Void
}

/// One Claude Code session (one terminal tab), keyed by Claude's `session_id`.
final class Session {
    let id: String
    var cwd = ""
    var hostPID: pid_t?
    var hostName: String?
    var prompt = ""
    var startedAt: Date?
    var endedAt: Date?
    var status: RunStatus = .idle
    var step = Step.thinking()
    var stepCount = 0
    var history: [HistoryItem] = []
    var lastUpdate = Date()
    var pending: PendingPermission?
    /// A finished step lingers briefly so its result can be read before the next one replaces it.
    var dwellUntil = Date.distantPast
    var queued: Step?
    /// Tools that have started but not finished. While any run, the session never times out.
    var toolsRunning = 0
    /// Folded away after a long silence; the next event resumes the same run.
    var asleep = false
    /// Claude finished by asking you something: stays as "Your turn" until you answer.
    var yourTurn = false

    init(id: String) { self.id = id }
}

struct HistoryItem: Identifiable, Equatable { let id = UUID(); let text: String }

/// Turns Claude Code hook events into what the notch should show.
@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var sessions: [String: Session] = [:]
    private(set) var currentID: String?
    /// After a run finishes we show "Done" for a moment, then fold away.
    private(set) var showDone = false
    var pendingHide = false
    var isHovering: () -> Bool = { false }

    let focus: FocusWatcher
    private var hideWork: DispatchWorkItem?
    private var thinkWork: DispatchWorkItem?

    static let permissionTimeout: TimeInterval = 25

    private var staleTimer: Timer?
    /// A run that hears nothing for this long, with no tool still running
    /// (Claude crashed, terminal closed), folds away. Any later event resumes it.
    static let staleAfter: TimeInterval = 60 * 60
    /// Even a "running" tool gets this long, in case Claude crashed mid-tool.
    static let hardStaleAfter: TimeInterval = 6 * 60 * 60

    init(focus: FocusWatcher) {
        self.focus = focus
        staleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepStale() }
        }
    }

    private func sweepStale() {
        var any = false
        for s in sessions.values where s.pending == nil && s.status != .idle && s.status != .done
            && Date().timeIntervalSince(s.lastUpdate) > (s.toolsRunning == 0 ? Self.staleAfter : Self.hardStaleAfter) {
            s.status = .idle
            s.asleep = !s.yourTurn
            s.yourTurn = false
            any = true
        }
        if let s = current, s.status == .idle { currentID = sessions.values.filter { $0.status != .idle }.max { $0.lastUpdate < $1.lastUpdate }?.id }
        if any { changed() }
    }

    var current: Session? { currentID.flatMap { sessions[$0] } }

    func hostIsFrontmost(_ s: Session) -> Bool { focus.isFrontmost(s.hostPID) }

    private func changed() { revision &+= 1 }

    // MARK: - Events

    func handle(_ e: [String: Any], pid: pid_t?, reply: ((String) -> Void)? = nil) {
        let name = (e["hook_event_name"] as? String) ?? ""
        let sid = (e["session_id"] as? String) ?? "default"
        let s = sessions[sid] ?? {
            let n = Session(id: sid); sessions[sid] = n; return n
        }()
        if let cwd = e["cwd"] as? String { s.cwd = cwd }
        if s.hostPID == nil, let pid, let app = FocusWatcher.hostApp(for: pid) {
            s.hostPID = app.processIdentifier
            s.hostName = app.localizedName
        }
        s.lastUpdate = Date()

        switch name {
        case "UserPromptSubmit":
            begin(s, prompt: (e["prompt"] as? String) ?? "")

        case "PreToolUse":
            wakeOrBegin(s)
            s.toolsRunning += 1
            let tool = (e["tool_name"] as? String) ?? "Tool"
            let input = (e["tool_input"] as? [String: Any]) ?? [:]
            s.stepCount += 1
            if s.status != .permission { s.status = .running }
            var step = ToolInfo.describe(tool: tool, input: input, cwd: s.cwd)
            step.toolUseID = e["tool_use_id"] as? String
            setStep(s, step)

        case "PostToolUse", "PostToolUseFailure":
            s.toolsRunning = max(0, s.toolsRunning - 1)
            if s.asleep { wake(s) }
            guard s.status != .idle && s.status != .done else { break }
            let tool = (e["tool_name"] as? String) ?? "Tool"
            let input = (e["tool_input"] as? [String: Any]) ?? [:]
            var r = ToolInfo.result(tool: tool, input: input, response: e["tool_response"],
                                    durationMs: (e["duration_ms"] as? Double) ?? (e["duration_ms"] as? Int).map(Double.init), cwd: s.cwd)
            if name == "PostToolUseFailure" {
                let what = ToolInfo.describe(tool: tool, input: input, cwd: s.cwd)
                r = ToolInfo.Result(count: nil, metaText: "failed",
                                    past: "\(tool) failed" + (what.detail.isEmpty ? "" : " · " + ToolInfo.truncate(what.detail, 40)))
            }
            s.history.append(HistoryItem(text: r.past))
            if s.history.count > 3 { s.history.removeFirst(s.history.count - 3) }
            if s.status == .waiting || s.status == .permission { s.status = .running }
            // Tools can run in parallel: only roll the count on the step it belongs to.
            let useID = e["tool_use_id"] as? String
            let matches = useID != nil ? useID == s.step.toolUseID : (s.step.toolUseID == nil && s.step.mode != .think)
            if matches { finishStep(s, r) }

        case "PermissionRequest":
            askPermission(s, e, reply: reply)
            return   // askPermission handles `changed()` and the reply

        case "Notification":
            let type = (e["notification_type"] as? String) ?? ""
            let msg = (e["message"] as? String) ?? ""
            guard s.status == .running, s.pending == nil else { break }
            if type == "permission_prompt" || msg.localizedCaseInsensitiveContains("permission") {
                s.status = .waiting
                setStep(s, Step(verb: "Needs you", detail: "Answer the prompt in \(s.hostName ?? "the terminal")", mode: .wait, tone: .wait), force: true)
            } else if type == "idle_prompt" || msg.localizedCaseInsensitiveContains("waiting") {
                s.status = .waiting
                setStep(s, Step(verb: "Waiting", detail: msg, mode: .wait, tone: .wait), force: true)
            }

        case "Stop":
            finish(s, lastMessage: e["last_assistant_message"] as? String)

        case "SessionEnd":
            resolvePending(s, decision: nil)
            sessions[sid] = nil
            if currentID == sid { currentID = nil }
            changed()
            reply?("")
            return

        default: break
        }
        if s.status != .idle { currentID = sid }
        changed()
        reply?("")
    }

    /// A tool event with no prompt in front of it: pick the run back up if it
    /// fell asleep, otherwise start a fresh one.
    private func wakeOrBegin(_ s: Session) {
        if s.asleep { wake(s) }
        else if s.status == .idle || s.status == .done || s.yourTurn { begin(s, prompt: s.prompt) }
    }

    /// Resume a run that folded away after a long silence: same timer, same history.
    private func wake(_ s: Session) {
        s.asleep = false
        s.status = .running
        s.step = .thinking()
        hideWork?.cancel(); showDone = false; pendingHide = false
        currentID = s.id
    }

    private func begin(_ s: Session, prompt: String) {
        resolvePending(s, decision: nil)
        s.asleep = false
        s.yourTurn = false
        s.toolsRunning = 0
        s.prompt = prompt
        s.startedAt = Date()
        s.endedAt = nil
        s.status = .running
        s.stepCount = 0
        s.history = []
        s.dwellUntil = .distantPast
        s.queued = nil
        s.step = .thinking()
        hideWork?.cancel(); showDone = false; pendingHide = false
        currentID = s.id
    }

    /// Show a new step, unless the previous one is still lingering with its result.
    private func setStep(_ s: Session, _ step: Step, force: Bool = false) {
        thinkWork?.cancel()
        if !force && Date() < s.dwellUntil {
            s.queued = step
            let wait = s.dwellUntil.timeIntervalSinceNow
            after(wait) { [weak self, weak s] in
                guard let self, let s, let q = s.queued else { return }
                s.queued = nil
                s.step = q
                self.changed()
            }
        } else {
            s.queued = nil
            s.step = step
        }
    }

    private func finishStep(_ s: Session, _ r: ToolInfo.Result) {
        var st = s.step
        st.count = r.count
        st.unit = r.unit
        st.metaText = r.count == nil ? r.metaText : nil
        st.countStart = Date()
        s.step = st
        // Let the count roll and be read (≈1.2s) before the next step takes over.
        s.dwellUntil = Date().addingTimeInterval(1.2)
        // If Claude goes quiet after the tool, it's thinking about what to do next.
        let stepID = st.id
        thinkWork?.cancel()
        thinkWork = after(1.6) { [weak self, weak s] in
            guard let self, let s, s.status == .running, s.step.id == stepID, s.queued == nil else { return }
            s.step = .thinking()
            self.changed()
        }
    }

    private func finish(_ s: Session, lastMessage: String?) {
        resolvePending(s, decision: nil)
        thinkWork?.cancel()
        s.queued = nil
        s.toolsRunning = 0
        s.asleep = false

        // Claude ended by asking you something: it's waiting on you, not done.
        if let q = lastMessage.flatMap(ToolInfo.trailingQuestion) {
            s.endedAt = Date()
            s.yourTurn = true
            s.status = .waiting
            s.step = Step(verb: "Your turn", detail: q, kind: .text, mode: .wait, tone: .wait)
            currentID = s.id
            hideWork?.cancel(); showDone = false; pendingHide = false
            if hostIsFrontmost(s) { s.status = .idle; s.yourTurn = false }
            return
        }
        s.yourTurn = false
        s.status = .done
        s.endedAt = Date()
        let took = s.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let steps = s.stepCount
        s.step = Step(verb: "Done", detail: steps == 0 ? "Answered" : "\(steps) step\(steps == 1 ? "" : "s")",
                      mode: .done, tone: .done, metaText: formatLong(took))
        currentID = s.id
        showDone = !hostIsFrontmost(s)
        if showDone { scheduleHide() } else { s.status = .idle }
    }

    func scheduleHide() {
        hideWork?.cancel()
        hideWork = after(3.6) { [weak self] in
            guard let self else { return }
            if self.isHovering() { self.pendingHide = true; return }
            self.collapseDone()
        }
    }

    func collapseDone() {
        showDone = false
        pendingHide = false
        if let s = current, s.status == .done { s.status = .idle }
        changed()
    }

    // MARK: - Permission

    private func askPermission(_ s: Session, _ e: [String: Any], reply: ((String) -> Void)?) {
        let reply = reply ?? { _ in }
        // Already looking at the terminal? Let Claude Code ask there, right away.
        if hostIsFrontmost(s) { reply(""); return }
        resolvePending(s, decision: nil)
        if s.status == .idle || s.status == .done { begin(s, prompt: s.prompt) }

        let tool = (e["tool_name"] as? String) ?? "Tool"
        let input = (e["tool_input"] as? [String: Any]) ?? [:]
        let sum = ToolInfo.permissionSummary(tool: tool, input: input, cwd: s.cwd)
        let p = PendingPermission(label: sum.label, detail: sum.detail,
                                  deadline: Date().addingTimeInterval(Self.permissionTimeout), reply: reply)
        s.pending = p
        s.status = .permission
        var st = s.step
        st.mode = .wait; st.tone = .wait
        s.step = st
        currentID = s.id
        changed()

        // Nobody answered: hand back to Claude Code's own prompt.
        let id = p.id
        after(Self.permissionTimeout) { [weak self, weak s] in
            guard let self, let s, s.pending?.id == id else { return }
            self.resolvePending(s, decision: nil)
            s.status = .waiting
            s.step = Step(verb: "Needs you", detail: "Answer the prompt in \(s.hostName ?? "the terminal")", mode: .wait, tone: .wait)
            self.changed()
        }
    }

    /// Answer the question shown in the notch.
    func answer(allow: Bool) {
        guard let s = current, s.pending != nil else { return }
        resolvePending(s, decision: allow)
        s.status = .running
        if allow {
            var st = s.step; st.mode = s.step.mode == .wait ? .run : st.mode; st.tone = .normal
            s.step = st
        } else {
            s.step = Step(verb: "Denied", detail: "Claude will try another way", mode: .think, tone: .wait)
        }
        changed()
    }

    /// nil = no decision (Claude Code shows its own prompt).
    private func resolvePending(_ s: Session, decision: Bool?) {
        guard let p = s.pending else { return }
        s.pending = nil
        guard let allow = decision else { p.reply(""); return }
        var d: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { d["message"] = "The user denied this from the Claude Notch." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
        p.reply(String(data: data, encoding: .utf8) ?? "")
    }

    /// Called when focus changes: if you've switched to the terminal mid-question, let it ask there.
    func focusChanged() {
        for s in sessions.values where s.pending != nil && hostIsFrontmost(s) {
            resolvePending(s, decision: nil)
            s.status = .running
            var st = s.step; st.tone = .normal; s.step = st
        }
        // You've gone back to Claude's terminal, so you've seen its question.
        for s in sessions.values where s.yourTurn && hostIsFrontmost(s) {
            s.yourTurn = false
            s.status = .idle
        }
        if let s = current, s.status == .done, showDone, hostIsFrontmost(s) {
            hideWork?.cancel()
            showDone = false
            s.status = .idle
        }
        changed()
    }

    #if DEBUG
    /// Pretend the current run went silent for an hour.
    func debugSleepCurrent() {
        guard let s = current else { return }
        s.lastUpdate = Date().addingTimeInterval(-Self.hardStaleAfter - 1)
        sweepStale()
    }
    #endif

    func activateHost() {
        guard let pid = current?.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}
