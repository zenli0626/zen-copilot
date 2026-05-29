import Foundation
import Combine

/// Stable identifier for each wellness cue. The pet animation layer (pass 2)
/// switches on this to act each cue out (stretch pose, drink, look away, sit up).
enum WellnessCue: String {
    case stretch
    case water
    case lookAway
    case posture
}

/// A single periodic wellness nudge: how often it fires, what the macOS
/// notification says, and the short speech-bubble caption the pet will speak.
struct WellnessReminder: Identifiable, Equatable {
    /// The cue type doubles as the stable identity (one reminder per cue).
    var kind: WellnessCue
    var id: WellnessCue { kind }

    /// Notification banner title.
    var title: String
    /// Notification banner body.
    var body: String
    /// Short speech-bubble text for the pet (pass 2).
    var caption: String
    /// Decorative emoji for the cue.
    var emoji: String
    /// How often this reminder fires.
    var interval: TimeInterval

    // MARK: - The four reminders

    /// 20-20-20 eye-rest cue — every 20 minutes.
    static let lookAway = WellnessReminder(
        kind: .lookAway,
        title: "Look away 👀",
        body: "20-20-20: look ~20 ft away for 20 seconds.",
        caption: "look away 👀",
        emoji: "👀",
        interval: 20 * 60)

    /// Posture check — every 30 minutes.
    static let posture = WellnessReminder(
        kind: .posture,
        title: "Posture check 🪑",
        body: "Sit up tall, shoulders back, unclench your jaw.",
        caption: "sit up 🪑",
        emoji: "🪑",
        interval: 30 * 60)

    /// Stand & stretch — every 45 minutes.
    static let stretch = WellnessReminder(
        kind: .stretch,
        title: "Stand & stretch 🧘",
        body: "You've been sitting a while — stand up and stretch.",
        caption: "stretch! 🧘",
        emoji: "🧘",
        interval: 45 * 60)

    /// Hydration — every 60 minutes.
    static let water = WellnessReminder(
        kind: .water,
        title: "Hydrate 💧",
        body: "Time to drink some water.",
        caption: "water 💧",
        emoji: "💧",
        interval: 60 * 60)

    /// All reminders, ordered shortest-interval first.
    static let all: [WellnessReminder] = [.lookAway, .posture, .stretch, .water]
}

/// Shared, observable state for the currently-active wellness cue. The pet UI
/// (pass 2) observes `active` and acts the cue out, then it auto-clears.
@MainActor
final class WellnessState: ObservableObject {
    /// The reminder currently being shown. Set when one fires, cleared a few
    /// seconds later. `nil` means "no cue right now".
    @Published var active: WellnessReminder?
}

/// Owns the wellness reminder schedule: one repeating timer per reminder. On
/// fire it publishes to `WellnessState`, posts a macOS notification, and clears
/// the cue after a short display window. Timer/Date are fine in this app.
@MainActor
final class WellnessController {
    /// How long a fired cue stays visible (the pet acts it out) before clearing.
    private let displayDuration: TimeInterval = 8

    private let state: WellnessState
    private let notifications: NotificationManager

    private var timers: [Timer] = []
    private var clearWorkItem: DispatchWorkItem?

    /// How long each cue is shown during a manual `testAll()` walkthrough.
    private let testStepDuration: TimeInterval = 3.5
    /// Bumped on every `testAll()` invocation so a fresh run cancels any
    /// still-pending steps from a previous run (avoids double-stepping).
    private var testToken = 0

    init(state: WellnessState, notifications: NotificationManager) {
        self.state = state
        self.notifications = notifications
    }

    /// Schedule every reminder on its own repeating timer. First fire is after
    /// one interval (never on launch). Each reminder is staggered by a small
    /// offset so they don't all align on the minute.
    func start() {
        stop()

        for (index, reminder) in WellnessReminder.all.enumerated() {
            // Small per-reminder stagger so cues don't pile up at the same instant.
            let stagger = TimeInterval(index) * 7
            let timer = Timer.scheduledTimer(
                withTimeInterval: reminder.interval + stagger,
                repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.fire(reminder)
                    }
                }
            // Allow firing while menus are open / during scrolling.
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
    }

    /// Invalidate all timers and cancel any pending clear. Idempotent.
    func stop() {
        for timer in timers { timer.invalidate() }
        timers.removeAll()
        clearWorkItem?.cancel()
        clearWorkItem = nil
    }

    /// Manually walk the pet through every cue, back-to-back, so the user can
    /// see all four reminders without waiting for the real schedule. Visual-only:
    /// fires regardless of `Settings.shared.wellnessEnabled` and posts NO macOS
    /// notifications. Re-invoking restarts cleanly (a new sequence token cancels
    /// any pending steps from the prior run). Does not touch the scheduled timers.
    func testAll() {
        let reminders = WellnessReminder.all
        guard !reminders.isEmpty else { return }

        // Invalidate any pending steps from a previous testAll() and cancel the
        // scheduled auto-clear so it can't wipe a test cue mid-walkthrough.
        testToken &+= 1
        let token = testToken
        clearWorkItem?.cancel()
        clearWorkItem = nil

        // Show the first cue immediately, then step through the rest.
        state.active = reminders[0]

        for (index, reminder) in reminders.enumerated() where index > 0 {
            let delay = testStepDuration * TimeInterval(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.testToken == token else { return }
                self.state.active = reminder
            }
        }

        // After the last cue's display window, clear back to no-cue.
        let clearDelay = testStepDuration * TimeInterval(reminders.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) { [weak self] in
            guard let self, self.testToken == token else { return }
            self.state.active = nil
        }
    }

    /// Fire a single reminder: respect the toggle, publish the cue, post the
    /// notification, and schedule the auto-clear.
    private func fire(_ reminder: WellnessReminder) {
        guard Settings.shared.wellnessEnabled else { return }

        state.active = reminder
        notifications.postReminder(title: reminder.title, body: reminder.body)

        // Replace any in-flight clear so a new cue gets its full display window.
        clearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Only clear if this reminder is still the active one.
            if self?.state.active == reminder {
                self?.state.active = nil
            }
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: work)
    }
}
