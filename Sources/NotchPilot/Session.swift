import Foundation
import SwiftUI

/// Status of a Claude Code session, mirroring the STATE_SCHEMA.md enum.
enum SessionStatus: String, Codable, Sendable {
    case idle
    case working
    case waiting
    case done
    case error

    /// Unknown / future values decode to `.idle` rather than failing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .idle
    }

    /// Status tone, drawn from the Claude semantic palette (see `Theme.swift`).
    /// Warm Claude tones replace the old neon green/orange/blue.
    var color: Color {
        switch self {
        case .idle: return Color.cl.onDarkSoft
        case .working: return Color.cl.success
        case .waiting: return Color.cl.amber
        case .done: return Color.cl.teal
        case .error: return Color.cl.error
        }
    }

    /// Sort priority: the things that need the human float to the top —
    /// waiting first, then error (a failed turn is easy to miss but wants you),
    /// then in-flight working, then done, then idle.
    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        }
    }
}

/// One Claude Code session, decoded from `~/.notchpilot/sessions/<id>.json`.
/// Tolerates missing optional fields per the contract.
struct Session: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion: Int?
    var sessionId: String
    var project: String
    var cwd: String?
    /// Current git branch of `cwd` (or `@<short-sha>` when detached), captured by
    /// the hook. The primary disambiguator for same-named sessions / worktrees.
    /// Decode-tolerant: nil for non-git dirs or older state files.
    var gitBranch: String?
    /// True when `cwd` is a LINKED git worktree (not the main checkout). Drives the
    /// small "WT" tag so duplicate-named worktree rows are obvious. Decode-tolerant.
    var isWorktree: Bool?
    /// Absolute toplevel of `cwd`'s working tree (distinct per worktree). Optional.
    var gitRepoRoot: String?
    /// STABLE shared-repo name — identical for every worktree of one repo (basename
    /// of the dir holding the common `.git`). Lets the UI group/identify by repo even
    /// when worktree dir names differ. Decode-tolerant.
    var repoName: String?
    var status: SessionStatus
    var statusDetail: String?
    /// Whether a `.waiting` session is a REAL permission request (Claude's
    /// notification said "needs your permission to use <tool>"), as opposed to an
    /// idle "Claude is waiting for your input" (very common in AUTO mode, where
    /// there is no prompt to answer). Only when `true` should the row show the
    /// Approve / Allow Once / Deny buttons. Optional + decode-tolerant so older
    /// state files (without the field) still decode; nil/false both mean "no
    /// permission prompt".
    var needsPermission: Bool?
    var tty: String?
    var termSessionId: String?
    /// `TERM_PROGRAM` of the owning terminal, e.g. "Apple_Terminal", "iTerm.app",
    /// "vscode". Drives which AppleScript dialect FocusController uses.
    var termProgram: String?
    var model: String?
    var startedAt: Date?
    /// When the current `working` turn began; nil unless actively working.
    var turnStartedAt: Date?
    /// When the session ENTERED its current waiting state (stamped by the hook on the
    /// transition into waiting; nil otherwise). Drives "blocked for 17m" + oldest-
    /// waiting-first triage. Decode-tolerant; falls back to `updatedAt` when absent.
    var enteredStatusAt: Date?
    /// Subagent / parent-child linkage — DEFENSIVE, optional. The Claude Code
    /// hook payload does not currently expose reliable parent→child linkage for
    /// Task-tool subagents; these decode whatever the hook captured (if anything)
    /// and tolerate absence. Do not build tree UI assuming these are populated.
    var parentSessionId: String?
    var agentId: String?
    var agentType: String?
    /// Count of `SubagentStop` events observed for this session; nil/0 when no
    /// subagents were used.
    var subagentStops: Int?
    /// Path to this session's Claude Code transcript `.jsonl` (one JSON object
    /// per line). Captured defensively by the hook from the stdin
    /// `transcript_path`; may be absent on older state files. Read on demand —
    /// see `lastAssistantSummary(maxChars:)` — NEVER from a SwiftUI render path.
    var transcriptPath: String?
    /// How many tokens the most recent assistant turn carried in its prompt
    /// (input + cache-read + cache-creation), i.e. how full the model's context
    /// window is. Captured defensively by the hook from the transcript tail; may
    /// be absent (older state files, or no assistant turn yet). Decode-tolerant.
    var contextTokens: Int?
    var updatedAt: Date

    var id: String { sessionId }

    /// Key identifying one attention EPISODE: id + status + a per-episode stamp.
    /// The stamp is `enteredStatusAt` (stable across a wait, fresh on each new wait)
    /// and falls back to `updatedAt` for error/done (which the hook re-stamps each
    /// time they're (re)entered). Used by the unread badge + per-row dots so a
    /// re-entered status re-notifies instead of colliding with a persisted seen-key.
    static func attentionEpisodeKey(_ s: Session) -> String {
        let stamp = Int((s.enteredStatusAt ?? s.updatedAt).timeIntervalSince1970)
        return "\(s.id):\(s.status.rawValue):\(stamp)"
    }

    /// Home-abbreviated form of `cwd` for display — "/Users/zenli/BY-Website/by"
    /// → "~/BY-Website/by". Nil when `cwd` is missing/empty. Used as the full
    /// location string (the row truncates it in the middle so the head and the
    /// project tail both stay visible, which is what disambiguates two same-named
    /// sessions living in different directories / worktrees).
    var cwdHome: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~/" + String(cwd.dropFirst(home.count + 1)) }
        return cwd
    }

    /// Short terminal-tab tag from `tty` ("/dev/ttys005" → "ttys005"). Guaranteed
    /// unique per tab, so it's the last-resort disambiguator when two sessions share
    /// both project name AND directory. Nil when tty is missing/"??".
    var ttyShort: String? {
        guard let tty, !tty.isEmpty, tty != "??" else { return nil }
        return tty.replacingOccurrences(of: "/dev/", with: "")
    }

    /// Compact model label for the row badge, e.g. "claude-opus-4-8[1m]" → "opus-4-8".
    var modelShort: String? {
        guard var m = model, !m.isEmpty else { return nil }
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        m = m.replacingOccurrences(of: "claude-", with: "")
        return m.trimmingCharacters(in: .whitespaces).isEmpty ? nil : m
    }

    /// The model's total context window in tokens. We can't know it exactly from
    /// the state file, so we infer from the model name: a "[1m]" / "1m" variant is
    /// the 1,000,000-token window; everything else defaults to 200,000.
    var contextWindow: Int {
        if let m = model?.lowercased(), m.contains("1m") { return 1_000_000 }
        return 200_000
    }

    /// How full the context window is, as an integer percent (0–100). Nil when we
    /// have no token count yet. Rounds to the nearest percent and clamps to 0–100
    /// (a turn can momentarily report slightly above the nominal window).
    var contextPercent: Int? {
        guard let tokens = contextTokens, tokens > 0 else { return nil }
        let pct = Int((Double(tokens) / Double(contextWindow) * 100).rounded())
        return min(100, max(0, pct))
    }

    /// Total session age — `startedAt` to now — formatted compactly ("2h14m",
    /// "45m", "30s"). This is the session's LIFETIME, distinct from the current
    /// working turn (`turnElapsed`). Nil if we never captured `startedAt`.
    func sessionElapsed(asOf now: Date = Date()) -> String? {
        guard let start = startedAt else { return nil }
        let secs = Int(max(0, now.timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        return "\(h)h\(m % 60)m"
    }

    /// How long this session has been WAITING, in seconds. Uses `enteredStatusAt`
    /// (stamped on the transition into waiting) and falls back to `updatedAt` for
    /// older state files. Nil unless currently waiting.
    func waitSeconds(asOf now: Date = Date()) -> Int? {
        guard status == .waiting else { return nil }
        let since = enteredStatusAt ?? updatedAt
        return Int(max(0, now.timeIntervalSince(since)))
    }

    /// Human "blocked for" label for a waiting session, e.g. "17m", "2h4m", "45s".
    /// Nil unless waiting.
    func waitElapsed(asOf now: Date = Date()) -> String? {
        guard let secs = waitSeconds(asOf: now) else { return nil }
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        return "\(h)h\(m % 60)m"
    }

    /// Human elapsed time for the current working turn, e.g. "2m14s". Nil unless working.
    func turnElapsed(asOf now: Date = Date()) -> String? {
        guard status == .working, let start = turnStartedAt else { return nil }
        let secs = Int(max(0, now.timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60
        return "\(h)h\(m % 60)m"
    }

    /// A whitespace-collapsed excerpt of Claude's MOST RECENT assistant message in
    /// this session's transcript — i.e. "what you're replying to" when answering
    /// from the notch. Capped at `maxChars` (default ~2000) with a trailing ellipsis
    /// on overflow; the reply UI renders it full-width and wrapping inside a scroll
    /// view so the whole excerpt is readable. Returns nil on any failure (no
    /// `transcriptPath`, missing / unreadable file, no assistant text found, parse errors).
    ///
    /// PERFORMANCE / SAFETY: this does synchronous file IO and JSON parsing, so it
    /// MUST be called on demand (e.g. once when the reply box opens) and the result
    /// cached — NEVER from a SwiftUI `body` / render path. It reads only the TAIL of
    /// the transcript (256KB, expanding to 1MB→4MB→8MB only if the last assistant
    /// text hasn't been found yet), so it stays fast even on multi-hundred-MB
    /// transcripts. It is fully defensive: never throws, never crashes.
    ///
    /// Transcript format: each line is one JSON object. An assistant text turn
    /// looks roughly like
    /// `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"…"}]}}`.
    /// We also tolerate `{"role":"assistant","content":"…"}` and content arrays
    /// whose items are plain strings or `{type:text,text:…}` parts. We scan lines
    /// from the END and return the first assistant turn that yields non-empty text.
    func lastAssistantSummary(maxChars: Int = 100_000) -> String? {
        guard let path = transcriptPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        // Expand-and-retry windows. Unlike `usage` (always on the very last line),
        // the last assistant TEXT can be pushed back by a large trailing tool_result,
        // so a fixed 256KB tail could miss it — we grow the window until we find it.
        let windows = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024]
        for window in windows {
            guard let (text, wholeFile) = Session.tailText(of: url, window: window) else { return nil }
            if let summary = Session.scanLastAssistant(in: text, maxChars: maxChars) {
                return summary
            }
            // The window already covered the WHOLE file and found no assistant text —
            // growing won't help, so stop (nil) rather than re-reading it below.
            if wholeFile { return nil }
        }
        // File exceeded the largest (8MB) window and the tail never contained an
        // assistant text turn — the last one was pushed back by a huge trailing
        // tool_result. Do one guaranteed whole-file pass so the reply context isn't
        // empty on exactly the big transcripts the tail-read was meant to speed up.
        if let data = try? Data(contentsOf: url) {
            return Session.scanLastAssistant(in: String(decoding: data, as: UTF8.self), maxChars: maxChars)
        }
        return nil
    }

    /// Read up to the last `window` bytes of `url` as UTF-8, dropping the partial
    /// first line after a mid-file seek. Returns the text and whether it covered the
    /// WHOLE file (so callers can stop expanding). Nil on any IO error — fully
    /// defensive (FileHandle calls are wrapped; never crashes).
    private static func tailText(of url: URL, window: Int) -> (text: String, wholeFile: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            if size <= UInt64(window) {
                try handle.seek(toOffset: 0)
                guard let data = try handle.readToEnd() else { return nil }
                return (String(decoding: data, as: UTF8.self), true)
            }
            try handle.seek(toOffset: size - UInt64(window))
            guard let data = try handle.readToEnd() else { return nil }
            var text = String(decoding: data, as: UTF8.self)
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            return (text, false)
        } catch {
            return nil
        }
    }

    /// Scan `contents` (a transcript or transcript tail) from the END for the last
    /// assistant text turn and return its condensed summary, or nil.
    private static func scanLastAssistant(in contents: String, maxChars: Int) -> String? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

            // The role can live at the top level or nested under "message".
            // Many Claude Code lines wrap the turn in {"type":"assistant","message":{…}}.
            let message = obj["message"] as? [String: Any]
            let role = (obj["role"] as? String) ?? (message?["role"] as? String)
            let type = obj["type"] as? String
            let looksAssistant = (role == "assistant") || (type == "assistant" && role == nil)
            guard looksAssistant else { continue }

            // Content can be on the wrapper or nested under message.
            let content = obj["content"] ?? message?["content"]
            let text = Session.extractText(from: content)
            if let summary = Session.condense(text, maxChars: maxChars) {
                return summary
            }
        }
        return nil
    }

    /// Pull concatenated plain text out of a transcript "content" value, which may
    /// be a String, or an array of strings / `{type:"text","text":"…"}` parts.
    /// Non-text parts (tool_use, images, …) are ignored.
    private static func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        guard let parts = content as? [Any] else { return "" }
        var pieces: [String] = []
        for part in parts {
            if let s = part as? String {
                pieces.append(s)
            } else if let dict = part as? [String: Any] {
                // Treat anything with a "text" field as text (tolerant of missing "type").
                if (dict["type"] as? String) == "text" || dict["text"] != nil,
                   let t = dict["text"] as? String {
                    pieces.append(t)
                }
            }
        }
        return pieces.joined(separator: " ")
    }

    /// Normalize an assistant message for the "↩ Replying to" renderer:
    /// PRESERVE structure (newlines/paragraphs) while cleaning block-markdown
    /// noise, so the SwiftUI markdown renderer can format inline markup and show
    /// paragraphs instead of a single collapsed wall of text.
    ///
    /// Rules:
    /// - Collapse runs of spaces/tabs to a single space, but KEEP newlines.
    /// - Collapse 3+ consecutive newlines to 2 (at most one blank line between
    ///   paragraphs). Trim leading/trailing whitespace.
    /// - Per line, strip leading BLOCK markers so they don't render as literal
    ///   characters: a leading `#{1,6}\s+` (heading → keep the heading text),
    ///   a leading `>\s?` (blockquote), and convert a leading `[-*+]\s+`
    ///   (bullet) to `• `. INLINE markup (`**bold**`, `*italic*`, `` `code` ``)
    ///   is left intact for the renderer.
    /// - Truncate to `maxChars` with an ellipsis, preferring a whitespace/line
    ///   boundary near the cap so we don't cut mid-word.
    /// Returns nil if the result is empty.
    private static func condense(_ text: String, maxChars: Int) -> String? {
        // Split on newlines, normalize each line, then rejoin preserving breaks.
        let rawLines = text.components(separatedBy: "\n")
        var normalizedLines: [String] = []
        normalizedLines.reserveCapacity(rawLines.count)

        for raw in rawLines {
            // Collapse runs of spaces/tabs (NOT newlines) to a single space.
            var line = raw
                .components(separatedBy: CharacterSet(charactersIn: " \t"))
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            line = Session.stripLeadingBlockMarkers(line)
            normalizedLines.append(line)
        }

        // Rejoin, then collapse 3+ consecutive newlines to exactly 2.
        var joined = normalizedLines.joined(separator: "\n")
        while joined.contains("\n\n\n") {
            joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        let normalized = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.count <= maxChars { return normalized }

        // Truncate near the cap, preferring a whitespace/newline boundary so we
        // don't slice a word in half when an easy break is close behind.
        let hardEnd = normalized.index(normalized.startIndex, offsetBy: maxChars)
        var cut = normalized[..<hardEnd]
        if let boundary = cut.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards),
           normalized.distance(from: boundary.lowerBound, to: hardEnd) <= 24 {
            cut = normalized[..<boundary.lowerBound]
        }
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Strip leading block-level markdown markers from a single line. Inline
    /// markup is untouched. Headings keep their text; blockquotes drop the
    /// `>`; bullets become `• `.
    private static func stripLeadingBlockMarkers(_ line: String) -> String {
        // Work on a copy with leading spaces preserved-but-considered: markers
        // are detected at the start of the trimmed content.
        let leadingWS = line.prefix { $0 == " " }
        var rest = String(line.dropFirst(leadingWS.count))

        // Heading: #{1,6} followed by whitespace → keep the heading text.
        if let first = rest.first, first == "#" {
            var hashes = 0
            for ch in rest {
                if ch == "#" { hashes += 1 } else { break }
            }
            if hashes >= 1, hashes <= 6 {
                let afterHashes = rest.index(rest.startIndex, offsetBy: hashes)
                if afterHashes < rest.endIndex, rest[afterHashes] == " " {
                    rest = String(rest[afterHashes...]).trimmingCharacters(in: .whitespaces)
                    return String(leadingWS) + rest
                }
            }
        }

        // Blockquote: leading `>` with an optional single space.
        if rest.hasPrefix("> ") {
            rest = String(rest.dropFirst(2))
            return String(leadingWS) + rest
        }
        if rest.hasPrefix(">") {
            rest = String(rest.dropFirst(1))
            return String(leadingWS) + rest
        }

        // Bullet: leading `-`, `*`, or `+` followed by whitespace → `• `.
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let afterMarker = rest.index(after: rest.startIndex)
            if afterMarker < rest.endIndex, rest[afterMarker] == " " {
                rest = "• " + String(rest[rest.index(after: afterMarker)...])
                return String(leadingWS) + rest
            }
        }

        return line
    }

    /// Relative, human friendly form of `updatedAt`, e.g. "12s ago".
    var relativeUpdated: String {
        let interval = Date().timeIntervalSince(updatedAt)
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
