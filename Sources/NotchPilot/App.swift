import AppKit

/// Programmatic @main entry. No storyboard, no Xcode project.
@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar utility: no Dock icon.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let notifications = NotificationManager()
    private lazy var menuBar = MenuBarController(store: store)
    private lazy var notch = NotchController(store: store, wellness: wellnessState)

    /// Shared wellness state — the pet UI observes `active` to act out each cue
    /// in the notch (speech bubble + matching pet animation). Retained here and
    /// injected into the `NotchController` so the view tree sees the same instance.
    let wellnessState = WellnessState()
    private lazy var wellnessController = WellnessController(
        state: wellnessState, notifications: notifications)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications.requestAuthorization()

        store.onTransition = { [weak self] session, from, to in
            self?.notifications.handleTransition(session: session, from: from, to: to)
        }

        menuBar.notchController = notch
        menuBar.wellnessController = wellnessController
        menuBar.start()
        notch.start()
        store.start()

        wellnessController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        wellnessController.stop()
    }
}
