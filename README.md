# Claude Notch

A tiny macOS menu-bar app that turns the MacBook notch into a live activity for
[Claude Code](https://code.claude.com). While Claude works in a terminal you're not
looking at, the notch shows what it's doing. Hover to peek, click to open, and answer
permission prompts (Allow / Deny) without switching back.

Native port of the web prototype in `Crafts/crafts/claude-notch`.

## States

| State | When | What you see |
|---|---|---|
| **Idle** | Nothing running, or you're already looking at Claude's terminal | Hidden in the hardware |
| **Compact** | Claude is working elsewhere | Menu-bar height. Left wing: spark + elapsed time. Right wing: the current verb. Width hugs the content, symmetric around the camera |
| **Peek** | Hover ~110ms | One live line: verb, detail (paths middle-truncated, keeping the filename; long commands glide once), rolling count |
| **Open** | Click | Prompt, full current step, progress, last 3 steps, "Open Terminal" |
| **Question** | Claude needs permission | One row: the command + Deny / Allow |
| **Your turn** | Claude's reply ends with a question | Amber "Your turn" + the question. Stays until you answer or go back to Claude's terminal |
| **Done** | Claude finishes the prompt | A check draws in, then it folds away after ~3.6s |

The notch only shows while the app Claude runs in (Terminal, iTerm, Ghostty, VS Code,
Claude.app…) is **not** frontmost. It finds that app by walking up the process tree
from the hook, and listens for app-activation and Space changes.

## Install

Needs Xcode 16+ and macOS 14+.

```bash
~/Documents/claude-notch-app/scripts/install.sh
```

This builds a Release copy, puts it in `/Applications`, and opens it. The first launch
from `/Applications` turns on **Start at Login** (System Settings → General → Login Items;
toggle it from the app's menu). Run the script again after pulling changes.

For development, open `ClaudeNotch.xcodeproj` and press ⌘R. Debug builds never register
as a login item, and have extra test commands on the socket that Release builds leave out.

There's no menu-bar icon. To open the app's menu, either **right-click the notch** while
it's showing, or **open Claude Notch again** (Spotlight, Launchpad or `/Applications`)
while it's running; the menu appears just under the notch. It has **Play Demo Run**
(every state, no Claude Code needed), **Copy Hooks Settings JSON**, **Start at Login**
and **Quit**.

## Hook setup

Claude Code runs "hooks" (shell commands) at points in its lifecycle and pipes a JSON
description of the event to them. The hook script forwards that JSON to the app over a
Unix socket at `~/Library/Application Support/ClaudeNotch/notch.sock`.

The script's source is `ClaudeNotch/Resources/notch-hook.sh`. On every launch the app
copies it to `~/Library/Application Support/ClaudeNotch/notch-hook.sh`, and Claude Code's
settings point there. So moving or deleting this repo never breaks Claude Code; the
hooks just do nothing until the app runs again.

```
Claude Code ──(hook JSON on stdin)──▶ notch-hook.sh ──curl --unix-socket──▶ Claude Notch app
                                            ◀──── Allow / Deny (PermissionRequest only) ────
```

Add this to `~/.claude/settings.json` (merge it into an existing `"hooks"` block if you
already have one):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" UserPromptSubmit", "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" PreToolUse", "timeout": 5 } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" PostToolUse", "timeout": 5 } ] }
    ],
    "PostToolUseFailure": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" PostToolUseFailure", "timeout": 5 } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" PermissionRequest", "timeout": 40 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" Notification", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" Stop", "timeout": 5 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/ClaudeNotch/notch-hook.sh\" SessionEnd", "timeout": 5 } ] }
    ]
  }
}
```

Hooks are read when a session starts, so restart any running `claude` sessions after
adding them. To remove the integration, delete these entries.

To try it without touching your global settings, save the block to a file and pass it to
one session: `claude --settings /path/to/notch-hooks.json`.

### What each hook does

| Hook | Notch |
|---|---|
| `UserPromptSubmit` | Starts a run: timer, prompt, spark "thinking" |
| `PreToolUse` | The verb: Read → **Reading** + path, Bash → **Running** + command (`git commit` → **Committing** + message), Edit → **Editing**, Write → **Writing**, Grep/Glob → **Searching**, WebFetch → **Fetching**, Task → **Delegating**, TodoWrite → **Planning** + the current to-do |
| `PostToolUse` | The result rolls up (219 lines, 42 additions, 6 files, 1.8s) and joins "recent steps" |
| `PostToolUseFailure` | A failed tool joins "recent steps" as failed |
| `PermissionRequest` | The question row. Waits for Allow / Deny |
| `Notification` | Amber "Needs you" / "Waiting" |
| `Stop` | Check mark, then folds away; or "Your turn" if Claude ended on a question |
| `SessionEnd` | Forgets the session |

### Why `PermissionRequest` and not `PreToolUse` for Allow / Deny

`PreToolUse` fires before *every* tool call, including the ones Claude Code would run
without asking. Waiting there would stall every file read until you clicked something.
`PermissionRequest` fires only when Claude Code is about to show you a permission
prompt, so the notch asks exactly when the terminal would.

The fallback is always Claude Code's own prompt:
- If the app isn't running, the hook exits instantly.
- If you're already looking at Claude's terminal, the app replies "no decision" at once.
- If nobody answers in 25 seconds, or you switch to the terminal while it's asking, the
  app replies "no decision" and Claude Code prompts in the terminal as usual.

While the notch is asking, the terminal shows nothing. A thin amber line under the
question drains over those 25 seconds, so you can see when it will hand back.

### How long it stays up

The notch stays for the whole prompt: from when you send it until Claude finishes (or
asks you something). Long-running commands are fine; a run only folds away after an hour
with no events and no tool running (6 hours if a tool never reported back, e.g. Claude
crashed). Any later event picks the same run back up, timer and history included.

### Security

The socket is a file with permissions `0600` in a `0700` folder, and the app checks the
peer's user ID, so only processes running as you can talk to it. It deliberately isn't a
localhost port: any web page in your browser can reach `localhost`, and could then
press "Allow" for you.

## How the motion works (if you're curious)

- **Springs, not durations.** The shape's width, height and corner radius each follow a
  damped spring (`Spring.swift`). Every frame: `force = −k·(value − target) − c·velocity`.
  Because velocity carries over, changing state mid-animation bends the motion instead
  of restarting it.
- **Opening** uses `k=420, c=32` (damping ratio ζ ≈ 0.78, a small bounce), with height
  on a softer spring so it trails the width by a beat. **Closing** uses `k=680, c=52`
  (ζ ≈ 1, critically damped: the fastest settle with no overshoot).
- **The shape** (`NotchShape.swift`) is redrawn from those numbers each frame: concave
  shoulders where it meets the bezel, straight sides, round bottom corners. Drawing it
  fresh keeps the corners crisp, where scaling a fixed shape would squash them.
- **Text** streams in letter by letter (rise 4pt, un-blur, fade over 340ms). The
  rolling counter changes at most ~9 times a second, so you can read it, and each digit
  wheel rolls forward over ~300ms.
- **Reduce Motion** (System Settings → Accessibility → Display) swaps all of it for
  crossfades and a gently pulsing spark.

## Files

```
ClaudeNotch/
  ClaudeNotchApp.swift   app entry, menu-bar item, hook-script install, login item
  NotchPanel.swift       the borderless always-on-top window
  NotchMetrics.swift     reads the notch size from the screen
  NotchController.swift  states, springs, hover / click / pin
  NotchModel.swift       hook events → what to show; permission round-trip
  ToolInfo.swift         tool name + input → verb, detail, result count
  SocketServer.swift     HTTP over a Unix socket
  FocusWatcher.swift     frontmost app, process-tree lookup
  NotchView.swift        SwiftUI: wings, peek row, open panel, question row
  SparkGlyph.swift       the 8-ray spark and its per-activity motion
  TextViews.swift        streamed text, path truncation, glide, rolling digits
  DemoRun.swift          scripted run for the menu's "Play Demo Run"
  Resources/notch-hook.sh  the Claude Code hook (installed to Application Support)
scripts/install.sh       Release build → /Applications
```

## Known limits (v1)

- Hooks don't stream token counts, so the counter rolls up when a step *finishes*
  rather than climbing live, and progress is a travelling glow (the total number of
  steps isn't known in advance).
- Several sessions at once: the notch follows whichever one changed most recently.
- Inside `tmux` / `screen` the process tree doesn't lead back to a terminal app, so the
  notch can't tell when you're looking at it and shows anyway.
