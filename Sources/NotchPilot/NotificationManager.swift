import AppKit
import Foundation
import UserNotifications

/// Posts local notifications on session status transitions (done / waiting).
@MainActor
final class NotificationManager {
    private var authorized = false

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                NSLog("NotchPilot: notification auth error: \(error)")
            }
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Called by SessionStore on every detected transition. Only fires on the
    /// transition into `done`/`waiting`, never on every refresh.
    func handleTransition(session: Session, from: SessionStatus?, to: SessionStatus) {
        // Skip the very first observation (from == nil) so we don't spam on launch
        // for sessions that already exist — except a fresh waiting/done is worth it
        // only if it just changed. We treat nil->X as "already in that state", no fire.
        guard from != nil else { return }
        guard from != to else { return }

        switch to {
        case .done:
            post(title: "✅ \(session.project) finished",
                 body: session.statusDetail ?? "Turn complete.")
            playSound(named: "Glass")
        case .waiting:
            post(title: "⏳ \(session.project) needs you",
                 body: session.statusDetail ?? "Waiting for your input.")
            playSound(named: "Submarine")
        default:
            break
        }
    }

    /// Posts a wellness reminder banner (stretch / water / eyes / posture).
    /// Reuses the same auth-gated builder as session notifications, with a
    /// gentle audio cue so the nudge is noticeable but not jarring.
    func postReminder(title: String, body: String) {
        post(title: title, body: body)
        playSound(named: "Tink")
    }

    /// Plays a stock macOS system sound (from /System/Library/Sounds) as a
    /// subtle audio cue. No-op if disabled or if the sound can't be loaded.
    private func playSound(named name: String) {
        // Read at call time so a menu toggle takes effect immediately.
        guard Settings.shared.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Silent banner — the distinct NSSound cue (Glass/Submarine) is the audio,
        // so we don't double up with the generic system notification sound.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
