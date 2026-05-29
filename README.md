# Zen-Copilot

A Claude Code session board that lives in your MacBook notch — inspired by *Vibe Island*.

When you run several Claude Code agents at once across terminal tabs, Zen-Copilot
sits in the notch and shows, at a glance, what every session is doing — and lets
you jump to, reply to, or answer a permission prompt for any of them without
hunting for the right tab.

## What it does

- **Notch status board for all your Claude Code sessions** — see each one as
  working, waiting (needs you), done, idle, or errored, with at-a-glance colors.
- **Click to focus** — click a session and Zen-Copilot brings its terminal tab to
  the front. Works with Apple Terminal and iTerm2, even when the tab is on
  another Space.
- **Act from the notch** — reply to a session, or answer a permission prompt
  (Approve / Allow Once / Deny) right from the notch, without switching apps.
- **A pixel-pet mascot** — the Claude Code character lives in the notch, reacts to
  your sessions, and idles, sleeps, and strolls when things are quiet.
- **Wellness reminders** — gentle nudges to stretch, hydrate, look away, and check
  your posture, acted out by the pet.

## How it works

```
Claude Code hooks  ──►  ~/.notchpilot/sessions/*.json  ──►  SwiftUI app (notch UI)
   (writer)                  (state contract)                     (reader)
```

Hooks fire on every Claude Code lifecycle event and write a small per-session JSON
file; the app watches that folder and renders the live board. The full contract is
in [`docs/STATE_SCHEMA.md`](docs/STATE_SCHEMA.md).

Status colors: ⚪ idle · 🟢 working · 🟠 waiting for you · 🔵 done · 🔴 error.

## Requirements

- macOS 14 or later
- Swift (Swift 6 toolchain / recent Xcode command line tools)
- Apple Terminal or iTerm2 (click-to-focus matches the terminal's AppleScript `tty`)
- Grants **Accessibility** + **Automation** permissions so it can focus tabs and
  send replies on your behalf
- Python 3 (preinstalled on macOS) for the hook script

## Build & run

```bash
# 1. build the release binary and bundle it into an app
swift build -c release
./scripts/make-app.sh          # → dist/Zen-Copilot.app

# 2. launch it
open dist/Zen-Copilot.app

# 3. wire the hooks into Claude Code
./hooks/install.sh

# 4. (optional) seed fake sessions to see the UI without real Claude runs
./hooks/simulate.sh
```

`./hooks/uninstall.sh` removes the Claude Code hook entries, and
`./hooks/simulate.sh --clear` removes the fake demo sessions.

> The first time you click a session, macOS will prompt for **Accessibility** and
> **Automation** permissions — grant both so click-to-focus and replies work. For
> a signature whose grants persist across rebuilds, see the signing note in
> `scripts/make-app.sh`.

## Credits

- Built on [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit).
- Inspired by *Vibe Island*.
- The pixel mascot evokes the Claude Code welcome character.

## License

MIT — see [`LICENSE`](LICENSE).
