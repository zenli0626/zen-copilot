import Foundation
import AppKit
import ApplicationServices

/// Brings the terminal window/tab matching a session's `tty` to the front —
/// **even when it lives on another Mission Control Space**.
///
/// Two steps:
///  1. AppleScript maps the stored `tty` to its window (selecting the right tab/
///     pane inside it) and returns that window's title. Supports Apple Terminal
///     (window → tab) and iTerm2 (window → tab → session).
///  2. The window is raised via the **Accessibility API** (`AXRaise` + make it
///     main + app frontmost), matched by that title. AX is the only thing that
///     reliably switches Spaces from a background (accessory) app. If AX isn't
///     granted, we fall back to AppleScript `frontmost`/`activate` (same-Space only).
@MainActor
enum FocusController {
    private static let terminalBundleID = "com.apple.Terminal"
    private static let itermBundleID = "com.googlecode.iterm2"
    private static let vsCodeBundleID = "com.microsoft.VSCode"
    private static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    static func focus(session: Session) {
        // VS Code / Cursor integrated terminal: both report termProgram "vscode".
        // We can't target the specific terminal tab, but we can focus the editor's
        // project window (best-effort title match on the workspace folder name).
        if session.termProgram == "vscode" {
            if focusEditor(project: session.project) { return }
            // fall through to generic activation below if no editor is running
            activateApp(for: session.termProgram)
            return
        }

        guard let tty = session.tty, !tty.isEmpty, tty != "??" else {
            activateApp(for: session.termProgram)
            return
        }

        // Which terminals to try, in order. Unknown owner → try both running ones.
        let candidates: [(bundleID: String, isITerm: Bool)]
        switch session.termProgram {
        case "iTerm.app":      candidates = [(itermBundleID, true)]
        case "Apple_Terminal": candidates = [(terminalBundleID, false)]
        default:               candidates = [(terminalBundleID, false), (itermBundleID, true)]
        }

        for c in candidates {
            guard let app = runningApp(c.bundleID) else { continue }

            // Step 1: select the tab/pane and get the owning window's title.
            let title = c.isITerm
                ? selectAndTitleITerm(bundleID: c.bundleID, tty: tty)
                : selectAndTitleTerminal(bundleID: c.bundleID, tty: tty)
            guard let title, !title.isEmpty else { continue } // no match in this terminal

            // Step 2a: raise via Accessibility (handles cross-Space). Preferred.
            if ensureAXTrusted(), raiseWindowViaAX(pid: app.processIdentifier, title: title) {
                return
            }

            // Step 2b: fallback — AppleScript frontmost + activate (same Space only).
            _ = run(frontmostScript(bundleID: c.bundleID, tty: tty, isITerm: c.isITerm))
            app.activate(options: [.activateAllWindows])
            return
        }

        // No Terminal/iTerm tab matched the tty. If the owner is unknown/empty, the
        // session may be running in an editor's integrated terminal — try that.
        if session.termProgram == nil || session.termProgram?.isEmpty == true,
           focusEditor(project: session.project) {
            return
        }

        activateApp(for: session.termProgram)
    }

    // MARK: - Cross-tool: VS Code / Cursor integrated terminal

    /// Bring a running editor (Cursor or VS Code) forward, raising the window whose
    /// AXTitle contains `project` so it crosses Spaces and picks the right window.
    /// Falls back to plain `activate` if no title matches. Never launches an editor.
    /// Returns true if some editor was running and was brought forward.
    private static func focusEditor(project: String) -> Bool {
        for bundleID in [cursorBundleID, vsCodeBundleID] {
            guard let app = runningApp(bundleID) else { continue }

            if ensureAXTrusted(),
               raiseWindowViaAX(pid: app.processIdentifier, titleContains: project) {
                return true
            }

            // No matching window title (or AX not granted) — just bring the app up.
            app.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }

    // MARK: - Step 1: select tab/pane, return window title

    private static func selectAndTitleTerminal(bundleID: String, tty: String) -> String? {
        run("""
        tell application id "\(bundleID)"
            set targetTTY to "\(escape(tty))"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if (tty of t) is targetTTY then
                            set selected of t to true
                            return (name of w)
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """)
    }

    private static func selectAndTitleITerm(bundleID: String, tty: String) -> String? {
        run("""
        tell application id "\(bundleID)"
            set targetTTY to "\(escape(tty))"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is targetTTY then
                                select t
                                select s
                                return (name of w)
                            end if
                        end repeat
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """)
    }

    // MARK: - Step 2a: Accessibility raise (cross-Space)

    /// Returns true if Accessibility is trusted; prompts (once, system dialog) if not.
    private static func ensureAXTrusted() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Raise the app window whose AXTitle exactly matches `title`, make it main, and
    /// bring the app frontmost. This is what switches Spaces. Returns false if not found.
    private static func raiseWindowViaAX(pid: pid_t, title: String) -> Bool {
        raiseWindowViaAX(pid: pid) { $0 == title }
    }

    /// Like `raiseWindowViaAX(pid:title:)` but matches windows whose AXTitle *contains*
    /// `substring` (e.g. an editor window title that includes the workspace folder name).
    /// Returns false if no window matches.
    private static func raiseWindowViaAX(pid: pid_t, titleContains substring: String) -> Bool {
        guard !substring.isEmpty else { return false }
        return raiseWindowViaAX(pid: pid) { $0.contains(substring) }
    }

    /// Shared raise logic: raise the first app window whose AXTitle satisfies `matches`,
    /// make it main, and bring the app frontmost. Returns false if none match.
    private static func raiseWindowViaAX(pid: pid_t, matches: (String) -> Bool) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        for win in windows {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
            guard let wt = t as? String, matches(wt) else { continue }
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            return true
        }
        return false
    }

    // MARK: - Step 2b: AppleScript fallback (same Space)

    private static func frontmostScript(bundleID: String, tty: String, isITerm: Bool) -> String {
        if isITerm {
            return """
            tell application id "\(bundleID)"
                set targetTTY to "\(escape(tty))"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if (tty of s) is targetTTY then
                                    select t
                                    select s
                                    activate
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
        return """
        tell application id "\(bundleID)"
            set targetTTY to "\(escape(tty))"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if (tty of t) is targetTTY then
                            set selected of t to true
                            set frontmost of w to true
                            activate
                            return "ok"
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
    }

    // MARK: - Helpers

    private static func activateApp(for termProgram: String?) {
        let bundleID = termProgram == "iTerm.app" ? itermBundleID : terminalBundleID
        runningApp(bundleID)?.activate(options: [.activateAllWindows])
    }

    private static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run AppleScript, returning result text (nil on error). Logs failures
    /// (incl. -1743 "not authorized" = Automation denied).
    @discardableResult
    private static func run(_ source: String) -> String? {
        guard let apple = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        if let error {
            NSLog("Zen-Copilot: focus AppleScript error: \(error)")
            return nil
        }
        return result.stringValue
    }
}
