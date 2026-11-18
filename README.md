# Claude Notch

I made my MacBook's notch tell me what Claude is up to.

Here's the thing that kept bugging me. I'd give Claude Code a task, switch over to
something else, and then keep flipping back every minute to check on it. Is it done? Is it
stuck? Is it waiting on me?

So now the notch does the checking for me.

## What it does

While Claude is working and I'm off in another app, the notch grows a little and shows
what's going on: reading a file, running a command, how long it's been at it. When I go
back to Claude, it tucks itself away again.

- **Hover** over it and it peeks open with a bit more detail.
- **Click** it and it opens up to show my prompt, the current step, and the last few
  things Claude did.
- **When Claude needs permission** to do something, **Deny** and **Allow** buttons show up
  right in the notch, so I don't have to switch back just to click yes.
- **When Claude asks me a question**, it turns amber and says **"Your turn"**.
- **When it's done**, a little check mark draws in and it folds back into the notch.

## The fun part: how it moves

I cared a lot about this one feeling right, not just working.

- It moves on **springs** rather than fixed timings. If you hover and leave halfway
  through, it doesn't restart. It just bends toward wherever it's going next.
- **Opening has a tiny bounce. Closing has none.** It feels like it's popping out of the
  notch, then gets out of your way quickly.
- The shape is **redrawn every frame**, so the little curved shoulders where it meets the
  screen edge stay crisp at every size.
- Text **types itself in** one letter at a time, and the numbers roll like an odometer,
  slowly enough to actually read.
- If you've turned on **Reduce Motion** on your Mac, all of that becomes gentle fades.

## How it came together

It started as a web prototype, where I worked out the states and the motion. Then I
rebuilt it as a real Mac app in Swift and SwiftUI.

The app hooks into Claude Code, so it reacts to what Claude is actually doing instead of
guessing. Everything stays on my Mac: no internet, no accounts, nothing tracked.

I built it with a lot of help from Claude, which felt fitting.

## Still on the list

- Showing more than one Claude session at a time.
- Live-updating numbers. Right now they update when each step finishes.

---

Made for fun by [Vinayak](https://github.com/VINAYAKCM). Not affiliated with Anthropic.
