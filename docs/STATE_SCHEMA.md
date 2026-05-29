# Zen-Copilot — State Contract (the spec both the app and the hooks obey)

> The internal Swift module / state files are named **NotchPilot** (e.g.
> `~/.notchpilot/`, `notchpilot-hook.sh`); the user-facing app/product is
> **Zen-Copilot**. Both names are used below where each is accurate.

This is the **single source of truth** shared by the Swift app (the reader) and the
Claude Code hooks (the writer). Do not diverge from it without updating this file.

## Storage layout

- State root: `~/.notchpilot/`
- One file **per session**: `~/.notchpilot/sessions/<session_id>.json`
- Files are written **atomically** (write to `*.tmp` then `rename`) so the app
  never reads a half-written file.
- A session file is **deleted** when the session ends (`SessionEnd` event) OR is
  treated as stale by the app if `updatedAt` is older than 6 hours.

## Session JSON shape (v1)

```json
{
  "schemaVersion": 1,
  "sessionId": "a1b2c3d4-...",        // Claude Code session_id (from hook stdin)
  "project": "web-app",                // basename of cwd
  "cwd": "/Users/you/Projects/web-app",
  "gitBranch": "main",                  // current branch of cwd (or "@<short-sha>" detached); absent for non-git dirs. Disambiguates same-named sessions / worktrees.
  "isWorktree": false,                  // true when cwd is a LINKED git worktree (not the main checkout); absent for non-git dirs
  "gitRepoRoot": "/Users/you/Projects/web-app",  // absolute working-tree toplevel (distinct per worktree); absent for non-git dirs
  "repoName": "web-app",                // STABLE shared-repo name (same for every worktree of one repo); absent for non-git dirs
  "status": "working",                 // see Status enum below
  "statusDetail": "Edit src/App.tsx",  // short human label, optional
  "tty": "/dev/ttys003",               // controlling terminal, for click-to-focus; may be null
  "termSessionId": "w0t0p0:UUID",      // $TERM_SESSION_ID fallback for focus; may be null
  "termProgram": "Apple_Terminal",     // $TERM_PROGRAM: picks the focus dialect (Apple_Terminal | iTerm.app | vscode | …); may be null
  "model": "Opus 4.6",                  // optional, best-effort
  "startedAt": "2026-05-28T17:45:00Z",  // ISO8601 UTC
  "enteredStatusAt": null,              // when the session entered `waiting` (stamped on the transition); null otherwise. Drives "blocked for 17m" + oldest-waiting-first triage.
  "updatedAt": "2026-05-28T17:46:12Z",  // ISO8601 UTC, bumped every event
  "lastEvent": "PreToolUse",            // raw hook_event_name that produced this state

  // --- Subagent linkage (DEFENSIVE / optional, may all be absent) ----------
  "parentSessionId": null,              // parent session id IF the payload ever exposes one
  "agentId": null,                      // distinct subagent/agent id IF exposed
  "agentType": null,                    // subagent_type/agent_type label IF exposed
  "subagentStops": 0                    // count of SubagentStop events seen on this session
}
```

### Subagent / parent-child fields (optional, defensive)

These exist so we **don't lose** any parent→child linkage the hook payload might
carry, but they are best-effort and frequently **absent**:

- `parentSessionId` / `agentId` / `agentType` — populated only if the hook stdin
  contains a matching field (`parent_session_id`/`parent_id`, `agent_id`/`subagent_id`,
  `agent_type`/`subagent_type`). The current public Claude Code hook schema does
  **not** document these, so in practice they are usually `null`/absent.
- `subagentStops` — incremented on every `SubagentStop` event. Useful as a coarse
  "this session spawned N subagents" signal even when no real linkage exists. It
  does **not** change `status`.

⚠️ Do not build a real parent→child session tree on these fields without first
confirming the running Claude Code version actually emits the linkage. As of this
writing, `SubagentStop` fires on the **parent** session's hook carrying the
**parent's** `session_id` and no child identifier — so a true tree is not yet
constructable from the hook payload alone.

## Status enum (string)

| status      | meaning                                          | color (UI) |
|-------------|--------------------------------------------------|------------|
| `idle`      | session started / between turns, nothing running | gray       |
| `working`   | actively running (prompt submitted / tool exec)  | green      |
| `waiting`   | needs the human: permission prompt or input idle | amber      |
| `done`      | turn finished, agent yielded (Stop)              | blue       |
| `error`     | last turn errored (best-effort)                  | red        |

## Event → status mapping (the hook implements exactly this)

| Claude Code hook event | resulting status | notes                                            |
|------------------------|------------------|--------------------------------------------------|
| `SessionStart`         | `idle`           | create file; capture tty, termSessionId, project, model, startedAt |
| `UserPromptSubmit`     | `working`        | statusDetail = "thinking…"                        |
| `PreToolUse`           | `working`        | statusDetail = "<ToolName> <short target>"        |
| `PostToolUse`          | `working` OR `error` | `error` ("<Tool> failed") when `tool_response.is_error == true`; else "ran <ToolName>" |
| `Notification`         | `waiting` OR `error` | `waiting` normally (permission or idle); `error` when the message is error-shaped and not a permission prompt |
| `Stop`                 | `done`           | statusDetail = "finished" — app fires a notification on this transition. NEVER produces `error`. |
| `SubagentStop`         | (unchanged)      | leave parent status as `working`; optionally bump updatedAt |
| `SessionEnd`           | (delete file)    | remove `<session_id>.json`                        |

**Git topology** (`gitBranch` / `isWorktree` / `gitRepoRoot` / `repoName`) is recomputed
from a single defensive `git rev-parse` (1s timeout) ONLY on `SessionStart` and
`UserPromptSubmit` — not every tool call — and is left untouched (not nulled) on a
transient git failure. `repoName` is the basename of the dir holding the COMMON `.git`,
so all worktrees of one repo share it; `gitRepoRoot` differs per worktree.

Every event MUST update `updatedAt`. `status` only changes per the table above.
`startedAt` is written once and never overwritten. `tty`, `termSessionId`, and
`termProgram` are **refreshed to the current terminal on every event** (a session
can move tabs via `--resume`, so click-to-focus must follow where it runs now) —
but only when a valid current value is available; an empty/`??` capture never
clobbers a previously good value.

## Hook stdin (what Claude Code passes the hook)

Claude Code pipes a JSON object to the hook on **stdin**. Relevant fields:
`hook_event_name`, `session_id`, `transcript_path`, `cwd`. (Plus event-specific
fields like `tool_name` for PreToolUse, `message` for Notification.) The hook reads
stdin JSON and the env (`TERM_SESSION_ID`) and derives the file above.

## tty capture (for click-to-focus)

The controlling terminal is inherited even when the hook's stdin is a pipe, so:
` tty="/dev/$(ps -o tty= -p $$ | tr -d ' ')" ` — guard against `??`/empty → null.
Also record `$TERM_SESSION_ID` as a fallback key.

## Focus action (the app implements; documented here so hooks know what to store)

Both **Apple Terminal** (window → tab) and **iTerm2** (window → tab → session)
expose `tty` via AppleScript. The app picks the dialect from `termProgram` and
focuses by matching that `tty`, then raises the window and activates the app. It
only ever scripts a terminal that's already running, so a click never launches
one. (See app's FocusController.)
