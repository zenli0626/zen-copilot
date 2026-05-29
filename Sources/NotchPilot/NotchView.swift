import SwiftUI
import AppKit

/// The expanded content shown below the notch: a clean, dark, color-coded list
/// of sessions. Each row is clickable — tapping it fronts that session's
/// terminal tab so you can reply directly.
struct NotchView: View {
    @ObservedObject var store: SessionStore
    /// Shared with `NotchController`: flipping `isReplying` pins the notch open
    /// while an inline reply field is showing so it can't collapse mid-typing.
    @ObservedObject var interaction: NotchInteraction
    /// Live wellness cue. When `active != nil` the header pet performs the matching
    /// cue and a speech bubble shows its caption for the reminder's display window.
    @ObservedObject var wellness: WellnessState
    /// Per-row read state: drives the leading attention dot (shown only while a
    /// waiting/done row is UNREAD) and is cleared per-row when the user dives in or
    /// opens a reply. Owned by `NotchController`.
    @ObservedObject var readState: AttentionReadState
    var onSelect: (Session) -> Void

    /// The session whose inline reply field is currently open, if any. Only one
    /// reply field is open at a time. Toggled by a row's ↩ button.
    @State private var replyingTo: Session.ID?
    /// Drives keyboard focus into the inline field once it appears.
    @FocusState private var replyFocused: Bool
    /// Cached "what you're replying to" context, computed ONCE when the reply box
    /// opens (in `toggleReply`) — NOT on every render, since deriving it reads the
    /// transcript file off disk. Shown muted above the composer. Falls back to the
    /// session's `statusDetail` when the transcript yields nothing.
    @State private var replyContext: String?
    /// Measured natural height of the session list, so the surrounding ScrollView
    /// can hug content when short and cap+scroll only when it would overflow the
    /// screen. 0 until the first measurement lands.
    @State private var listContentHeight: CGFloat = 0

    // MARK: - Stroll ("the pet goes for a walk") state

    /// Current phase of the rare "stroll" treat. `.docked` is the resting state
    /// (pet sits in the header). The other phases drive the overlay pet across the
    /// panel and back. See `startStroll` / `endStroll`.
    @State private var strollPhase: StrollPhase = .docked
    /// Horizontal offset (points) of the overlay pet from its docked x-position.
    /// Animated edge-to-edge during a stroll; 0 when docked.
    @State private var strollX: CGFloat = 0
    /// Repeating scheduler that occasionally kicks off a stroll. Recreated with a
    /// randomized interval after each fire for personality. Invalidated on disappear.
    @State private var strollTimer: Timer?
    /// Pending work items (the phase transitions) so we can cancel them cleanly if
    /// the stroll is aborted mid-walk (e.g. behavior leaves `.calm`).
    @State private var strollWork: [DispatchWorkItem] = []

    /// Phases of a stroll round-trip.
    private enum StrollPhase: Equatable {
        case docked       // resting in the header (no overlay)
        case walkingOut   // walking toward the far (right) edge
        case pausing      // brief pause at the far edge
        case walkingBack  // walking back toward the dock
    }

    /// True while the overlay pet is out on its walk (any non-docked phase). While
    /// true the docked header pet is hidden so there's only ever one pet visible.
    private var isStrolling: Bool { strollPhase != .docked }

    /// The pet's facing direction for the current phase, fed to `PixelPet`.
    private var strollFacing: WalkFacing {
        switch strollPhase {
        case .walkingOut: return .right
        case .walkingBack: return .left
        case .pausing, .docked: return .none
        }
    }

    /// Geometry for the traverse. The docked pet renders at pixelSize 1.5 → 13
    /// cells ≈ 19.5pt wide; it lives at the leading edge of the header (after the
    /// horizontal panel padding). We walk it from x=0 (dock) to the far edge minus
    /// its width and the trailing padding, along the header band.
    private let strollPetWidth: CGFloat = 13 * 1.5
    /// One-way traverse duration (seconds). A few seconds, easeInOut, per the brief.
    private let strollLeg: TimeInterval = 3.2
    /// Pause at the far edge before heading back.
    private let strollPause: TimeInterval = 0.9

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // Header: coral pixel-pet mascot + serif wordmark + per-status dots,
            // with a hairline divider underneath for clean separation.
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    // Greet the user with the little mascot when the notch opens.
                    // pixelSize 1.5 → 13×10 grid renders ~19.5×15pt, sitting
                    // nicely beside the 15pt serif wordmark. Alive: it reacts to
                    // session state and hops when tapped (PixelPet's own
                    // .onTapGesture). `phase: 1.3` de-syncs it from the compact
                    // notch pet so the two aren't in lockstep.
                    // Header pet stays in its normal session-driven mood — the big
                    // reminder BANNER below is now the star that acts out wellness
                    // cues, so the header pet no longer needs the `cue:`.
                    PixelPet(tint: .cl.coral,
                             pixelSize: 1.5,
                             behavior: PetBehavior.from(sessions: store.sessions),
                             phase: 1.3)
                        // While the pet is off strolling across the panel (the
                        // overlay below), hide the docked one so there's only ever
                        // ONE pet on screen. It reappears the instant it re-docks.
                        .opacity(isStrolling ? 0 : 1)
                    Text("Zen-Copilot")
                        .font(Theme.serif(15))
                        .foregroundStyle(Color.cl.onDark)
                    Spacer()
                    statusSummary
                }

                Rectangle()
                    .fill(Color.cl.hairline)
                    .frame(height: 1)
            }

            // WELLNESS REMINDER BANNER — when a cue is active, a large pet front
            // and center ACTS OUT the cue (stretch / drink / look away / sit up)
            // beside a clean one-line title. Sits above the session rows so it's
            // the focus; fades in/out with `wellness.active`.
            if wellness.active != nil {
                reminderBanner
            }

            if store.sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cl.onDarkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.sm)
            } else {
                // The session list scrolls INTERNALLY once it would exceed the
                // usable screen height. Without this cap the panel grows with the
                // session count and DynamicNotchKit sizes the panel to content, so
                // 6+ sessions push the bottom rows off the screen edge (the same
                // class of bug as the reply pane). `maxListHeight` leaves room for
                // the header + reminder banner + paddings.
                ScrollView(.vertical, showsIndicators: true) {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            ForEach(store.sessions) { session in
                                SessionRow(
                                    session: session,
                                    isReplying: replyingTo == session.id,
                                    // Compact the OTHER rows while a reply is open on one of
                                    // them — keeps focus on the replied-to session.
                                    dimmed: replyingTo != nil && replyingTo != session.id,
                                    replyContext: replyingTo == session.id ? replyContext : nil,
                                    // The dot shows only while this row's attention is unread;
                                    // diving in or replying (below) clears it.
                                    isUnread: readState.isUnread(session),
                                    // When two live sessions share a project name (e.g. two
                                    // worktrees of the same repo), the row shows a location
                                    // subtitle (path · branch · tab) so they're tellable apart.
                                    nameClash: clashingDisplayNames.contains(Settings.shared.displayName(for: session)),
                                    replyFocused: $replyFocused,
                                    onReply: { toggleReply(for: session) },
                                    onSubmitReply: { text in submitReply(text, to: session) },
                                    onCancelReply: { dismissReply() },
                                    onJump: {
                                        readState.markRead(session)
                                        onSelect(session)
                                    }
                                )
                                    .id(session.id)
                                    .contentShape(Rectangle())
                                    // Don't front the terminal (or show the row menu) for taps in
                                    // an OPEN reply card's chrome — that would steal focus and
                                    // drop the in-progress reply. The ⋯ button still gives actions.
                                    .onTapGesture { if replyingTo != session.id { onSelect(session) } }
                                    .contextMenu { if replyingTo != session.id { zcRowActions(session) } }
                            }
                        }
                        // Measure the list's natural height so the ScrollView can size to
                        // content when short and cap+scroll only when it would overflow.
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: SessionListHeightKey.self, value: proxy.size.height)
                            }
                        )
                        // When a reply opens, scroll its row (with the tall composer)
                        // into view so the focused field is never below the fold.
                        .onChange(of: replyingTo) { _, newValue in
                            if let id = newValue {
                                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
                // Content-sized up to the screen cap; scrolls internally beyond it.
                // Before the first measurement lands, fall back to the cap so it
                // never renders collapsed.
                .frame(height: listContentHeight > 0 ? min(listContentHeight, maxListHeight) : maxListHeight)
                .onPreferenceChange(SessionListHeightKey.self) { h in
                    guard abs(h - listContentHeight) > 0.5 else { return }
                    DispatchQueue.main.async { listContentHeight = h }
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        // Widen the panel while a reply is open so Claude's message wraps onto
        // fewer lines and far more of it is visible at once. DynamicNotchKit
        // resizes the panel to the content, so changing the frame width suffices.
        .frame(width: replyingTo != nil ? 520 : restingPanelWidth)
        // Paint our own warm Claude product-chrome surface so the panel reads as
        // #181715 (not pure black) regardless of DynamicNotchKit's backing.
        .background(Color.cl.surfaceDark)
        .animation(.easeInOut(duration: 0.18), value: replyingTo)
        // Gentle fade/scale of the speech bubble as cues come and go.
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: wellness.active)
        .foregroundStyle(Color.cl.onDark)
        // The STROLL overlay: the same coral pet, drawn ON TOP of the panel along
        // the header band, so it can traverse the full width without disturbing the
        // row layout below. Hidden (and not laid into the dock) unless walking.
        .overlay(alignment: .topLeading) { strollOverlay }
        // Schedule strolls while the expanded panel is on screen; tear down on exit.
        .onAppear { scheduleNextStroll() }
        .onDisappear { teardownStroll() }
        // A session event that changes the mood mid-walk: if we leave `.calm`, the
        // pet should abort the stroll and re-dock so it can show the new state.
        .onChange(of: PetBehavior.from(sessions: store.sessions)) { _, newBehavior in
            if newBehavior != .calm && isStrolling { abortStroll() }
        }
    }

    // MARK: - Stroll overlay + scheduling

    /// The strolling pet, positioned along the header band and offset horizontally
    /// by `strollX` (animated edge-to-edge). Only present while actually walking.
    @ViewBuilder private var strollOverlay: some View {
        if isStrolling {
            PixelPet(tint: .cl.coral,
                     pixelSize: 1.5,
                     // Stays calm-mooded while walking; the walk gait + facing
                     // are what animate it. (We only ever stroll while calm.)
                     behavior: .calm,
                     phase: 1.3,
                     facing: strollFacing)
                // Sit on the same baseline as the docked header pet: leading +
                // top padding of the panel, then slide by the animated offset.
                .padding(.leading, Theme.Space.lg)
                .padding(.top, Theme.Space.md)
                .offset(x: strollX)
                .allowsHitTesting(false)
        }
    }

    /// Arm the next stroll on a randomized ~60–120s interval (Timer is fine here).
    /// Only one timer outstanding at a time.
    private func scheduleNextStroll() {
        strollTimer?.invalidate()
        let interval = Double.random(in: 60...120)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            // Hop back to the main actor to touch view state / start the walk.
            Task { @MainActor in
                startStrollIfAppropriate()
                scheduleNextStroll()   // re-arm with a fresh randomized interval
            }
        }
        strollTimer = timer
    }

    /// Begin a stroll only if it makes sense: the pet is docked (not mid-walk),
    /// there's no reply field open (panel is at its normal width), and the mood is
    /// `.calm` (don't wander off during alert/working/error/etc.).
    private func startStrollIfAppropriate() {
        guard strollPhase == .docked,
              replyingTo == nil,
              PetBehavior.from(sessions: store.sessions) == .calm else { return }
        startStroll()
    }

    /// Run one round-trip: walk out to the far edge, pause, walk back, re-dock.
    /// Each leg eases in/out; the phase transitions are scheduled as cancelable
    /// work items so `abortStroll` can interrupt cleanly.
    private func startStroll() {
        cancelStrollWork()

        // Far-edge target: panel width minus both horizontal paddings and the
        // pet's own width, so it stops flush at the inner right edge.
        let travel = max(0, restingPanelWidth - Theme.Space.lg * 2 - strollPetWidth)

        // Phase 1 — walk OUT (facing right).
        strollPhase = .walkingOut
        withAnimation(.easeInOut(duration: strollLeg)) { strollX = travel }

        // Phase 2 — pause at the far edge.
        let pause = DispatchWorkItem {
            strollPhase = .pausing
        }
        // Phase 3 — walk BACK (facing left).
        let back = DispatchWorkItem {
            strollPhase = .walkingBack
            withAnimation(.easeInOut(duration: strollLeg)) { strollX = 0 }
        }
        // Phase 4 — re-dock (show the header pet again).
        let dock = DispatchWorkItem {
            strollPhase = .docked
            strollX = 0
        }
        strollWork = [pause, back, dock]

        let q = DispatchQueue.main
        q.asyncAfter(deadline: .now() + strollLeg, execute: pause)
        q.asyncAfter(deadline: .now() + strollLeg + strollPause, execute: back)
        q.asyncAfter(deadline: .now() + strollLeg + strollPause + strollLeg, execute: dock)
    }

    /// Abort an in-progress stroll and snap-walk back to the dock quickly so the
    /// pet can show the new (non-calm) mood. Cancels the scheduled phase work.
    private func abortStroll() {
        cancelStrollWork()
        // Brief retreat to the dock, then restore the docked pet.
        strollPhase = .walkingBack
        withAnimation(.easeInOut(duration: 0.4)) { strollX = 0 }
        let dock = DispatchWorkItem {
            strollPhase = .docked
            strollX = 0
        }
        strollWork = [dock]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: dock)
    }

    /// Cancel any pending phase-transition work items.
    private func cancelStrollWork() {
        strollWork.forEach { $0.cancel() }
        strollWork.removeAll()
    }

    /// Stop scheduling and cancel everything when the panel goes away.
    private func teardownStroll() {
        strollTimer?.invalidate()
        strollTimer = nil
        cancelStrollWork()
        strollPhase = .docked
        strollX = 0
    }

    // MARK: - Inline reply coordination

    /// Toggle the inline reply field for `session`: open it (and pin the notch
    /// open + request focus) if closed, or dismiss it if it's already showing.
    private func toggleReply(for session: Session) {
        if replyingTo == session.id {
            dismissReply()
        } else {
            replyingTo = session.id
            interaction.isReplying = true
            // Opening a reply is "reading" this row — clear its attention dot.
            readState.markRead(session)
            // Compute the "what you're replying to" context ONCE, here, off the
            // render path — `lastAssistantSummary()` reads the transcript file from
            // disk. Fall back to `statusDetail` when the transcript yields nothing.
            replyContext = session.lastAssistantSummary() ?? session.statusDetail
            // Focus on the next runloop tick so the field exists first.
            DispatchQueue.main.async { replyFocused = true }
        }
    }

    /// Send the typed line via `InputController` (fronts the terminal + injects),
    /// then dismiss the field. No-ops on empty input but still dismisses.
    private func submitReply(_ text: String, to session: Session) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            InputController.send(trimmed, to: session)
        }
        dismissReply()
    }

    /// Close any open inline reply field and release the notch pin.
    private func dismissReply() {
        replyingTo = nil
        replyFocused = false
        replyContext = nil
        interaction.isReplying = false
    }

    /// Cap for the scrollable session list: most of the active screen height, less
    /// room for the notch, header, reminder banner, and paddings. Clamped so it's
    /// sane on both a short laptop screen and a tall external display. Beyond this
    /// the list scrolls internally instead of pushing rows off the screen edge.
    private var maxListHeight: CGFloat {
        // Size off the screen that owns the menu bar / physical notch (origin==.zero),
        // not whichever screen happens to be `.main`, so the cap is right on a
        // multi-monitor setup where the panel lives on the built-in display.
        let notchScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let screen = notchScreen?.visibleFrame.height ?? 800
        return min(max(screen - 260, 240), 760)
    }

    /// Single source of truth for the resting (non-reply) panel width, shared by the
    /// panel frame and the pet-stroll travel calc so they can't drift apart.
    private let restingPanelWidth: CGFloat = 400

    /// DISPLAY names shared by 2+ live sessions — the rows that need a location
    /// subtitle to be tellable apart (the "find this" case: duplicate names from
    /// worktrees / multiple checkouts, OR two sessions the user aliased the same).
    /// Counted by `displayName` (not raw project) so aliasing two siblings to the
    /// same name still flags the clash and keeps the path·tab subtitle visible.
    private var clashingDisplayNames: Set<String> {
        var counts: [String: Int] = [:]
        for s in store.sessions { counts[Settings.shared.displayName(for: s), default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    /// Per-status tallies for the non-empty statuses, sorted by `sortRank`
    /// (waiting, working, done, idle, error). Zero counts are dropped so the
    /// header only shows what's actually happening.
    private var statusCounts: [(status: SessionStatus, count: Int)] {
        Dictionary(grouping: store.sessions, by: \.status)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.sortRank < $1.0.sortRank }
    }

    /// Prominent wellness REMINDER BANNER shown above the session rows while a cue
    /// is active. A LARGE PixelPet (pixelSize 4.5 → ~45pt tall) acts out the cue
    /// front-and-center, beside a clean title line (the reminder's `title`, with a
    /// muted body/caption below). Claude-styled elevated surface, rounded, with a
    /// gentle fade/scale-in tied to `wellness.active`. The acting pet replaces the
    /// old tiny emoji speech bubble — the pet is the star.
    @ViewBuilder private var reminderBanner: some View {
        if let active = wellness.active {
            HStack(spacing: Theme.Space.md) {
                // The star: a big pet acting out the cue. Calm-mooded so the cue
                // animation reads cleanly without a competing session behavior.
                PixelPet(tint: .cl.coral,
                         pixelSize: 4.5,
                         behavior: .calm,
                         phase: 2.1,
                         cue: active.kind)
                    .frame(width: 13 * 4.5, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(active.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.cl.onDark)
                        .lineLimit(1)
                    Text(active.body)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cl.onDarkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Color.cl.surfaceDarkElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .strokeBorder(Color.cl.coral.opacity(0.35), lineWidth: 1)
                    )
            )
            .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            .accessibilityLabel("Wellness reminder: \(active.title)")
        }
    }

    /// Compact, color-coded aggregate that replaces the plain session count:
    /// a small status dot + tally per active status, e.g. "● 2  ● 1  ● 1".
    /// Reads at a glance as "what's happening across all sessions". Empty when
    /// there are no sessions (the body shows the "No active sessions" state).
    @ViewBuilder private var statusSummary: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(statusCounts, id: \.status) { entry in
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.status.color)
                        .frame(width: 6, height: 6)
                    Text("\(entry.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.cl.onDarkSoft)
                }
            }
        }
    }
}

/// A single, clickable session row. Status drives the color throughout: the
/// left accent bar (which breathes while working), the status badge, and the
/// hover highlight all use `status.color`. Shows the model and live turn time.
private struct SessionRow: View {
    let session: Session
    /// Whether this row's inline reply field is currently shown.
    let isReplying: Bool
    /// True when SOME OTHER row is being replied to — this row should collapse to
    /// a compact, de-emphasized one-liner so focus stays on the reply. Never true
    /// for the row that's actually being replied to.
    let dimmed: Bool
    /// Pre-computed "what you're replying to" summary (Claude's last message, or a
    /// `statusDetail` fallback), passed down from `NotchView` so it's derived ONCE
    /// when the box opens rather than on every render. Nil when not replying.
    let replyContext: String?
    /// Whether this row's attention is UNREAD — drives the leading dot. True only
    /// for a waiting/done session the user hasn't yet dived into or replied to;
    /// computed by `NotchView` from the shared `AttentionReadState`.
    let isUnread: Bool
    /// True when another live session shares this one's project name. Drives the
    /// location subtitle (path · tab) so duplicate-named sessions are tellable apart.
    let nameClash: Bool
    /// Shared focus binding owned by `NotchView` — drives keyboard focus into
    /// the inline field. Only one field exists at a time, so one binding is enough.
    @FocusState.Binding var replyFocused: Bool
    /// Toggles the inline reply field for this session. Kept as a SEPARATE
    /// control from the row tap (which fronts the terminal via `onSelect`).
    var onReply: () -> Void
    /// Submit the field contents (Enter) for this session.
    var onSubmitReply: (String) -> Void
    /// Cancel/dismiss the field (Esc, or toggling the ↩ button off).
    var onCancelReply: () -> Void
    /// Dive straight into this session: front its terminal tab. Same effect as a
    /// row tap (`onSelect`), surfaced as an explicit ↗ button so it's discoverable
    /// when you just want to jump in rather than type a reply.
    var onJump: () -> Void

    @State private var hovering = false
    /// Live text for this row's inline reply field.
    @State private var replyText = ""
    /// Measured (and ~5-line-capped) height of the multi-line composer, driven by
    /// `MultilineReplyField` so the SwiftUI layout — and the notch panel — grows
    /// with the message. Starts at one line.
    @State private var replyHeight: CGFloat = 20
    /// Measured natural height of the "↩ REPLYING TO" message `Text` (as it wraps
    /// at the reply width), reported by a `GeometryReader`-backed `PreferenceKey`.
    /// The reading pane is then sized to `min(this, contextMaxHeight)` so short
    /// messages stay compact and long ones cap + scroll internally. Starts at 0;
    /// while it's 0 we fall back to a sensible non-collapsed height.
    @State private var contextTextHeight: CGFloat = 0
    /// Cap for the REPLYING-TO reading pane; above this it scrolls internally.
    /// Kept deliberately SHORT: the panel has no overall height bound and
    /// DynamicNotchKit sizes it to its content, so a tall reading pane pushes the
    /// composer (which sits BELOW it) off the bottom of the screen — the user then
    /// "can't see it and can't reply". 180pt (~9 lines, internally scrollable for
    /// longer messages) guarantees the composer stays on screen.
    private let contextMaxHeight: CGFloat = 180
    /// Fallback height before the first measurement lands, so the pane never
    /// renders collapsed to ~2 lines on the first pass.
    private let contextFallbackHeight: CGFloat = 90

    private var color: Color { session.status.color }
    private var isWorking: Bool { session.status == .working }
    private var isWaiting: Bool { session.status == .waiting }
    /// Shown name: the user's alias (by cwd) or the project basename.
    private var displayName: String { Settings.shared.displayName(for: session) }

    var body: some View {
        // While a reply is open on ANOTHER row, this row collapses to a compact,
        // de-emphasized one-liner so focus stays on the reply. Otherwise (normal,
        // or this is the replied-to row) it renders the full detail + buttons.
        Group {
            if dimmed {
                compactRow
            } else {
                fullRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                // Hover highlight: lift the row onto the elevated surface so it
                // reads as a Claude card-on-hover (warm, not a status wash).
                .fill(Color.cl.surfaceDarkElevated.opacity(hovering ? 1.0 : 0.0))
        )
        .onHover { hovering = $0 }
    }

    /// Small, secondary status tag — same visual tier as the `ctx` meta, so it
    /// never crowds out the project name. Status-tinted uppercase micro-label on a
    /// faint fill; deliberately compact (8pt, tight padding). `fixedSize` keeps it a
    /// clean single-line pill, but its small footprint means the name wins the row.
    private var statusPill: some View {
        Text(session.status.rawValue)
            .font(.system(size: 8, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(color)
            // Single-line guard: the badge must NEVER wrap to one-letter-per-line
            // when the row's left column is compressed. `fixedSize` keeps it at its
            // natural single-line width so it stays a clean pill.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
    }

    /// Muted model label, e.g. "opus-4-8". Mono to read as code-ish.
    @ViewBuilder private var modelLabel: some View {
        if let model = session.modelShort {
            Text(model)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.cl.onDarkSoft)
                .lineLimit(1)
        }
    }

    /// Full row: project + badges, detail line / live timer, permission buttons,
    /// trailing reply button, and (when open) the inline reply composer.
    private var fullRow: some View {
        // Row content on top; when open, the reply composer drops to its own
        // FULL-WIDTH line below the whole row (not cramped in the trailing area).
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // Row 1 — main info line. The left column holds ONLY the
            // project+badge+model line and the detail line; it shares the row's
            // width with the trailing timestamp + reply button. The permission
            // buttons are deliberately NOT here — they'd inflate this column's
            // width demand and squeeze the top line (badge wrapping vertically).
            HStack(spacing: Theme.Space.md) {
                accentBar

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.sm) {
                        attentionDot

                        // The name now owns the entire title row — status + model
                        // moved down to `metaLine`, so the full name shows instead
                        // of truncating behind the WAITING badge. `displayName` is
                        // the user alias when set, else the project basename.
                        Text(displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.cl.onDark)
                            .lineLimit(1)
                    }

                    locationSubtitle
                    detailLine
                    metaLine
                }

                Spacer(minLength: Theme.Space.sm)

                Text(session.relativeUpdated)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.cl.onDarkSoft)

                jumpButton
                replyButton
                overflowMenu
            }

            // Row 2 — permission menu. Shown ONLY for a waiting row that is a REAL
            // permission request (`needsPermission == true`). A `.waiting` session
            // that's just idle / awaiting the user's next input (e.g. AUTO mode,
            // where tool permissions are auto-accepted so there's NO prompt — its
            // notification reads "Claude is waiting for your input") shows NO
            // Approve/Allow Once/Deny buttons; the reply (↩) affordance already
            // lets the user respond. On its OWN full-width line below the main row
            // so the content-sized buttons get the whole panel width.
            if isWaiting && session.needsPermission == true {
                permissionActions
            }

            // Inline reply composer — shown when this row's ↩ is toggled on.
            // Lives INSIDE the notch panel; no separate window. Full-width line
            // spanning the whole panel so a long message stays visible.
            if isReplying {
                replyField
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Theme.Space.md)
    }

    /// Compact one-liner shown for the NON-replying rows while a reply is open on
    /// another session: just the accent bar + project name + status badge (+ model
    /// badge). No detail line / timer, no permission buttons, no reply button.
    /// Slightly faded and tighter vertical padding so it reads as background.
    private var compactRow: some View {
        HStack(spacing: Theme.Space.md) {
            accentBar

            Text(displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cl.onDarkSoft)
                .lineLimit(1)

            statusPill

            // When names clash, keep the branch visible even on the dimmed/compact
            // row so the replied-to session and its sibling stay tellable apart.
            if nameClash, let branch = session.gitBranch, !branch.isEmpty {
                Text("⎇ \(branch)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.cl.onDarkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            modelLabel

            Spacer(minLength: Theme.Space.sm)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Theme.Space.md)
        // Fixed slim height so the accent bar's RoundedRectangle (which fills the
        // row height) stays short instead of stretching tall.
        .frame(height: 24)
        .opacity(0.7)
    }

    /// Color-coded left accent bar. While working it breathes (opacity pulse) so
    /// the row reads as "alive". TimelineView animates it independent of data updates.
    @ViewBuilder private var accentBar: some View {
        if isWorking {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 3))
                bar.opacity(pulse)
            }
        } else {
            bar
        }
    }

    private var bar: some View {
        // Thinner, softer status accent — a calm warm rail, not a neon glow.
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color.opacity(0.85))
            .frame(width: 2.5)
    }

    /// Labeled, color-coded permission menu (Vibe-Island style) for answering a
    /// numbered permission prompt straight from the notch. Claude Code's menu maps
    /// 1 = "Yes" (allow once), 2 = "Yes, and don't ask again" (approve/always),
    /// 3 = "No" (deny) — so each button injects that digit + Return into the
    /// session's terminal. Only shown on `.waiting` rows, on its own line below the
    /// detail. Real `Button`s, so taps are consumed and never fall through to the
    /// row's `onTapGesture` (click-to-focus).
    private var permissionActions: some View {
        // Claude action hierarchy: coral primary CTA + restrained secondaries.
        // Left-aligned, full-width line: each button is content-sized; a trailing
        // Spacer keeps the group anchored left and lets them breathe across the panel.
        HStack(spacing: Theme.Space.sm) {
            permissionButton("Approve", symbol: "checkmark.circle.fill", digit: "2", style: .primary)
            permissionButton("Allow Once", symbol: "checkmark", digit: "1", style: .secondary)
            permissionButton("Deny", symbol: "xmark", digit: "3", style: .danger)
            Spacer(minLength: 0)
        }
    }

    /// Visual weight of a permission button, mapping to Claude's button styles.
    private enum PermissionStyle { case primary, secondary, danger }

    /// One labeled button in the permission row. Tapping sends `digit` (+ Return)
    /// to the session, answering the menu directly.
    /// - `.primary` → coral fill, white text (the CTA).
    /// - `.secondary` → elevated-surface fill, onDark text.
    /// - `.danger` → subtle error-red outline + text.
    private func permissionButton(_ label: String, symbol: String, digit: String, style: PermissionStyle) -> some View {
        Button(action: { InputController.send(digit, to: session) }) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(permissionFG(style))
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 5)
            .background(permissionBG(style))
            .overlay(permissionBorder(style))
            // Size each button to its icon + single-line label so the text never
            // wraps per-character when the row's left column gets compressed.
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label) — send \(digit)")
    }

    private func permissionFG(_ style: PermissionStyle) -> Color {
        switch style {
        case .primary: return Color.cl.onDark
        case .secondary: return Color.cl.onDark
        case .danger: return Color.cl.error
        }
    }

    @ViewBuilder private func permissionBG(_ style: PermissionStyle) -> some View {
        switch style {
        case .primary:
            RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.cl.coral)
        case .secondary:
            RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.cl.surfaceDarkElevated)
        case .danger:
            RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.clear)
        }
    }

    @ViewBuilder private func permissionBorder(_ style: PermissionStyle) -> some View {
        switch style {
        case .danger:
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Color.cl.error.opacity(0.45), lineWidth: 1)
        case .primary, .secondary:
            EmptyView()
        }
    }

    /// Small status-tinted dot pinned to the LEFT of the project name on rows whose
    /// attention is UNREAD (waiting/done you haven't dived into or replied to yet).
    /// It's the at-a-glance "this one is new and wants you" signal that pairs with
    /// the ↗ dive-in button. Waiting dots gently pulse (actively blocked on you);
    /// done dots are steady. Once you engage the row the dot clears, so the column
    /// only lights up for what you still owe a look.
    @ViewBuilder private var attentionDot: some View {
        if isUnread {
            if isWaiting {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let pulse = 0.5 + 0.5 * (0.5 + 0.5 * sin(t * 3))
                    dotCircle.opacity(pulse)
                }
            } else {
                dotCircle
            }
        }
    }

    private var dotCircle: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 2)
    }

    /// Overflow "⋯" menu of per-row quick actions (copy last message / copy path /
    /// reveal in Finder / open folder / rename). A `Menu` consumes its own clicks so
    /// it won't trigger the row's tap-to-focus or the ↗/↩ buttons.
    private var overflowMenu: some View {
        Menu {
            zcRowActions(session)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.cl.coral : Color.cl.onDarkSoft)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// One-tap reply snippets above the composer (only while replying). Leads with
    /// yes/no when Claude's last message looks like a question. A snippet ending in
    /// "…" pre-fills the field (no send) so you can finish it; otherwise it sends
    /// immediately via the same proven injection path as Return.
    @ViewBuilder private var snippetBar: some View {
        let questionLike = (replyContext?.contains("?") == true)
        let chips = (questionLike ? ["yes", "no"] : []) + Settings.shared.replySnippets
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        Button {
                            if chip.hasSuffix("…") {
                                replyText = String(chip.dropLast()).trimmingCharacters(in: .whitespaces) + " "
                                replyFocused = true
                            } else {
                                onSubmitReply(chip)
                                replyText = ""
                            }
                        } label: {
                            Text(chip)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.cl.onDark)
                                .lineLimit(1)
                                .padding(.horizontal, Theme.Space.sm)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.cl.surfaceDarkSoft)
                                        .overlay(Capsule().strokeBorder(Color.cl.coral.opacity(0.4), lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Dive-in affordance: ↗ jumps straight into this session's terminal tab (same
    /// effect as tapping the row, surfaced explicitly so it's discoverable when you
    /// just want to switch in rather than reply). A real `Button` consumes its own
    /// click so it won't double-fire the row's `onTapGesture`. Lights coral on hover.
    private var jumpButton: some View {
        Button(action: onJump) {
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.cl.coral : Color.cl.onDarkSoft)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to \(session.project) in the terminal")
    }

    /// Reply affordance: toggles an INLINE text field inside the notch to inject a
    /// line into this session's terminal. A real `Button` consumes its own click, so
    /// it won't also trigger the row's `onTapGesture`. Status-tinted to match the row;
    /// stays lit while the field is open so it reads as an on/off toggle.
    private var replyButton: some View {
        Button(action: onReply) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 11, weight: .semibold))
                // Coral when active/hovered (the reply affordance is a primary
                // action); muted otherwise.
                .foregroundStyle(isReplying || hovering ? Color.cl.coral : Color.cl.onDarkSoft)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color.cl.coral.opacity(isReplying ? 0.20 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isReplying ? "Close reply" : "Reply to this session")
    }

    /// Inline, MULTI-LINE reply composer shown beneath the row's detail. Spans the
    /// full usable width of the panel so a long message stays fully visible: the
    /// text wraps and the box grows vertically as you type, up to ~5 lines, then
    /// scrolls internally. Styled to match the panel (dark fill, status-tinted
    /// border). Backed by an `NSTextView` (`MultilineReplyField`) so Return SENDS
    /// (Shift+Return inserts a newline) while still wrapping — a SwiftUI
    /// `TextField(axis: .vertical)` can't do Return-to-send. The field makes the
    /// host panel KEY on appear (the panel is non-activating but `canBecomeKey` is
    /// true) so keystrokes land, folding in the old `MakeKeyOnAppear` behavior.
    /// Muted "↩ REPLYING TO" context block shown ABOVE the composer so you can read
    /// and answer Claude's last message/question without opening the terminal. The
    /// uppercase label sits on its own line; below it the full message renders
    /// full-width and WRAPPING inside a vertical `ScrollView` capped at ~320pt
    /// (~18-20 lines) so a long excerpt (up to ~2000 chars) is largely readable
    /// at once; it sizes to content (short messages stay short) and only scrolls
    /// once content exceeds the cap, while the panel doesn't grow unbounded. The
    /// panel itself also widens to 520pt while replying so the message wraps onto
    /// fewer lines. `replyContext` is
    /// pre-computed in `NotchView` (off the render path); hidden entirely when
    /// there's nothing to show.
    @ViewBuilder private var replyContextLine: some View {
        if let ctx = replyContext, !ctx.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("↩ Replying to")
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(Color.cl.onDarkSoft)

                // A bare `ScrollView` with only a `maxHeight` collapses to a
                // minimal ideal height (≈2 lines) — it never expands to its
                // content. So we MEASURE the wrapped text's natural height with a
                // `GeometryReader` in `.background` + a `PreferenceKey`, report it
                // into `contextTextHeight`, and give the scroll container an
                // EXPLICIT height of `min(measured, cap)`: content-sized when
                // short, capped + internally scrollable when long.
                let measured = contextTextHeight > 0 ? contextTextHeight : contextFallbackHeight
                ScrollView(.vertical, showsIndicators: true) {
                    // Render the normalized summary as MARKDOWN so inline
                    // **bold** / *italic* / `code` style and newlines/paragraph
                    // breaks are preserved (`.inlineOnlyPreservingWhitespace`).
                    // Fall back to a plain Text if parsing fails.
                    replyContextText(ctx)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.cl.onDark.opacity(0.85))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ReplyContextHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                }
                .frame(height: min(measured, contextMaxHeight))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onPreferenceChange(ReplyContextHeightKey.self) { h in
                    // Push async so we never mutate `@State` during a view-update
                    // pass (same discipline as the input field's height report).
                    guard abs(h - contextTextHeight) > 0.5 else { return }
                    DispatchQueue.main.async { contextTextHeight = h }
                }
            }
        }
    }

    /// Build a `Text` from the reply summary, rendering inline markdown
    /// (**bold** / *italic* / `code`) while preserving the newlines and
    /// whitespace the normalizer kept. Falls back to plain text if the markdown
    /// parser returns nil.
    private func replyContextText(_ ctx: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: ctx,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(ctx)
    }

    private var replyField: some View {
        // Claude card: elevated warm surface, lg radius, generous padding.
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            replyContextLine

            snippetBar

            // The input area itself sits on the soft inset surface with a coral
            // focus ring (Claude's text-input-focused = coral).
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.cl.coral)
                    .padding(.top, 4)

                MultilineReplyField(
                    text: $replyText,
                    placeholder: "Reply to \(displayName)…",
                    caretColor: Color.cl.coral,
                    isFocused: $replyFocused,
                    onSend: {
                        onSubmitReply(replyText)
                        replyText = ""
                    },
                    onCancel: { onCancelReply() },
                    onHeightChange: { replyHeight = $0 }
                )
                .frame(height: replyHeight)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Color.cl.surfaceDarkSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Color.cl.coral.opacity(0.55), lineWidth: 1.5)
                    )
            )
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Color.cl.surfaceDarkElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Color.cl.hairline, lineWidth: 1)
                )
        )
        .padding(.top, Theme.Space.sm)
        // Reset stale text + height if the field is re-targeted / closed.
        .onChange(of: isReplying) { _, showing in
            if !showing {
                replyText = ""
                replyHeight = 20
            }
        }
    }

    /// Attributes line beneath the detail text: the small status tag, then muted
    /// mono hints — model (`opus-4-8`), context-window usage (`ctx 42%`), and total
    /// session lifetime (`2h14m`), joined with a middot — e.g.
    /// `[WAITING]  opus-4-8 · ctx 42% · 2h14m`. The status tag was MOVED here off the
    /// title row so the project name owns the full left column instead of being
    /// truncated behind the badge. The session time is a LIFETIME value (distinct
    /// from the live `running <turn>` in `detailLine`); it ticks once a second via
    /// `TimelineView` so it stays current. Monospaced digits keep it from jittering.
    @ViewBuilder private var metaLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let parts: [String] = [
                session.modelShort,
                session.contextPercent.map { "ctx \($0)%" },
                session.sessionElapsed(asOf: timeline.date),
            ].compactMap { $0 }
            HStack(spacing: Theme.Space.sm) {
                statusPill
                waitingBadge(asOf: timeline.date)
                branchChip
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.cl.onDarkSoft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// "Blocked for" badge — `⏱ 17m` — on waiting rows only, whose tint ESCALATES
    /// with the wait: neutral under 2m, amber past 2m, red past 10m, so a long-
    /// neglected session draws the eye. Reuses the meta line's 1s tick (no extra
    /// render cost) and hides on every non-waiting row.
    @ViewBuilder private func waitingBadge(asOf now: Date) -> some View {
        if let waited = session.waitElapsed(asOf: now) {
            let secs = session.waitSeconds(asOf: now) ?? 0
            let tint: Color = secs > 600 ? .cl.error : (secs > 120 ? .cl.amber : .cl.onDarkSoft)
            HStack(spacing: 2) {
                Image(systemName: "clock")
                    .font(.system(size: 8, weight: .semibold))
                Text(waited)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .fixedSize()
        }
    }

    /// Small git-branch chip on the meta line — `⎇ main`. The everyday "which
    /// checkout is this" signal and, with the location subtitle, the worktree
    /// disambiguator. Hidden for non-git dirs. Truncates tail-first so a long
    /// branch name never pushes the model/ctx/uptime off the line.
    @ViewBuilder private var branchChip: some View {
        if let branch = session.gitBranch, !branch.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                Text(branch)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Linked-worktree tag — instantly flags which row is a worktree vs
                // the main checkout when names collide.
                if session.isWorktree == true {
                    Text("WT")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(Color.cl.teal)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Color.cl.teal.opacity(0.16), in: Capsule())
                }
            }
            .foregroundStyle(Color.cl.onDarkSoft)
            .layoutPriority(0.5)
        }
    }

    /// Location subtitle shown ONLY when another live session shares this project
    /// name (the "find this" case). Home-abbreviated path + a guaranteed-unique tab
    /// tag, middle-truncated so the head and the project tail both stay visible —
    /// so two `beyond-young-academy` rows read as e.g. `~/BY-Website · ttys003`
    /// vs `~/worktrees/by-notch · ttys007`. Normal (non-clashing) rows stay compact.
    @ViewBuilder private var locationSubtitle: some View {
        if nameClash, let loc = locationText {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 8))
                Text(loc)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.cl.onDarkSoft)
        }
    }

    /// The disambiguating location string: home-abbreviated cwd + the tab tag,
    /// each included only when known. Nil when neither is available.
    private var locationText: String? {
        let parts = [session.cwdHome, session.ttyShort].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// statusDetail, with a live "· running 2m14s" appended while working.
    @ViewBuilder private var detailLine: some View {
        let detail = session.statusDetail ?? ""
        if isWorking {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let elapsed = session.turnElapsed(asOf: timeline.date)
                Text(detail.isEmpty
                     ? (elapsed.map { "running \($0)" } ?? "")
                     : (elapsed.map { "\(detail) · running \($0)" } ?? detail))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cl.onDarkSoft)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !detail.isEmpty {
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.cl.onDarkSoft)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Multi-line reply composer

/// Full-width, multi-line reply input backed by an `NSTextView` inside an
/// `NSScrollView`. Wraps text and grows vertically with content up to a ~5-line
/// cap (`maxLines`), after which it scrolls internally so the box never pushes the
/// notch panel arbitrarily tall.
///
/// Key bindings (handled in `Coordinator.textView(_:doCommandBy:)`):
/// - **Return** (no modifier) → SEND: calls `onSend` (which submits via
///   `InputController` and clears the field). We return `true` to swallow the
///   newline so it isn't inserted.
/// - **Shift+Return** → inserts a literal newline (`insertNewlineIgnoringFieldEditor`).
/// - **Esc** (`cancelOperation:`) → `onCancel` (dismiss).
///
/// We can't tell Shift+Return apart from plain Return purely from the
/// `doCommandBy:` selector, so we read `NSApp.currentEvent`'s modifier flags at
/// the moment the `insertNewline:` command fires.
///
/// Focus / key-window: on appear the coordinator makes the text view first
/// responder AND calls `window?.makeKey()` (the notch panel is a non-activating
/// `NSPanel` with `canBecomeKey == true`), folding in the behavior of the old
/// `MakeKeyOnAppear` helper so keystrokes actually land.
private struct MultilineReplyField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let caretColor: Color
    @FocusState.Binding var isFocused: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    /// Reports the desired height (laid-out content, capped at ~`maxLines`) back to
    /// SwiftUI, which applies it via `.frame(height:)` so the panel grows to fit.
    let onHeightChange: (CGFloat) -> Void

    /// Visible-line cap before the field starts scrolling internally.
    private let maxLines: CGFloat = 5
    private let font = NSFont.systemFont(ofSize: 12)
    private let inset = NSSize(width: 0, height: 2)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NotchReplyTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.string = text
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(Color.cl.onDark)
        textView.insertionPointColor = NSColor(caretColor)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = inset
        // Wrap text to the container width (don't grow horizontally).
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholderString = placeholder

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Make first responder + promote the host panel to key, on the next
        // runloop tick (the view isn't in the window hierarchy on first layout).
        DispatchQueue.main.async {
            guard let window = textView.window else { return }
            if !window.isKeyWindow { window.makeKey() }
            window.makeFirstResponder(textView)
            context.coordinator.reportHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NotchReplyTextView else { return }
        // Keep the text view in sync when the binding is cleared externally
        // (e.g. after send), without clobbering in-progress typing.
        if textView.string != text {
            textView.string = text
        }
        textView.insertionPointColor = NSColor(caretColor)

        // Re-assert focus + key window if SwiftUI says we should be focused.
        if isFocused, let window = textView.window {
            if !window.isKeyWindow { window.makeKey() }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }
        context.coordinator.reportHeight()
    }

    /// Capped height for the current content: laid-out text height (incl. insets),
    /// clamped between one line and `maxLines`. Beyond the cap the scroll view
    /// scrolls internally.
    fileprivate func cappedHeight(for textView: NotchReplyTextView) -> CGFloat {
        let line = ceil(font.boundingRectForFont.height)
        let minH = line + inset.height * 2
        let maxH = line * maxLines + inset.height * 2
        return min(max(textView.laidOutContentHeight, minH), maxH)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineReplyField
        weak var textView: NotchReplyTextView?
        private var lastReported: CGFloat = -1

        init(_ parent: MultilineReplyField) {
            self.parent = parent
        }

        /// Compute the capped height and push it to SwiftUI if it changed. Pushed
        /// async so we never mutate SwiftUI `@State` during a view-update pass.
        func reportHeight() {
            guard let textView else { return }
            let h = parent.cappedHeight(for: textView)
            if abs(h - lastReported) > 0.5 {
                lastReported = h
                let report = parent.onHeightChange
                DispatchQueue.main.async { report(h) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NotchReplyTextView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → newline; plain Return → SEND.
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSend()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// `NSTextView` subclass that exposes its laid-out content height (so the
/// representable can size + cap the box), paints a placeholder when empty, and
/// keeps the non-activating notch panel key on becoming first responder.
final class NotchReplyTextView: NSTextView {
    var placeholderString: String = ""

    /// Height needed to show all currently laid-out text, including the text
    /// container insets. The representable clamps this between one and `maxLines`.
    var laidOutContentHeight: CGFloat {
        guard let layoutManager = layoutManager, let container = textContainer else {
            return ceil(font?.boundingRectForFont.height ?? 14)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        return ceil(used) + textContainerInset.height * 2
    }

    override func becomeFirstResponder() -> Bool {
        // The notch panel is non-activating; make sure it's key so we get keys.
        if let window = window, !window.isKeyWindow { window.makeKey() }
        return super.becomeFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(Color.cl.onDarkSoft).withAlphaComponent(0.7),
        ]
        let origin = NSPoint(x: textContainerInset.width,
                             y: textContainerInset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }
}

/// Reports the natural (wrapped) height of the "↩ REPLYING TO" message `Text`
/// up the view tree so the reading pane can size itself to `min(content, cap)`
/// instead of collapsing to a `ScrollView`'s minimal ideal height.
// MARK: - Row quick actions (shared by the ⋯ overflow menu and the right-click menu)

/// Copy Claude's last assistant message to the clipboard. CRITICAL: this does
/// synchronous disk IO (now tail-bounded) — only ever call it from a tap action,
/// never a label/body render path.
@MainActor private func zcCopyLastMessage(_ s: Session) {
    let text = s.lastAssistantSummary() ?? s.statusDetail ?? ""
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

@MainActor private func zcCopyPath(_ s: Session) {
    guard let cwd = s.cwd, !cwd.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(cwd, forType: .string)
}

@MainActor private func zcRevealInFinder(_ s: Session) {
    guard let cwd = s.cwd, !cwd.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
}

/// Open the session's folder in the user's default handler for directories (e.g.
/// Finder, or an editor set as the folder handler). NOT routed through
/// FocusController.focusEditor (that only RAISES an already-open editor by title).
@MainActor private func zcOpenFolder(_ s: Session) {
    guard let cwd = s.cwd, !cwd.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
}

/// Modal rename: set or clear the per-cwd alias. Uses an NSAlert with a text field
/// (SwiftUI menus can't host one) and activates the app so the field is focusable.
@MainActor private func zcPromptRename(_ s: Session) {
    guard let cwd = s.cwd, !cwd.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Rename session"
    alert.informativeText = "Shown instead of “\(s.project)”. Leave blank to use the default."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = Settings.shared.alias(forCwd: cwd) ?? ""
    field.placeholderString = s.project
    alert.accessoryView = field
    // Do NOT NSApp.activate here: this is an .accessory app, so activating it would
    // permanently pull frontmost off the terminal (it never auto-deactivates when
    // the modal closes). runModal() makes the alert window key on its own, so the
    // field still accepts input while the terminal keeps frontmost on dismiss.
    alert.window.makeKeyAndOrderFront(nil)
    if alert.runModal() == .alertFirstButtonReturn {
        Settings.shared.setAlias(field.stringValue, forCwd: cwd)
    }
}

/// The shared action set, rendered in both the ⋯ overflow Menu and the row's
/// right-click contextMenu so they never drift.
@ViewBuilder @MainActor private func zcRowActions(_ s: Session) -> some View {
    Button { zcCopyLastMessage(s) } label: { Label("Copy last message", systemImage: "doc.on.doc") }
    Button { zcCopyPath(s) } label: { Label("Copy path", systemImage: "folder") }
    Button { zcRevealInFinder(s) } label: { Label("Reveal in Finder", systemImage: "macwindow") }
    Button { zcOpenFolder(s) } label: { Label("Open folder", systemImage: "arrow.up.forward.app") }
    Divider()
    Button { zcPromptRename(s) } label: {
        Label(Settings.shared.alias(forCwd: s.cwd) == nil ? "Rename…" : "Rename / clear name…",
              systemImage: "pencil")
    }
}

private struct ReplyContextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the session list's natural content height so the surrounding ScrollView
/// can size to content (short list → panel hugs it) and cap + scroll only when it
/// would overflow the screen.
private struct SessionListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
