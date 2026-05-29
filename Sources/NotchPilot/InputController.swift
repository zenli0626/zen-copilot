import Foundation
import AppKit

/// Injects a typed reply into a session's terminal and **submits** it (Return), as if
/// the user had typed it and pressed Enter — ideally **without** raising the terminal
/// or flashing focus.
///
/// The hard part is *submission*. Claude Code's TUI treats an injected text burst that
/// ends in a newline as **pasted** content: the trailing newline lands as a literal
/// newline inside the prompt rather than acting as a real "Enter", so the reply sits
/// in the composer unsubmitted. The fix is a **two-step** send: first inject the TEXT
/// body, then — after a short delay — deliver a **discrete Return** that the TUI sees
/// as a keypress (not part of the paste).
///
/// Paths, tried in order:
///  1. **iTerm2 native send (fully seamless).** Match the session whose `tty` equals
///     `session.tty`, then `write text "<text>" newline NO` (text, no newline). After
///     ~0.15s, `write text "" newline YES` delivers a lone discrete Return. No focus
///     at any point.
///  2. **Apple Terminal native send (text seamless, Enter needs brief focus).**
///     `do script "<text>" in <tab>` writes the text into the tab without raising it
///     (note: `do script` *always* appends a Return, which is exactly the paste-newline
///     that fails to submit). After ~0.15s we `FocusController.focus(session:)` and send
///     a real `key code 36` via System Events — a discrete Return that DOES submit.
///     Terminal therefore briefly raises focus for the Enter; reliability wins.
///  3. **System Events keystroke (last-resort fallback).** For vscode/cursor/unknown
///     termPrograms, or when no tty matches, or when the native AppleScript errors:
///     `FocusController.focus(session:)` then System Events `keystroke`s the text and a
///     real `key code 36`. This raises focus and types — but it already submits reliably.
///
/// (A prior TIOCSTI ioctl approach was removed: it returns ENOTTY on modern macOS.)
///
/// Single-line for v1; empty / whitespace-only text is a no-op.
@MainActor
enum InputController {
    private static let terminalBundleID = "com.apple.Terminal"
    private static let itermBundleID = "com.googlecode.iterm2"

    /// Delay between injecting the text body and delivering the discrete Return, so
    /// Claude's TUI registers the Return as a keypress rather than part of the paste.
    private static let submitDelay: TimeInterval = 0.15

    /// Send `text` to `session`'s terminal and submit it (Return). No-op if `text`
    /// is empty or only whitespace.
    static func send(_ text: String, to session: Session) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let tty = session.tty
        let hasUsableTTY = tty.map { !$0.isEmpty && $0 != "??" } ?? false

        // Path 1: iTerm2 — write text (no newline) to the matching session, then a
        // discrete lone-Return after a short delay. Fully seamless: no focus.
        if session.termProgram == "iTerm.app", hasUsableTTY, let tty {
            if run(itermSendTextScript(text: trimmed, tty: tty)) == "ok" {
                NSLog("Zen-Copilot: input via iTerm write-text (no newline, seamless) — step 1/2 done")
                DispatchQueue.main.asyncAfter(deadline: .now() + submitDelay) {
                    if run(itermSubmitScript(tty: tty)) == "ok" {
                        NSLog("Zen-Copilot: input iTerm discrete Return (write \"\" newline YES, seamless) — step 2/2 done")
                    } else {
                        // Discrete-return-in-place failed; fall back to a focused real Return.
                        NSLog("Zen-Copilot: input iTerm discrete Return failed — falling back to focused key code 36")
                        FocusController.focus(session: session)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            run(returnKeyScript())
                        }
                    }
                }
                return
            }
        }

        // Path 2: Apple Terminal — `do script ... in <tab>` writes the text (it appends
        // a Return that fails to submit), then after a short delay a real discrete
        // Return via System Events. Text is seamless; the Enter briefly raises focus.
        if session.termProgram == "Apple_Terminal", hasUsableTTY, let tty {
            if run(terminalSendTextScript(text: trimmed, tty: tty)) == "ok" {
                NSLog("Zen-Copilot: input via Apple Terminal do-script (text seamless) — step 1/2 done")
                DispatchQueue.main.asyncAfter(deadline: .now() + submitDelay) {
                    NSLog("Zen-Copilot: input Apple Terminal discrete Return (focus + key code 36) — step 2/2")
                    FocusController.focus(session: session)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        run(returnKeyScript())
                    }
                }
                return
            }
        }

        // Path 3 (fallback): bring the tab forward, then keystroke the text + a real
        // Return via System Events. Raises focus, but submits reliably.
        NSLog("Zen-Copilot: input falling back to System Events keystroke (focus + type + Return)")
        FocusController.focus(session: session)

        // Let focus / Space switch settle before typing into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            run(keystrokeScript(for: trimmed))
        }
    }

    // MARK: - Path 1: iTerm2 native send (fully seamless)

    /// Match the session (window → tab → session) whose `tty` equals the session's,
    /// then `write text` the body with `newline NO` so no trailing newline is sent.
    /// No focus. Returns "ok" on a match.
    private static func itermSendTextScript(text: String, tty: String) -> String {
        """
        tell application id "\(itermBundleID)"
            set targetTTY to "\(escape(tty))"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is targetTTY then
                                tell s to write text "\(escape(text))" newline NO
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
    }

    /// Deliver a discrete Return to the matching iTerm session: `write text "" newline
    /// YES` sends a lone newline with no preceding text. No focus. Returns "ok".
    private static func itermSubmitScript(tty: String) -> String {
        """
        tell application id "\(itermBundleID)"
            set targetTTY to "\(escape(tty))"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is targetTTY then
                                tell s to write text "" newline YES
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
    }

    // MARK: - Path 2: Apple Terminal native send (text seamless)

    /// Match the tab whose `tty` equals the session's, then `do script` the text into
    /// it. `do script` always appends a Return (which fails to submit in Claude's TUI —
    /// the discrete Return is delivered separately, focused, in step 2). No `activate`,
    /// so the tab is not raised for this step. Returns "ok" on a match.
    private static func terminalSendTextScript(text: String, tty: String) -> String {
        """
        tell application id "\(terminalBundleID)"
            set targetTTY to "\(escape(tty))"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if (tty of t) is targetTTY then
                            do script "\(escape(text))" in t
                            return "ok"
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
    }

    // MARK: - Discrete Return / System Events fallbacks

    /// A real discrete Return key event via System Events (used after focusing the
    /// target tab). `key code 36` is Return.
    private static func returnKeyScript() -> String {
        """
        tell application "System Events"
            key code 36
        end tell
        """
    }

    /// `tell System Events to keystroke "<escaped>"` followed by a real Return.
    private static func keystrokeScript(for text: String) -> String {
        """
        tell application "System Events"
            keystroke "\(escape(text))"
            key code 36
        end tell
        """
    }

    // MARK: - Helpers

    /// Escape backslashes and double-quotes for embedding in an AppleScript string
    /// literal. Backslash must be escaped first so the quote-escaping doesn't
    /// double-process the backslashes it introduces.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run AppleScript, logging failures (incl. -1743 "not authorized").
    @discardableResult
    private static func run(_ source: String) -> String? {
        guard let apple = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        if let error {
            NSLog("Zen-Copilot: input AppleScript error: \(error)")
            return nil
        }
        return result.stringValue
    }
}
