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
        let notch = DynamicNotch(
            hoverBehavior: .all,
            style: .auto,
            expanded: {
                NotchView(store: store, interaction: interaction, wellness: wellness) { session in
                    FocusController.focus(session: session)
                }
            },
            compactLeading: { CompactGlyph(store: store, wellness: wellness) },
            compactTrailing: { CompactCount(store: store) }
        )
        self.notch = notch

        // Re-resolve display state whenever sessions change. A *new* attention
        // event opens a brief flash window; steady-state waiting/done does not.
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.noteTransitions(in: sessions)
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
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

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
    /// Priority: a manual hide wins; otherwise a recent attention flash or an
    /// active hover expands; otherwise the compact glyph. The glyph stays color-
    /// coded so state is still visible at rest. All transitions are idempotent.
    private func refresh() {
        guard let notch else { return }

        let attentionActive = expandUntil.map { $0 > Date() } ?? false
        // A firing wellness reminder pops the notch open so the pet can act it
        // out — but a manual hide still wins (checked first below).
        let wellnessActive = wellness.active != nil

        let desired: Display
        if isOverlayHidden {
            desired = .hidden
        } else if interaction.isReplying || attentionActive || isHovering || wellnessActive {
            // An open inline reply field pins the notch open (like attention),
            // so it can't collapse to compact mid-typing when the mouse leaves.
            // A live wellness cue does the same for its ~8s display window.
            desired = .expanded
        } else {
            desired = .compact
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

    /// Body color, by status priority: waiting → amber, done → teal,
    /// working → green; otherwise coral (idle/calm = the brand mascot color).
    private var tint: Color {
        if store.sessions.contains(where: { $0.status == .waiting }) { return .cl.amber }
        if store.sessions.contains(where: { $0.status == .done }) { return .cl.teal }
        if store.sessions.contains(where: { $0.status == .working }) { return .cl.success }
        return .cl.coral
    }

    var body: some View {
        // 10 rows × 2pt ≈ 20pt tall — sits nicely in the notch compact area.
        // Behavior is the live digital-pet mood derived from session state.
        PixelPet(tint: tint,
                 pixelSize: 2,
                 behavior: PetBehavior.from(sessions: store.sessions),
                 cue: wellness.active?.kind)
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
