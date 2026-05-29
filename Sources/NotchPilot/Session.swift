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

    /// Sort priority: waiting first, then working, then idle/done/error.
    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        case .error: return 4
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
    var status: SessionStatus
    var statusDetail: String?
    var tty: String?
    var termSessionId: String?
    /// `TERM_PROGRAM` of the owning terminal, e.g. "Apple_Terminal", "iTerm.app",
    /// "vscode". Drives which AppleScript dialect FocusController uses.
    var termProgram: String?
    var model: String?
    var startedAt: Date?
    /// When the current `working` turn began; nil unless actively working.
    var turnStartedAt: Date?
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
    var updatedAt: Date

    var id: String { sessionId }

    /// Compact model label for the row badge, e.g. "claude-opus-4-8[1m]" → "opus-4-8".
    var modelShort: String? {
        guard var m = model, !m.isEmpty else { return nil }
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        m = m.replacingOccurrences(of: "claude-", with: "")
        return m.trimmingCharacters(in: .whitespaces).isEmpty ? nil : m
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
    /// cached — NEVER from a SwiftUI `body` / render path. It is fully defensive:
    /// it never throws and never crashes.
    ///
    /// Transcript format: each line is one JSON object. An assistant text turn
    /// looks roughly like
    /// `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"…"}]}}`.
    /// We also tolerate `{"role":"assistant","content":"…"}` and content arrays
    /// whose items are plain strings or `{type:text,text:…}` parts. We scan lines
    /// from the END and return the first assistant turn that yields non-empty text.
    func lastAssistantSummary(maxChars: Int = 2000) -> String? {
        guard let path = transcriptPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        // Read the whole file as UTF-8; bail quietly on any failure.
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // Split into lines and scan from the END for the last assistant text turn.
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
