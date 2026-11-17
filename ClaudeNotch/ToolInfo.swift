import Foundation

enum Tone: Equatable { case normal, wait, done }
enum DetailKind: Equatable { case text, path, mono }

/// How the spark glyph moves: one personality per kind of work.
enum GlyphMode: Equatable { case think, read, search, edit, run, commit, wait, done }

/// One thing Claude is doing right now, as the notch shows it.
struct Step: Equatable {
    var id = UUID()
    /// Claude's id for the tool call this step shows, so results land on the right step.
    var toolUseID: String? = nil
    var verb: String
    var detail: String = ""
    var kind: DetailKind = .text
    var mode: GlyphMode = .think
    var tone: Tone = .normal
    /// A count that rolls up when the step finishes (e.g. 219 lines).
    var count: Int? = nil
    var unit: String = ""
    var countStart: Date? = nil
    /// Plain meta text instead of a count (e.g. a duration).
    var metaText: String? = nil

    static func thinking() -> Step { Step(verb: "Thinking", mode: .think) }
}

/// Turns raw Claude Code tool events into words for the notch.
enum ToolInfo {
    static func describe(tool: String, input: [String: Any], cwd: String) -> Step {
        let s = { (k: String) in (input[k] as? String) ?? "" }
        switch tool {
        case "Read":
            return Step(verb: "Reading", detail: displayPath(s("file_path"), cwd: cwd), kind: .path, mode: .read)
        case "Edit", "MultiEdit":
            return Step(verb: "Editing", detail: displayPath(s("file_path"), cwd: cwd), kind: .path, mode: .edit)
        case "Write":
            return Step(verb: "Writing", detail: displayPath(s("file_path"), cwd: cwd), kind: .path, mode: .edit)
        case "NotebookEdit":
            return Step(verb: "Editing", detail: displayPath(s("notebook_path"), cwd: cwd), kind: .path, mode: .edit)
        case "Bash":
            let cmd = oneLine(s("command"))
            if cmd.hasPrefix("git commit") {
                return Step(verb: "Committing", detail: commitMessage(cmd) ?? cmd, kind: .mono, mode: .commit)
            }
            return Step(verb: "Running", detail: cmd, kind: .mono, mode: .run)
        case "Grep":
            var d = "\"\(s("pattern"))\""
            let p = s("path")
            if !p.isEmpty { d += " in " + displayPath(p, cwd: cwd) }
            return Step(verb: "Searching", detail: d, kind: .mono, mode: .search)
        case "Glob":
            return Step(verb: "Searching", detail: s("pattern"), kind: .mono, mode: .search)
        case "WebFetch":
            return Step(verb: "Fetching", detail: shortURL(s("url")), kind: .text, mode: .read)
        case "WebSearch":
            return Step(verb: "Searching", detail: s("query"), kind: .text, mode: .search)
        case "Task", "Agent":
            return Step(verb: "Delegating", detail: s("description"), kind: .text, mode: .think)
        case "TodoWrite":
            let todos = (input["todos"] as? [[String: Any]]) ?? []
            let now = todos.first { ($0["status"] as? String) == "in_progress" }
            let d = (now?["activeForm"] as? String) ?? (now?["content"] as? String) ?? "Updating the to-do list"
            return Step(verb: "Planning", detail: d, kind: .text, mode: .think)
        default:
            if tool.hasPrefix("mcp__") {
                // mcp__<server>__<tool>
                let parts = tool.components(separatedBy: "__")
                let server = parts.count > 1 ? parts[1] : "MCP"
                let name = parts.count > 2 ? parts[2...].joined(separator: "__").replacingOccurrences(of: "_", with: " ") : ""
                return Step(verb: "Using", detail: name.isEmpty ? server : "\(server) · \(name)", kind: .text, mode: .run)
            }
            return Step(verb: tool, detail: "", kind: .text, mode: .run)
        }
    }

    /// What a finished tool produced: a count to roll up, and a line for "recent steps".
    struct Result { var count: Int?; var unit = ""; var metaText: String?; var past: String }

    static func result(tool: String, input: [String: Any], response: Any?, durationMs: Double?, cwd: String) -> Result {
        let resp = response as? [String: Any]
        let file = { (k: String) -> String in
            let p = (input[k] as? String) ?? ""
            return (p as NSString).lastPathComponent
        }
        switch tool {
        case "Read":
            let n = ((resp?["file"] as? [String: Any])?["numLines"] as? Int)
                ?? lineCount((resp?["file"] as? [String: Any])?["content"] as? String)
            return Result(count: n, unit: "lines", past: "Read \(file("file_path"))" + (n.map { " · \($0) lines" } ?? ""))
        case "Edit", "MultiEdit":
            let (a, r) = patchCounts(resp) ?? (lineCount(input["new_string"] as? String) ?? 0, lineCount(input["old_string"] as? String) ?? 0)
            return Result(count: a, unit: a == 1 ? "addition" : "additions", past: "Edited \(file("file_path")) · +\(a) −\(r)")
        case "Write":
            let n = lineCount(input["content"] as? String) ?? 0
            return Result(count: n, unit: "lines", past: "Wrote \(file("file_path")) · \(n) lines")
        case "Grep", "Glob":
            let n = (resp?["numFiles"] as? Int) ?? (resp?["filenames"] as? [Any])?.count
            let pattern = (input["pattern"] as? String) ?? ""
            let past = tool == "Grep" ? "Searched \"\(pattern)\"" : "Matched \(pattern)"
            return Result(count: n, unit: n == 1 ? "file" : "files", past: past + (n.map { " · \($0) files" } ?? ""))
        case "Bash":
            let cmd = oneLine((input["command"] as? String) ?? "")
            let meta = durationMs.map { formatDuration($0) }
            return Result(count: nil, metaText: meta, past: "Ran \(truncate(cmd, 48))" + (meta.map { " · \($0)" } ?? ""))
        case "WebFetch":
            return Result(count: nil, past: "Fetched \(shortURL((input["url"] as? String) ?? ""))")
        default:
            let step = describe(tool: tool, input: input, cwd: cwd)
            return Result(count: nil, past: step.detail.isEmpty ? "Used \(tool)" : "\(step.verb) \(truncate(step.detail, 48))")
        }
    }

    /// The question row: a short label (amber) plus what's being asked about.
    static func permissionSummary(tool: String, input: [String: Any], cwd: String) -> (label: String, detail: String) {
        switch tool {
        case "Bash": return ("$", oneLine((input["command"] as? String) ?? ""))
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            let p = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            return (tool, displayPath(p, cwd: cwd))
        case "WebFetch": return ("Fetch", shortURL((input["url"] as? String) ?? ""))
        default:
            let d = describe(tool: tool, input: input, cwd: cwd)
            return (tool.hasPrefix("mcp__") ? "Use" : tool, d.detail)
        }
    }

    // MARK: helpers

    static func displayPath(_ p: String, cwd: String) -> String {
        if !cwd.isEmpty, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    static func oneLine(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        return truncate(collapsed, 400)
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func lineCount(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        var n = s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if !s.hasSuffix("\n") { n += 1 }
        return n
    }

    static func patchCounts(_ resp: [String: Any]?) -> (Int, Int)? {
        guard let hunks = resp?["structuredPatch"] as? [[String: Any]], !hunks.isEmpty else { return nil }
        var a = 0, r = 0
        for h in hunks {
            for l in (h["lines"] as? [String]) ?? [] {
                if l.hasPrefix("+") { a += 1 } else if l.hasPrefix("-") { r += 1 }
            }
        }
        return (a, r)
    }

    static func shortURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        let path = u.path == "/" ? "" : u.path
        return host.replacingOccurrences(of: "www.", with: "") + path
    }

    static func commitMessage(_ cmd: String) -> String? {
        // git commit -m "message" …  →  message
        guard let r = cmd.range(of: #"-m\s+(["'])(.*?)\1"#, options: .regularExpression) else { return nil }
        let m = String(cmd[r])
        guard let q = m.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(m[m.index(after: q)..<m.index(before: m.endIndex)])
    }

    static func formatDuration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms))ms" : (ms < 60_000 ? String(format: "%.1fs", ms / 1000) : formatLong(ms / 1000))
    }
}
