#!/bin/bash
# NotchPilot installer — idempotently registers notchpilot-hook.sh in
# ~/.claude/settings.json for all relevant Claude Code events, PRESERVING every
# existing hook (including the user's ~/.claude/notify.sh Notification hook).
#
# Uses python3 to load/modify/write settings.json (never a naive text edit).
# Backs up settings.json first.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
# Derive the hook path from this script's own location so it works for anyone
# who clones the repo to an arbitrary path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/notchpilot-hook.sh"
STATE_DIR="$HOME/.notchpilot/sessions"

mkdir -p "$STATE_DIR"
echo "[notchpilot] ensured state dir: $STATE_DIR"

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$HOME/.claude"
  echo '{}' > "$SETTINGS"
  echo "[notchpilot] created empty settings.json"
fi

BACKUP="$SETTINGS.bak.notchpilot-$(date +%s)"
cp "$SETTINGS" "$BACKUP"
echo "[notchpilot] backed up settings.json -> $BACKUP"

SETTINGS="$SETTINGS" HOOK_PATH="$HOOK_PATH" python3 <<'PYEOF'
import os, json, sys

settings_path = os.environ["SETTINGS"]
hook_path = os.environ["HOOK_PATH"]

events = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "Notification", "Stop", "SubagentStop", "SessionEnd",
]

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("[notchpilot] ERROR: 'hooks' is not an object; aborting.", file=sys.stderr)
    sys.exit(1)

added = []
skipped = []

for event in events:
    arr = hooks.setdefault(event, [])
    if not isinstance(arr, list):
        print(f"[notchpilot] WARNING: hooks.{event} not a list; skipping.", file=sys.stderr)
        continue

    # Does a notchpilot entry already exist anywhere under this event?
    def is_notchpilot(cmd):
        return isinstance(cmd, str) and "notchpilot-hook.sh" in cmd

    already = any(
        isinstance(group, dict)
        and any(is_notchpilot(h.get("command")) for h in group.get("hooks", []) if isinstance(h, dict))
        for group in arr
    )
    if already:
        skipped.append(event)
        continue

    # Find an existing matcher "" group to append to (so we don't clobber
    # e.g. the user's notify.sh Notification group).
    target = None
    for group in arr:
        if isinstance(group, dict) and group.get("matcher", "") == "":
            target = group
            break

    entry = {"type": "command", "command": hook_path}
    if target is not None:
        target.setdefault("hooks", []).append(entry)
    else:
        arr.append({"matcher": "", "hooks": [entry]})
    added.append(event)

with open(settings_path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(settings_path + ".tmp", settings_path)

print(f"[notchpilot] registered hook: {hook_path}")
print(f"[notchpilot] events ADDED   : {added if added else 'none'}")
print(f"[notchpilot] events SKIPPED (already present): {skipped if skipped else 'none'}")
print("[notchpilot] existing hooks (e.g. notify.sh) preserved.")
PYEOF

echo "[notchpilot] install complete."
