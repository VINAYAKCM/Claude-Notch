#!/bin/sh
# Claude Notch hook.
#
# Claude Code runs this for each hook event and pipes the event's JSON to stdin.
# We forward it to the Claude Notch app over a Unix socket that only your user
# can open. If the app isn't running, we exit at once and Claude carries on.
#
# Usage (from Claude Code settings):  notch-hook.sh <EventName>
#
# PermissionRequest is the one event that waits: the app answers Allow or Deny
# from the notch, and we print that decision for Claude Code. If nobody answers
# in time, we print nothing and Claude Code shows its own prompt as usual.

SOCK="${CLAUDE_NOTCH_SOCKET:-$HOME/Library/Application Support/ClaudeNotch/notch.sock}"
EVENT="${1:-event}"

# No app, no wait.
[ -S "$SOCK" ] || { cat >/dev/null; exit 0; }

if [ "$EVENT" = "PermissionRequest" ]; then
  # The app gives up after ~25s; curl allows a little longer so the app's
  # "no decision" reply always lands first.
  curl -s --max-time 30 --unix-socket "$SOCK" \
    -H "Expect:" -H "Content-Type: application/json" -H "X-Claude-PID: $PPID" \
    --data-binary @- "http://notch/permission" 2>/dev/null
  exit 0
fi

curl -s --max-time 2 -o /dev/null --unix-socket "$SOCK" \
  -H "Expect:" -H "Content-Type: application/json" -H "X-Claude-PID: $PPID" \
  --data-binary @- "http://notch/event" 2>/dev/null
exit 0
