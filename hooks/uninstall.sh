#!/bin/bash
# NotchPilot uninstaller — removes ONLY the notchpilot-hook.sh entries from
# ~/.claude/settings.json, preserving everything else (idempotent).
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS" ]; then
  echo "[notchpilot] no settings.json found; nothing to do."
  exit 0
fi

BACKUP="$SETTINGS.bak.notchpilot-$(date +%s)"
cp "$SETTINGS" "$BACKUP"
echo "[notchpilot] backed up settings.json -> $BACKUP"

SETTINGS="$SETTINGS" python3 <<'PYEOF'
import os, json, sys

settings_path = os.environ["SETTINGS"]

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    print("[notchpilot] no hooks object; nothing to remove.")
    sys.exit(0)

def is_notchpilot(cmd):
    return isinstance(cmd, str) and "notchpilot-hook.sh" in cmd

removed = 0
for event, arr in list(hooks.items()):
    if not isinstance(arr, list):
        continue
    new_arr = []
    for group in arr:
        if not isinstance(group, dict):
            new_arr.append(group)
            continue
        ghooks = group.get("hooks", [])
        kept = [h for h in ghooks if not (isinstance(h, dict) and is_notchpilot(h.get("command")))]
        removed += len(ghooks) - len(kept)
        group["hooks"] = kept
        # Drop the group entirely only if it became empty (don't leave dangling).
        if kept:
            new_arr.append(group)
    if new_arr:
        hooks[event] = new_arr
    else:
        # No groups left for this event -> remove the event key.
        del hooks[event]

# Clean up empty hooks object.
if not hooks:
    settings.pop("hooks", None)

with open(settings_path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(settings_path + ".tmp", settings_path)

print(f"[notchpilot] removed {removed} notchpilot hook entr{'y' if removed == 1 else 'ies'}.")
print("[notchpilot] all other hooks preserved.")
PYEOF

echo "[notchpilot] uninstall complete."
