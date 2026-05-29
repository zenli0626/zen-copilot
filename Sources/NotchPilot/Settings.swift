import Foundation

/// Persisted user settings, backed by `UserDefaults.standard`. A tiny singleton
/// so any caller (NotificationManager, MenuBarController) reads/writes the same
/// store and changes survive across launches.
@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Keys for persisted values. Kept namespaced to avoid collisions.
    private enum Key {
        static let soundsEnabled = "zc.soundsEnabled"
        static let wellnessEnabled = "zc.wellnessEnabled"
        static let aliases = "zc.aliases"
        static let replySnippets = "zc.replySnippets"
    }

    private init() {
        // Default audio cues to ON for users who've never toggled the setting.
        // `register` only fills in values absent from disk, so an explicit user
        // choice (including `false`) always wins.
        defaults.register(defaults: [
            Key.soundsEnabled: true,
            Key.wellnessEnabled: true,
            Key.replySnippets: ["continue", "yes, proceed", "run the tests", "commit + push", "explain…"],
        ])
    }

    // MARK: - Session aliases

    /// User-set display names keyed by ABSOLUTE `cwd`. Keyed by cwd (not sessionId)
    /// so the name survives `claude --resume`, which rotates the session id but keeps
    /// the directory — and so two same-named worktrees can be named distinctly.
    var sessionAliases: [String: String] {
        get { (defaults.dictionary(forKey: Key.aliases) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.aliases) }
    }

    /// The alias set for `cwd`, trimmed; nil when unset or blank.
    func alias(forCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let a = sessionAliases[cwd]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (a?.isEmpty == false) ? a : nil
    }

    /// Set (or, when blank, clear) the alias for `cwd`.
    func setAlias(_ alias: String?, forCwd cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        var dict = sessionAliases
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { dict.removeValue(forKey: cwd) } else { dict[cwd] = trimmed }
        sessionAliases = dict
    }

    /// The name to show for a session: the user's alias (by cwd) or the project
    /// basename. Resolved here (MainActor) so `Session` stays a plain value type.
    func displayName(for session: Session) -> String {
        alias(forCwd: session.cwd) ?? session.project
    }

    // MARK: - Reply snippets

    /// Canned one-tap replies for the inline composer. A trailing "…" means
    /// pre-fill the field (don't send) so you can finish the sentence.
    var replySnippets: [String] {
        get { defaults.stringArray(forKey: Key.replySnippets) ?? [] }
        set { defaults.set(newValue, forKey: Key.replySnippets) }
    }

    /// Whether session audio cues (Glass / Submarine) play. Read at call time
    /// by NotificationManager so a menu toggle takes effect immediately.
    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    /// Whether periodic wellness reminders (stretch / water / eyes / posture)
    /// fire. Read at fire time by WellnessController so the toggle takes effect
    /// immediately.
    var wellnessEnabled: Bool {
        get { defaults.bool(forKey: Key.wellnessEnabled) }
        set { defaults.set(newValue, forKey: Key.wellnessEnabled) }
    }
}
