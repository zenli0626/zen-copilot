#!/bin/bash
# NotchPilot universal Claude Code hook.
# Reads a hook JSON object on stdin, branches on hook_event_name, and writes a
# per-session state file at ~/.notchpilot/sessions/<session_id>.json conforming
# to docs/STATE_SCHEMA.md.
#
# HARD RULE: this script must NEVER block or break Claude Code. Any failure is
# swallowed and we exit 0 unconditionally.

# Capture the controlling tty for click-to-focus. The hook is often spawned in a
# process detached from the terminal (its own $$ reports "??"), so we walk UP the
# process tree and take the first ancestor that has a real tty — that ancestor is
# the `claude` process, whose tty matches the Apple Terminal tab. Falls back to
# null if nothing in the chain has a tty.
find_tty() {
  local pid="$$" tty ppid hops=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$hops" -lt 12 ]; do
    tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$tty" ] && [ "$tty" != "??" ] && [ "$tty" != "-" ]; then
      printf '%s' "$tty"
      return 0
    fi
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ "$ppid" = "$pid" ] && break
    pid="$ppid"
    hops=$((hops + 1))
  done
  return 0
}
TTY_RAW="$(find_tty)"

# Read all of stdin into a variable so python gets it via env (robust to pipes).
STDIN_JSON="$(cat 2>/dev/null)"

NOTCHPILOT_STDIN="$STDIN_JSON" \
NOTCHPILOT_TTY_RAW="$TTY_RAW" \
NOTCHPILOT_TERM_SESSION_ID="${TERM_SESSION_ID:-}" \
NOTCHPILOT_TERM_PROGRAM="${TERM_PROGRAM:-}" \
python3 <<'PYEOF' 2>/dev/null
import os, sys, json, datetime

def now_iso():
    # ISO8601 UTC, e.g. 2026-05-28T17:46:12.123456+00:00
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

try:
    raw = os.environ.get("NOTCHPILOT_STDIN", "") or ""
    try:
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}

    event = data.get("hook_event_name") or ""
    session_id = data.get("session_id") or ""
    cwd = data.get("cwd") or ""

    # No session id => nothing we can key on. Bail cleanly.
    if not session_id:
        sys.exit(0)

    home = os.path.expanduser("~")
    state_dir = os.path.join(home, ".notchpilot", "sessions")
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, session_id + ".json")

    # SessionEnd => delete file and stop.
    if event == "SessionEnd":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        except Exception:
            pass
        sys.exit(0)

    # Read-merge-write: load existing state so we preserve startedAt/tty/etc.
    state = {}
    try:
        with open(path, "r") as f:
            state = json.load(f)
            if not isinstance(state, dict):
                state = {}
    except Exception:
        state = {}

    # Defaults / invariants.
    state.setdefault("schemaVersion", 1)
    state["schemaVersion"] = 1
    state["sessionId"] = session_id
    if cwd:
        state["cwd"] = cwd
        state.setdefault("project", os.path.basename(cwd.rstrip("/")) or cwd)
    state.setdefault("project", state.get("project"))
    state.setdefault("status", "idle")
    state.setdefault("statusDetail", None)
    state.setdefault("needsPermission", False)
    state.setdefault("tty", None)
    state.setdefault("termSessionId", None)
    state.setdefault("model", None)
    state.setdefault("startedAt", None)
    state.setdefault("turnStartedAt", None)
    state.setdefault("contextTokens", None)

    # --- Subagent / parent-child linkage (DEFENSIVE, optional) -----------------
    # The public Claude Code hook schema does NOT currently document a reliable
    # parent->child linkage for Task-tool subagents. We capture any plausible
    # field IF present so that a future schema (or a payload we haven't seen)
    # is recorded rather than lost. These are read with .get(...) and only stored
    # when non-empty; absence is harmless. They never affect status mapping.
    for src_key, dst_key in (
        ("parent_session_id", "parentSessionId"),
        ("parent_id", "parentSessionId"),
        ("agent_id", "agentId"),
        ("subagent_id", "agentId"),
        ("agent_type", "agentType"),
        ("subagent_type", "agentType"),
    ):
        v = data.get(src_key)
        if isinstance(v, str) and v and not state.get(dst_key):
            state[dst_key] = v

    # --- Transcript path (DEFENSIVE, optional) ---------------------------------
    # Claude Code's hook stdin includes `transcript_path` — the session's
    # conversation .jsonl. We store it so the UI can summarize Claude's last
    # message ("what you're replying to") without opening the terminal. Stored
    # ONLY when present + non-empty; refreshed when it changes. Never affects
    # status. Absence is harmless.
    tp_path = data.get("transcript_path")
    if isinstance(tp_path, str) and tp_path:
        state["transcriptPath"] = tp_path

    # --- Context-window usage (DEFENSIVE, optional) ----------------------------
    # Compute how full the model's context window is by reading the session's
    # transcript .jsonl and finding the MOST RECENT assistant turn's `usage`. The
    # prompt/context size for a turn ≈ input_tokens + cache_read_input_tokens +
    # cache_creation_input_tokens. PERFORMANCE: we only read the TAIL of the file
    # (last ~256KB) and scan lines from the END for the first object carrying a
    # `usage` with token fields, so this stays fast + non-blocking even on huge
    # transcripts. Any failure is swallowed — we leave the prior value intact and
    # never break or slow the hook.
    def compute_context_tokens(path):
        try:
            tp = os.path.expanduser(path)
            size = os.path.getsize(tp)
            tail = 256 * 1024
            with open(tp, "rb") as f:
                if size > tail:
                    f.seek(size - tail)
                    f.readline()  # discard the partial first line after the seek
                chunk = f.read()
            text = chunk.decode("utf-8", "replace")
            for line in reversed(text.splitlines()):
                line = line.strip()
                if not line or "usage" not in line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                msg = obj.get("message")
                usage = None
                if isinstance(msg, dict) and isinstance(msg.get("usage"), dict):
                    usage = msg["usage"]
                elif isinstance(obj.get("usage"), dict):
                    usage = obj["usage"]
                if not isinstance(usage, dict):
                    continue
                total = 0
                for k in ("input_tokens", "cache_read_input_tokens",
                          "cache_creation_input_tokens"):
                    v = usage.get(k)
                    if isinstance(v, (int, float)):
                        total += int(v)
                if total > 0:
                    return total
        except Exception:
            return None
        return None

    tp_for_ctx = state.get("transcriptPath")
    if isinstance(tp_for_ctx, str) and tp_for_ctx:
        ctx = compute_context_tokens(tp_for_ctx)
        if isinstance(ctx, int) and ctx > 0:
            state["contextTokens"] = ctx

    # Remember the status BEFORE this event so we can detect the start of a turn.
    prev_status = state.get("status")

    # Refresh terminal identity to the CURRENT tab on EVERY event. A session can
    # move tabs (e.g. `claude --resume` in a new window/tab), which gives it a new
    # tty / TERM_SESSION_ID / TERM_PROGRAM — so click-to-focus must track where it
    # is *now*, not where it started. Only overwrite when we have a valid current
    # value; never clobber a good value with an empty/?? one.
    state.setdefault("tty", None)
    tty_raw = (os.environ.get("NOTCHPILOT_TTY_RAW") or "").strip()
    if tty_raw and tty_raw not in ("??", "-"):
        state["tty"] = "/dev/" + tty_raw

    state.setdefault("termSessionId", None)
    tsid = os.environ.get("NOTCHPILOT_TERM_SESSION_ID") or ""
    if tsid:
        state["termSessionId"] = tsid

    state.setdefault("termProgram", None)
    tp = os.environ.get("NOTCHPILOT_TERM_PROGRAM") or ""
    if tp:
        state["termProgram"] = tp

    def short_target(tool_name, tool_input):
        """Build a short human label for a tool invocation."""
        if not isinstance(tool_input, dict):
            return ""
        # Common file-ish fields.
        for k in ("file_path", "path", "notebook_path"):
            v = tool_input.get(k)
            if isinstance(v, str) and v:
                return os.path.basename(v.rstrip("/")) or v
        # Bash command.
        cmd = tool_input.get("command")
        if isinstance(cmd, str) and cmd:
            c = " ".join(cmd.split())
            return (c[:40] + "…") if len(c) > 40 else c
        # Search-ish.
        for k in ("pattern", "query", "url", "prompt"):
            v = tool_input.get(k)
            if isinstance(v, str) and v:
                return (v[:40] + "…") if len(v) > 40 else v
        return ""

    # Event -> status mapping (per STATE_SCHEMA.md). status only changes here.
    if event == "SessionStart":
        state["status"] = "idle"
        state["needsPermission"] = False
        # Capture startedAt once; tty/termSessionId are handled by the backfill above.
        if not state.get("startedAt"):
            state["startedAt"] = now_iso()
        # model: best-effort from stdin, else leave null.
        if not state.get("model"):
            m = data.get("model")
            if isinstance(m, dict):
                m = m.get("display_name") or m.get("id")
            state["model"] = m if isinstance(m, str) and m else None

    elif event == "UserPromptSubmit":
        state["status"] = "working"
        state["statusDetail"] = "thinking…"
        state["needsPermission"] = False

    elif event == "PreToolUse":
        state["status"] = "working"
        state["needsPermission"] = False
        tool_name = data.get("tool_name") or "tool"
        tgt = short_target(tool_name, data.get("tool_input"))
        state["statusDetail"] = (tool_name + " " + tgt).strip() if tgt else tool_name

    elif event == "PostToolUse":
        state["status"] = "working"
        state["needsPermission"] = False
        tool_name = data.get("tool_name") or "tool"
        state["statusDetail"] = "ran " + tool_name

    elif event == "Notification":
        state["status"] = "waiting"
        msg = data.get("message") or ""
        # A `.waiting` session is only a REAL permission request when Claude's
        # notification mentions permission (it says "needs your permission to
        # use <tool>"). Idle "Claude is waiting for your input" notifications —
        # very common in AUTO mode, where tool permissions are auto-accepted and
        # there is NO prompt — must NOT show the Approve/Deny buttons. Be
        # conservative: only true when "permission" is clearly present.
        state["needsPermission"] = bool(
            isinstance(msg, str) and "permission" in msg.lower()
        )
        if isinstance(msg, str) and msg:
            msg = " ".join(msg.split())
            state["statusDetail"] = (msg[:80] + "…") if len(msg) > 80 else msg
        else:
            state["statusDetail"] = "waiting for input"

    elif event == "Stop":
        state["status"] = "done"
        state["statusDetail"] = "finished"
        state["needsPermission"] = False

    elif event == "SubagentStop":
        # Leave parent status unchanged; just bump updatedAt below.
        # DEFENSIVE: count subagent completions seen on this session. Harmless
        # (stays 0/absent) when no Task-tool subagents are used. Does NOT change
        # status — the parent remains whatever it was (typically "working").
        try:
            state["subagentStops"] = int(state.get("subagentStops") or 0) + 1
        except Exception:
            state["subagentStops"] = 1

    else:
        # Unknown event: don't change status, just bump updatedAt + lastEvent.
        pass

    # Track when the current "working" turn began (for the UI's elapsed timer).
    # Stamp on the transition INTO working; clear once the session leaves working.
    if state.get("status") == "working":
        if prev_status != "working" or not state.get("turnStartedAt"):
            state["turnStartedAt"] = now_iso()
    else:
        state["turnStartedAt"] = None

    # Always bump updatedAt + record raw event.
    state["updatedAt"] = now_iso()
    if event:
        state["lastEvent"] = event

    # Atomic write: tmp then replace.
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

except Exception:
    # Swallow everything.
    pass

sys.exit(0)
PYEOF

# Whatever happened above, never block Claude Code.
exit 0
