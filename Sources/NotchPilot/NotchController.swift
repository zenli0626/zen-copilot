import Foundation
import SwiftUI
import Combine
import DynamicNotchKit

/// Shared interaction state bridging `NotchView` and `NotchController`.
///
/// `NotchView` flips `isReplying` while an inline reply field is open; the
/// controller observes it and treats it like an attention flash so the notch
/// stays `.expanded` (and doesn't collapse to compact when the pointer leaves)
/// for as long as the user is typing a reply.
@MainActor
final class NotchInteraction: ObservableObject {
    @Published var isReplying = false
}

/// Read/unread state for the compact pet's notification badge.
///
/// The compact pet shows an ambient badge when sessions are waiting/done. Without
/// a "read" concept the count never clears. `NotchController` owns one of these,
/// computes how many waiting/done items are *unread* (not yet seen by the user),
/// and marks everything seen when the user opens (expands) the notch. `CompactGlyph`
/// observes it and shows the badge only while `unreadCount > 0`.
@MainActor
final class NotchInbox: ObservableObject {
    /// Number of currently-waiting/done sessions the user hasn't seen yet.
    @Published var unreadCount = 0
    /// Badge tint for the unread items (amber if any unread is waiting, else teal).
    @Published var tint: Color = .cl.amber
    /// Whether a wellness reminder is firing right now (self-clears in ~8s). Shown
    /// alongside / folded into the unread badge so a live nudge still surfaces.
    @Published var wellnessActive = false
}

/// Owns the DynamicNotchKit panel and drives its expand/compact/hide lifecycle.
///
/// Behavior:
/// - Expands automatically when any session is `waiting` or `done` (something
///   that wants the human's attention).
/// - Otherwise compacts (notch displays) / hides (floating displays, which have
///   no compact mode — DynamicNotchKit auto-hides compact there).
/// - The compact glyph reflects whether anything needs attention.
///
/// On screens without a physical notch, `.auto` style resolves to `.floating`,
/// giving us the minimal floating-panel fallback for free.
@MainActor
final class NotchController {
    private let store: SessionStore
    /// Shared wellness state — when a reminder fires (`active != nil`) the notch
    /// pops open so the header pet can act the cue out (unless manually hidden).
    private let wellness: WellnessState
    private var notch: DynamicNotch<NotchView, CompactGlyph, CompactCount>?
    private var cancellables = Set<AnyCancellable>()

    /// Shared with the `NotchView` so an open inline reply field pins the notch
    /// open. Owned here so both the view and `refresh()` see the same instance.
    private let interaction = NotchInteraction()

    /// Drives the compact pet's notification badge from *unread* attention items
    /// (see `recomputeInbox` / `markCurrentAttentionSeen`). Injected into `CompactGlyph`.
    private let inbox = NotchInbox()

    /// Attention items the user has already SEEN. Each waiting/done session is
    /// keyed by `"\(id):\(status.rawValue)"`, so a session going working→waiting
    /// (or re-entering done) produces a *new* key and re-notifies. Pruned to live
    /// session ids in `recomputeInbox` so it can't grow unbounded and a reused id
    /// re-notifies cleanly.
    private var seenAttentionKeys: Set<String> = []

    /// The three display states the notch can resolve to.
    private enum Display { case hidden, compact, expanded }

    /// What we last told the notch to do (for dedup). The notch itself starts hidden.
    private var applied: Display = .hidden

    /// True while the pointer is over the notch panel — drives hover-to-expand
    /// so the clickable session list is reachable even when nothing needs attention.
    private var isHovering = false

    /// User-controlled close toggle (driven from the menu bar). When true the
    /// notch overlay is fully hidden regardless of session state; the menu-bar
    /// item stays as the always-on indicator.
    private(set) var isOverlayHidden = false

    /// How long the notch stays expanded after a *new* attention event before it
    /// settles back to the compact glyph. Expansion is transient, not sticky — a
    /// session that merely *remains* waiting/done does not keep it pinned open.
    private let attentionFlash: TimeInterval = 6

    /// Last seen status per session id, to detect new transitions into waiting/done.
    private var lastStatuses: [String: SessionStatus] = [:]

    /// While `now < expandUntil` a recent attention event keeps the notch expanded.
    private var expandUntil: Date?
    private var collapseTimer: Timer?

    init(store: SessionStore, wellness: WellnessState) {
        self.store = store
        self.wellness = wellness
    }

    /// Hide or restore the notch overlay on demand (menu-bar "Hide/Show notch
    /// overlay"). While hidden, session changes are ignored until restored.
    func setOverlayHidden(_ hidden: Bool) {
        guard hidden != isOverlayHidden else { return }
        isOverlayHidden = hidden
        refresh()
    }

    func start() {
        let store = self.store
        let interaction = self.interaction
        let wellness = self.wellness
        let inbox = self.inbox
        let notch = DynamicNotch(
            hoverBehavior: .all,
            style: .auto,
            expanded: {
                NotchView(store: store, interaction: interaction, wellness: wellness) { session in
                    FocusController.focus(session: session)
                }
            },
            compactLeading: { CompactGlyph(store: store, wellness: wellness, inbox: inbox) },
            compactTrailing: { CompactCount(store: store) }
        )
        self.notch = notch

        // Re-resolve display state whenever sessions change. A *new* attention
        // event opens a brief flash window; steady-state waiting/done does not.
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.noteTransitions(in: sessions)
                self?.recomputeInbox()
                self?.refresh()
            }
            .store(in: &cancellables)

        // …or when the pointer enters/leaves the notch (hover-to-expand).
        notch.$isHovering
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering in
                guard let self else { return }
                self.isHovering = hovering
                // Defeat the "first mouse" problem. The notch window is a
                // non-activating NSPanel (`canBecomeKey == true`): when it
                // isn't already key, the first mouse-down is consumed just to
                // make it key and never reaches the SwiftUI control — so the
                // user has to click a session row twice to switch tabs. Pre-
                // making the panel key the moment the pointer enters means it's
                // already key by click time, so the first click hits the row.
                // `makeKey()` (not `makeKeyAndOrderFront`, not app activation)
                // keeps the panel non-activating, so the terminal stays the
                // frontmost app and keeps focus.
                if hovering {
                    self.notch?.windowController?.window?.makeKey()
                }
                self.refresh()
            }
            .store(in: &cancellables)

        // …or when an inline reply field opens/closes, so the notch pins open
        // while typing and is free to collapse again once the field dismisses.
        interaction.$isReplying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // …or when a wellness reminder fires/clears, so the notch pops open to
        // let the header pet act the cue out, then settles when it auto-clears.
        wellness.$active
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeInbox()
                self?.refresh()
            }
            .store(in: &cancellables)

        recomputeInbox()
        refresh()
    }

    /// Detect sessions that *just* transitioned into waiting/done and open a
    /// short flash window so the notch pops out once per new event, then settles.
    private func noteTransitions(in sessions: [Session]) {
        var sawNewAttention = false
        for session in sessions {
            let previous = lastStatuses[session.id]
            if previous != session.status,
               session.status == .waiting || session.status == .done {
                sawNewAttention = true
            }
            lastStatuses[session.id] = session.status
        }
        let live = Set(sessions.map(\.id))
        lastStatuses = lastStatuses.filter { live.contains($0.key) }

        if sawNewAttention {
            expandUntil = Date().addingTimeInterval(attentionFlash)
            scheduleCollapse(after: attentionFlash)
        }
    }

    /// Stable key for an attention (waiting/done) session. Changes whenever the
    /// session enters a *new* attention status, so working→waiting or
    /// working→done produces a fresh, unread key even for the same session id.
    private func attentionKey(_ session: Session) -> String {
        "\(session.id):\(session.status.rawValue)"
    }

    /// Current waiting/done keys across all live sessions.
    private func currentAttentionKeys() -> [String] {
        store.sessions
            .filter { $0.status == .waiting || $0.status == .done }
            .map(attentionKey)
    }

    /// Recompute the unread badge state and prune the seen set to live ids.
    ///
    /// UNREAD = current waiting/done sessions whose key isn't yet in `seenAttentionKeys`.
    /// The seen set is pruned to keys belonging to currently-attention sessions so it
    /// can't grow without bound and a reused id (or a session that left + re-entered
    /// attention) re-notifies. The badge tint follows the most-urgent *unread* item.
    private func recomputeInbox() {
        let currentKeys = currentAttentionKeys()
        let currentSet = Set(currentKeys)
        // Drop seen keys that no longer correspond to a live attention item.
        seenAttentionKeys.formIntersection(currentSet)

        let unreadSessions = store.sessions.filter {
            ($0.status == .waiting || $0.status == .done)
                && !seenAttentionKeys.contains(attentionKey($0))
        }
        inbox.unreadCount = unreadSessions.count
        inbox.wellnessActive = wellness.active != nil
        if unreadSessions.contains(where: { $0.status == .waiting }) {
            inbox.tint = .cl.amber
        } else if unreadSessions.contains(where: { $0.status == .done }) {
            inbox.tint = .cl.teal
        } else {
            // No unread sessions — fall back to the wellness coral if one is firing.
            inbox.tint = .cl.coral
        }
    }

    /// Mark every current waiting/done item as SEEN (called when the user opens
    /// the notch). Drives `unreadCount` to 0 until a *new* attention event arrives.
    private func markCurrentAttentionSeen() {
        seenAttentionKeys.formUnion(currentAttentionKeys())
        recomputeInbox()
    }

    /// Re-evaluate the display once the flash window elapses, so it collapses on
    /// its own even if no further session events arrive.
    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseTimer?.invalidate()
        let timer = Timer(timeInterval: seconds + 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        collapseTimer = timer
    }

    /// Resolve the desired display state from current inputs and apply it.
    /// Priority: a manual hide wins; otherwise an open reply field or an active
    /// hover expands; otherwise the compact glyph (the resting state). The notch
    /// deliberately does NOT auto-expand on a new waiting/done event or a firing
    /// wellness reminder — that would block the user's screen. Instead the
    /// compact pet shows an ambient notification badge (see `CompactGlyph`) and
    /// the user hovers to open the panel themselves. (`noteTransitions` /
    /// `expandUntil` / the `wellness.$active` sink may still fire `refresh()`,
    /// but they no longer drive expansion.) All transitions are idempotent.
    private func refresh() {
        guard let notch else { return }

        let desired: Display
        if isOverlayHidden {
            desired = .hidden
        } else if interaction.isReplying || isHovering {
            // An open inline reply field pins the notch open, so it can't
            // collapse to compact mid-typing when the mouse leaves; an active
            // hover is the user's own request to open it.
            desired = .expanded
        } else {
            desired = .compact
        }

        // Opening (or being open) is the user *seeing* the attention items — clear
        // unread now so the badge disappears, and a later new waiting/done event
        // re-marks it unread. Done here (not gated on the applied transition) so a
        // new event arriving while already expanded is still marked seen.
        if desired == .expanded {
            markCurrentAttentionSeen()
        }

        guard desired != applied else { return }
        applied = desired
        switch desired {
        case .hidden:   Task { await notch.hide() }
        case .compact:  Task { await notch.compact() }
        case .expanded: Task { await notch.expand() }
        }
    }
}

/// Compact leading view: the brand's little pixel-art pet, tinted by the
/// highest-priority session status. Coral at rest (the mascot's calm brand
/// color); shifts to the alert tone when something needs attention.
struct CompactGlyph: View {
    @ObservedObject var store: SessionStore
    /// Live wellness cue — when active, the compact pet also performs it for the
    /// brief moment before `refresh()` pops the panel open (and after it settles).
    @ObservedObject var wellness: WellnessState
    /// Unread-attention state from the controller. Drives the badge's visibility
    /// and count, so the badge clears once the user opens the notch and only
    /// returns on a *new* waiting/done event.
    @ObservedObject var inbox: NotchInbox

    /// Body color, by status priority: waiting → amber, done → teal,
    /// working → green; otherwise coral (idle/calm = the brand mascot color).
    private var tint: Color {
        if store.sessions.contains(where: { $0.status == .waiting }) { return .cl.amber }
        if store.sessions.contains(where: { $0.status == .done }) { return .cl.teal }
        if store.sessions.contains(where: { $0.status == .working }) { return .cl.success }
        return .cl.coral
    }

    /// How many *unread* attention items to surface on the badge: unread
    /// waiting/done sessions, plus a firing wellness reminder (which self-clears
    /// in ~8s and isn't part of the seen/unread set, so it counts directly).
    private var badgeCount: Int {
        inbox.unreadCount + (inbox.wellnessActive ? 1 : 0)
    }

    /// Whether the ambient notification badge should be shown: only when there's
    /// something UNREAD (a new waiting/done item not yet seen) or a live wellness
    /// reminder. Opening the notch marks attention seen, so this drops to false
    /// until the next new event. The badge is the user's cue to hover and open
    /// the panel — the notch no longer pops open on its own.
    private var hasNotification: Bool {
        badgeCount > 0
    }

    /// Badge tint: follows the most-urgent unread item (amber waiting / teal done /
    /// coral wellness), computed in the controller. When only wellness is firing,
    /// `inbox.tint` is coral.
    private var badgeTint: Color {
        inbox.tint
    }

    var body: some View {
        // 10 rows × 2pt ≈ 20pt tall — sits nicely in the notch compact area.
        // Behavior is the live digital-pet mood derived from session state.
        PixelPet(tint: tint,
                 pixelSize: 2,
                 behavior: PetBehavior.from(sessions: store.sessions),
                 cue: wellness.active?.kind)
            // A small ambient "you have something to check" dot/bubble pinned to
            // the pet's upper-right. Overlaid (zero layout impact) and nudged
            // outward so it reads as a notification badge without clipping or
            // pushing the compact area wider. Hovering opens the full panel.
            .overlay(alignment: .topTrailing) {
                if hasNotification {
                    NotificationBadge(count: badgeCount, tint: badgeTint)
                        .alignmentGuide(.top) { $0[.top] - 1 }
                        .alignmentGuide(.trailing) { $0[.trailing] + 3 }
                }
            }
    }
}

/// Subtle notification indicator for the compact pet: a tiny rounded bubble in
/// an urgency tint, with a small count when more than one thing needs checking.
/// Gently pops in (scale + opacity) when it appears; otherwise it's static so it
/// never distracts — the macOS notification is the real alert.
private struct NotificationBadge: View {
    let count: Int
    let tint: Color

    /// ~9pt bubble — large enough to read as a badge, small enough to sit beside
    /// the ~20pt pet in the notch compact strip without crowding it.
    private let size: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: size, height: size)
                // A hairline dark ring lifts the bubble off the pet/notch so it
                // stays legible against any body tint.
                .overlay(Circle().strokeBorder(Color.cl.surfaceDark, lineWidth: 0.5))
                .shadow(color: tint.opacity(0.5), radius: 1.5)

            // Tiny count only when it adds information (>1 thing to check).
            if count > 1 {
                Text("\(min(count, 9))")
                    .font(.system(size: 6, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cl.onDark)
            }
        }
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: count)
    }
}

/// Compact trailing view: active session count, tinted by the highest-priority
/// status so the resting glyph still conveys state at a glance.
struct CompactCount: View {
    @ObservedObject var store: SessionStore

    private var tint: Color {
        if store.sessions.contains(where: { $0.status == .waiting }) { return .orange }
        if store.sessions.contains(where: { $0.status == .done }) { return .blue }
        if store.sessions.contains(where: { $0.status == .working }) { return .green }
        return .white
    }

    var body: some View {
        Text("\(store.sessions.count)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
    }
}
