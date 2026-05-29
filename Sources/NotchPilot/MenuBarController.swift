import Foundation
import AppKit
import Combine

/// Owns the NSStatusItem: a compact glyph + active session count, with a menu
/// listing each session and a Quit item. Clicking a session focuses its terminal.
@MainActor
final class MenuBarController: NSObject {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private var cancellable: AnyCancellable?

    /// Set by AppDelegate after init; drives the "Hide/Show notch overlay" item.
    weak var notchController: NotchController?

    /// Set by AppDelegate after init; backs the "Test reminders" item.
    weak var wellnessController: WellnessController?

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        cancellable = store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.updateTitle(for: sessions)
            }
        updateTitle(for: store.sessions)
    }

    private func updateTitle(for sessions: [Session]) {
        guard let button = statusItem.button else { return }
        button.title = "◆ \(sessions.count)"
        button.font = .menuBarFont(ofSize: 0)
    }

    private func rebuildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()

        if store.sessions.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, session) in store.sessions.enumerated() {
                let title = menuTitle(for: session)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(selectSession(_:)),
                    keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = dotImage(for: session.status)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if let notchController {
            let hidden = notchController.isOverlayHidden
            let toggle = NSMenuItem(
                title: hidden ? "Show notch overlay" : "Hide notch overlay",
                action: #selector(toggleOverlay),
                keyEquivalent: "h")
            toggle.target = self
            menu.addItem(toggle)
        }

        let sounds = NSMenuItem(
            title: "Play sounds",
            action: #selector(toggleSounds),
            keyEquivalent: "")
        sounds.target = self
        sounds.state = Settings.shared.soundsEnabled ? .on : .off
        menu.addItem(sounds)

        let wellness = NSMenuItem(
            title: "Wellness reminders",
            action: #selector(toggleWellness),
            keyEquivalent: "")
        wellness.target = self
        wellness.state = Settings.shared.wellnessEnabled ? .on : .off
        menu.addItem(wellness)

        let testReminders = NSMenuItem(
            title: "Test reminders",
            action: #selector(testReminders),
            keyEquivalent: "")
        testReminders.target = self
        menu.addItem(testReminders)

        let clear = NSMenuItem(
            title: "Clear finished/stale sessions",
            action: #selector(clearFinishedStale),
            keyEquivalent: "k")
        clear.target = self
        menu.addItem(clear)

        let quit = NSMenuItem(
            title: "Quit Zen-Copilot",
            action: #selector(quit),
            keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func menuTitle(for session: Session) -> String {
        "\(session.project) — \(session.status.rawValue) — \(session.relativeUpdated)"
    }

    /// Small colored dot rendered as an NSImage for the menu item.
    private func dotImage(for status: SessionStatus) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        nsColor(for: status).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func nsColor(for status: SessionStatus) -> NSColor {
        switch status {
        case .idle: return .systemGray
        case .working: return .systemGreen
        case .waiting: return .systemOrange
        case .done: return .systemBlue
        case .error: return .systemRed
        }
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        let index = sender.tag
        guard store.sessions.indices.contains(index) else { return }
        FocusController.focus(session: store.sessions[index])
    }

    @objc private func toggleOverlay() {
        guard let notchController else { return }
        notchController.setOverlayHidden(!notchController.isOverlayHidden)
    }

    @objc private func toggleSounds() {
        Settings.shared.soundsEnabled.toggle()
    }

    @objc private func toggleWellness() {
        Settings.shared.wellnessEnabled.toggle()
    }

    @objc private func testReminders() {
        wellnessController?.testAll()
    }

    @objc private func clearFinishedStale() {
        store.clearFinishedAndStale()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
