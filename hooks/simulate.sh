#!/bin/bash
# NotchPilot demo driver — writes a set of fake session JSON files into
# ~/.notchpilot/sessions/ in different states so the Swift app can be demoed
# without real Claude Code sessions. Conforms to docs/STATE_SCHEMA.md.
#
# Usage:
#   ./simulate.sh          # write the fake sessions
#   ./simulate.sh --clear  # delete the fake sessions
set -euo pipefail

MODE="${1:-write}"

STATE_DIR="$HOME/.notchpilot/sessions"
mkdir -p "$STATE_DIR"

MODE="$MODE" STATE_DIR="$STATE_DIR" python3 <<'PYEOF'
import os, json, datetime

state_dir = os.environ["STATE_DIR"]
mode = os.environ["MODE"]

# Stable fake session ids so --clear can find them.
SESSIONS = {
    "notchpilot-demo-working": {
        "schemaVersion": 1,
        "project": "web-app",
        "cwd": "/Users/you/Projects/web-app",
        "status": "working",
        "statusDetail": "Edit src/App.tsx",
        "tty": "/dev/ttys003",
        "termSessionId": "w0t0p0:DEMO-WORKING",
        "model": "Opus 4.8",
        "lastEvent": "PreToolUse",
        "started_offset_sec": 300,
        "updated_offset_sec": 4,
    },
    "notchpilot-demo-waiting": {
        "schemaVersion": 1,
        "project": "api",
        "cwd": "/Users/you/Projects/api",
        "status": "waiting",
        "statusDetail": "Claude needs your permission to run: rm -rf build/",
        "tty": "/dev/ttys005",
        "termSessionId": "w0t1p0:DEMO-WAITING",
        "model": "Opus 4.8",
        "lastEvent": "Notification",
        "started_offset_sec": 900,
        "updated_offset_sec": 12,
    },
    "notchpilot-demo-done": {
        "schemaVersion": 1,
        "project": "zen-copilot",
        "cwd": "/Users/you/Projects/zen-copilot",
        "status": "done",
        "statusDetail": "finished",
        "tty": "/dev/ttys007",
        "termSessionId": "w0t2p0:DEMO-DONE",
        "model": "Opus 4.8",
        "lastEvent": "Stop",
        "started_offset_sec": 1800,
        "updated_offset_sec": 30,
    },
    "notchpilot-demo-idle": {
        "schemaVersion": 1,
        "project": "scratch",
        "cwd": "/Users/you/Projects/scratch",
        "status": "idle",
        "statusDetail": None,
        "tty": None,
        "termSessionId": "w0t3p0:DEMO-IDLE",
        "model": None,
        "lastEvent": "SessionStart",
        "started_offset_sec": 60,
        "updated_offset_sec": 60,
    },
}

def path_for(sid):
    return os.path.join(state_dir, sid + ".json")

if mode == "--clear":
    removed = 0
    for sid in SESSIONS:
        try:
            os.remove(path_for(sid))
            removed += 1
        except FileNotFoundError:
            pass
    print(f"[notchpilot] simulate --clear: removed {removed} demo session file(s).")
else:
    now = datetime.datetime.now(datetime.timezone.utc)
    for sid, spec in SESSIONS.items():
        started = now - datetime.timedelta(seconds=spec.pop("started_offset_sec"))
        updated = now - datetime.timedelta(seconds=spec.pop("updated_offset_sec"))
        state = dict(spec)
        state["sessionId"] = sid
        state["startedAt"] = started.isoformat()
        state["updatedAt"] = updated.isoformat()
        p = path_for(sid)
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=2)
            f.write("\n")
        os.replace(tmp, p)
        print(f"[notchpilot] wrote demo session: {sid} ({state['status']})")
    print(f"[notchpilot] {len(SESSIONS)} demo sessions written to {state_dir}")
    print("[notchpilot] run './simulate.sh --clear' to remove them.")
PYEOF
