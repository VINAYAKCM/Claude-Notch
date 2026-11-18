# Claude Notch

Your MacBook's notch, but it tells you what Claude is up to.

You ask Claude Code to do something, then you wander off to Figma or Slack or wherever.
Normally you'd keep flipping back to check on it. With Claude Notch, the notch quietly
grows a little and shows you what's happening: what it's reading, what it's running,
how long it's been going. If Claude needs your permission, you can tap **Allow** or
**Deny** right there, no tab-switching.

When you go back to Claude, it gets out of your way and hides again.

- Works with **Claude Code** wherever you run it: Terminal, iTerm, Ghostty, VS Code,
  or the Code tab in the Claude desktop app.
- Doesn't work with regular Claude chats. It runs off Claude Code's hooks, and plain chats
  don't have any.
- Everything stays on your Mac. No network, no accounts, no analytics.

## What it looks like

| State | When | What you see |
|---|---|---|
| **Hidden** | Nothing's running, or you're already looking at Claude | Just your normal notch |
| **Compact** | Claude is working and you're somewhere else | A slim strip the height of the menu bar. Spark and timer on the left, what it's doing on the right |
| **Peek** | Hover over it | One live line: the action, the file or command, a rolling count |
| **Open** | Click it | Your prompt, the current step, progress and the last few steps |
| **Question** | Claude needs permission | The command plus **Deny** / **Allow** buttons |
| **Your turn** | Claude ended its reply with a question | Amber "Your turn" until you go answer |
| **Done** | Claude's finished | A little check mark, then it folds away |

Want to see it without running anything? Use **Play Demo Run** from the menu (see below).

## Getting it running

You'll need a Mac with a notch, macOS 14 or later, and Xcode 16 or later. There's no
download yet, so you build it yourself. It takes about a minute.

```bash
git clone https://github.com/VINAYAKCM/Claude-Notch.git
cd Claude-Notch
./scripts/install.sh
```

That builds the app, copies it to `/Applications` and opens it. It also turns on
**Start at Login** the first time, so it's always around. To pick up changes later,
pull and run the script again.

No notch? It should fall back to a small pill at the top of the screen, but that part hasn't been tested on a real Mac yet.

### Hook it up to Claude Code

Claude Code can run little scripts ("hooks") whenever something happens, like a tool
starting or a reply finishing. Claude Notch ships with a hook script and copies it to
`~/Library/Application Support/ClaudeNotch/` each time it launches. Your job is to tell
Claude Code to use it.

Add this to `~/.claude/settings.json`. If you already have a `"hooks"` section, merge it
in. You can also copy this exact block from the app's menu (**Copy Hooks Settings JSON**).

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

Restart any Claude Code sessions you have open, and you're set.

Not ready to commit? Save that block to a file and try it in one session only:
`claude --settings /path/to/notch-hooks.json`.

To get rid of it, delete those entries and quit the app. If the app isn't running, the
hook just does nothing, so Claude Code never breaks or slows down because of it.

### Where's the menu?

There's no menu bar icon, on purpose. Nobody needs more stuff up there. To get to the
menu:

- **Right-click the notch** while it's showing, or
- **Open Claude Notch again** (Spotlight, Launchpad, `/Applications`) while it's already
  running. The menu pops up right under the notch.

From the menu you can play the demo, copy the hooks JSON, toggle Start at Login, or quit.

## A few things worth knowing

**Allow / Deny always has a fallback.** If you don't answer within 25 seconds (a thin
amber line counts it down), or you switch back to Claude while it's asking, the notch
steps aside and Claude Code asks you the normal way. If you're already looking at
Claude, the notch doesn't ask at all.

**It sticks around for the whole run.** From when you send a prompt until Claude
finishes or asks you something, long commands included. It only gives up on a run after
an hour of total silence.

**It's private.** The app and the hook talk over a local socket file that only your user
account can open. There's deliberately no `localhost` port, since any website in your
browser can reach those.

## How it works (the short version)

```
Claude Code ──(event JSON)──▶ notch-hook.sh ──(local socket)──▶ Claude Notch
                                    ◀────────── Allow / Deny ──────────
```

Each hook passes Claude Code's event to the app. The app turns it into something
readable: `Read` becomes **Reading** plus the file name, `Bash` becomes **Running** plus
the command, `git commit` becomes **Committing** plus the message, and so on. To know when
to hide, it works out which app Claude is running in by walking up the process tree, then
watches which app you're using.

## The motion bits (for the curious)

Most of the fun is in how it moves.

- **Springs instead of fixed timings.** Width, height and corner radius each follow their
  own little physics spring. Interrupt it halfway, by hovering then leaving quickly, and it
  bends smoothly into the new direction instead of restarting.
- **Opening has a tiny bounce, closing has none.** It opens with a bit of give, and
  closes snappy and flat.
- **The shape is redrawn every frame,** so the curved shoulders where it meets the bezel
  stay crisp at every size instead of getting squished.
- **Text types itself in** letter by letter. Long paths get trimmed in the middle so you
  still see the file name. The counter rolls like an odometer, but slowly enough to
  read.
- **Reduce Motion** (System Settings → Accessibility → Display) is respected: everything
  turns into gentle crossfades.

## What's in here

```
ClaudeNotch/
  ClaudeNotchApp.swift     app setup, the menu, hook install, start at login
  NotchPanel.swift         the floating window that sits over the notch
  NotchMetrics.swift       measures the notch on your screen
  NotchController.swift    states, springs, hover and click
  NotchModel.swift         turns hook events into what you see; Allow / Deny
  ToolInfo.swift           tool name → "Reading", "Running", counts
  SocketServer.swift       the tiny local server
  FocusWatcher.swift       which app you're looking at
  NotchView.swift          the SwiftUI views
  SparkGlyph.swift         the animated spark
  TextViews.swift          typing text, path trimming, rolling numbers
  DemoRun.swift            the fake run behind "Play Demo Run"
  Resources/notch-hook.sh  the hook script
scripts/install.sh         build and install
```

## Not perfect yet

- Claude Code doesn't share live token counts with hooks, so numbers update when a step
  finishes rather than ticking up live.
- If you have several Claude sessions going, the notch follows whichever one did
  something most recently.
- Inside `tmux` or `screen` it can't tell which window Claude lives in, so it shows even
  when you're looking right at it.
- Only tested on one MacBook so far. If something looks off on yours, open an issue.

## Credits

Built for fun by [Vinayak](https://github.com/VINAYAKCM), with a lot of help from
Claude. Not affiliated with Anthropic.
