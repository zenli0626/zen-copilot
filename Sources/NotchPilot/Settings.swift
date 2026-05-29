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
    }

    private init() {
        // Default audio cues to ON for users who've never toggled the setting.
        // `register` only fills in values absent from disk, so an explicit user
        // choice (including `false`) always wins.
        defaults.register(defaults: [
            Key.soundsEnabled: true,
            Key.wellnessEnabled: true,
        ])
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
