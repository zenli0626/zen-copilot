import SwiftUI

/// High-level mood for the pet, derived from the aggregate session state. Drives
/// posture, eye shape, and the periodic motions in `PixelPet`.
///
/// Priority (most → least urgent): error → alert(waiting) → working → happy(done)
/// → calm(idle/nothing). Only `.calm` is "restful" enough to let the pet drift
/// toward sleep over time.
enum PetBehavior: Equatable {
    case calm     // nothing happening — idles, then gets sleepy → sleeps
    case working  // actively thinking — busy eye-scan + quicker bob
    case alert    // waiting on the human — wide eyes + periodic attention hop
    case happy    // just finished — content posture + occasional joyful hop
    case error    // something broke — worried horizontal wobble

    /// Derive the single aggregate behavior from a set of sessions, by priority:
    /// any error → .error; else any waiting → .alert; else any working → .working;
    /// else any done (with nothing working/waiting) → .happy; else .calm.
    static func from(sessions: [Session]) -> PetBehavior {
        if sessions.contains(where: { $0.status == .error })   { return .error }
        if sessions.contains(where: { $0.status == .waiting }) { return .alert }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        if sessions.contains(where: { $0.status == .done })    { return .happy }
        return .calm
    }
}

/// Which way the pet is facing while it STROLLS across the panel. Drives the
/// eye-glance shift and the leading-foot of the walk gait so the creature reads
/// as actually heading somewhere. `.none` = not strolling (normal behaviors).
enum WalkFacing: Equatable {
    case none   // standing in the header — no walk gait
    case right  // heading toward the right edge
    case left   // heading back toward the dock

    /// Signed horizontal direction for eye-glance / lean (+1 right, -1 left, 0 idle).
    var sign: CGFloat {
        switch self {
        case .right: return 1
        case .left: return -1
        case .none: return 0
        }
    }
}

/// A tiny pixel-art mascot that lives in the MacBook notch — now a full DIGITAL
/// PET with moods, reactions, idle personality, and a tap-to-hop.
///
/// The pet is a wider-than-tall coral creature with notched corners — a filled
/// HEAD with two dark, wide-set EYES near the top and two short feet (with a
/// gap) below, faithful to the Claude Code welcome-screen mascot. It's rendered
/// from a fixed sprite matrix into a `Canvas` (one fill per run of like-colored
/// cells per row), so it stays cheap even when re-evaluated by the
/// `TimelineView(.animation)`.
///
/// All motion is derived purely from the timeline clock — periodic sine/modulo
/// math, no `Timer`/`Date()` randomness — so it's stable, resumes cleanly, and
/// the two on-screen pets (compact + header) are de-synced only by a constant
/// per-instance `phase` offset. The eyes are post-processed in the draw pass
/// (wide / scan / droop / closed / glance / happy-arch) rather than by editing
/// the base grid.
///
/// `behavior` selects the personality:
/// - **calm** — gentle bob, periodic blink, occasional eye-glance. After ~25s
///   continuously calm it gets **sleepy** (droopy half-lid eyes, slower bob);
///   after ~50s it's **sleeping** (eyes shut to a line, very slow breathing, a
///   little "z" drifting up and fading). Any non-calm behavior wakes it instantly.
/// - **working** — quicker bob; eyes scan left↔right (looks busy/focused).
/// - **alert** — eyes held wide; a small attention hop every ~2s.
/// - **happy** — content posture + a joyful hop every ~3s; eyes arch into "^ ^".
/// - **error** — a brief, gentle worried horizontal wobble/shake, looping.
struct PixelPet: View {

    /// Body color — driven by overall session status by the caller.
    var tint: Color

    /// Cell size in points. Small (≈2–3pt) so the whole pet fits the notch's
    /// ~22pt-tall compact area. View size = grid dimensions × `pixelSize`.
    var pixelSize: CGFloat = 2.4

    /// The pet's mood, derived from session state by the caller via
    /// `PetBehavior.from(sessions:)`.
    var behavior: PetBehavior = .calm

    /// Per-instance phase offset (seconds) so two pets on screen aren't perfectly
    /// in sync. Deterministic — a constant, NOT randomness.
    var phase: TimeInterval = 0

    /// When non-`.none`, the pet performs a WALK gait (alternating stepping feet
    /// + a brisk body bob) and faces the travel direction (eyes glance + lean
    /// toward `facing`). Driven by the STROLL overlay in `NotchView`. Layered on
    /// top of `behavior` (only the stroll uses it, and only while calm), so the
    /// normal moods are untouched when `facing == .none`.
    var facing: WalkFacing = .none

    /// When non-`nil`, the pet ACTS OUT a wellness reminder on top of its normal
    /// behavior for the cue's display window (~8s): stretch reaches up, water
    /// sips with a droplet, lookAway holds its eyes far to one side (20-20-20),
    /// posture sits up tall and still. Driven by `WellnessState.active?.kind` in
    /// `NotchView`/`CompactGlyph`. `nil` = no cue (normal moods stand).
    var cue: WellnessCue? = nil

    // Eye color (dark, reads against the coral body even on the notch black).
    private let eyeColor = Color.cl.surfaceDark

    // MARK: - Sleep timing (only accrues while behavior == .calm)

    /// Seconds of continuous calm before the pet looks sleepy (droopy eyes, slow bob).
    private let sleepyAfter: TimeInterval = 25
    /// Seconds of continuous calm before the pet is fully asleep (eyes shut, "z").
    private let sleepingAfter: TimeInterval = 50

    /// Timeline timestamp captured the moment `behavior` last became `.calm`. Used
    /// to measure how long we've been continuously calm (sleep progression). Nil
    /// whenever behavior isn't calm. We can't use `Date()` (must stay deterministic
    /// off the timeline clock), so this is seeded from the `TimelineView`'s own
    /// `timeline.date` via `.onChange(of: behavior)` and an initial read.
    @State private var calmSince: TimeInterval?

    /// One-shot tap hop: while the timeline clock is < this value, overlay a
    /// springy jump on top of whatever the behavior is doing. Set on tap.
    @State private var hopUntil: TimeInterval = 0
    private let tapHopDuration: TimeInterval = 0.6

    // MARK: - Sprite

    // 0 = transparent, 1 = body, 2 = eye.
    // 13 wide × 10 tall — faithful to the Claude Code welcome-screen mascot: a
    // blocky head WIDER than tall with notched/rounded corners (top & bottom
    // corners cut in), two dark eyes set WIDE apart in the upper-middle, and two
    // short feet (with a gap) hanging below.
    private static let sprite: [[Int]] = [
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        [1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1],
        [1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0],
        [0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0],
    ]

    // The two eye rows (top, bottom) — used to fake blink / droop / close by
    // drawing only a thin slice instead of the full eye cells.
    private static let eyeRows = 3...4
    // Base eye-block extents in cells (columns the eye pixels span).
    private static let leftEyeCols = 2...3
    private static let rightEyeCols = 8...9

    // The two FEET (bottom leg blocks, rows 8–9). Used by the walk gait to lift
    // one foot at a time so the creature appears to step. Cols match the sprite:
    // left foot at 4–5, right foot at 7–8.
    private static let footRows = 8...9
    private static let leftFootCols = 4...5
    private static let rightFootCols = 7...8
    /// How far a stepping foot lifts off the ground, in cells.
    private static let footLift: CGFloat = 1.0
    /// Seconds per single step (one foot up/down); the gait alternates feet so a
    /// full stride is two of these.
    private static let stepPeriod: TimeInterval = 0.25

    private static var cols: Int { sprite.first?.count ?? 0 }
    private static var rows: Int { sprite.count }

    var body: some View {
        let cols = Self.cols
        let rows = Self.rows
        let w = CGFloat(cols) * pixelSize
        let h = CGFloat(rows) * pixelSize

        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let t = now + phase
            let frame = expression(at: t, now: now)

            Canvas { ctx, _ in
                // Whole-body transforms: vertical bob/hop + a horizontal wobble
                // (error) / attention shimmy.
                ctx.translateBy(x: frame.shakeOffset * pixelSize,
                                y: frame.bobOffset * pixelSize)

                // Look-away / slumped LEAN: rotate the whole body about its base so
                // the head clearly tips toward the gaze (or slouches). Anchored at
                // the feet so it reads as leaning, not floating.
                if frame.bodyLean != 0 {
                    ctx.translateBy(x: w / 2, y: h)
                    ctx.rotate(by: .radians(frame.bodyLean))
                    ctx.translateBy(x: -w / 2, y: -h)
                }

                // Water GULP: tip the head back by rotating about the lower neck so
                // the whole creature clearly tilts up to drink.
                if frame.headTilt != 0 {
                    let pivotY = h * 0.7
                    ctx.translateBy(x: w / 2, y: pivotY)
                    ctx.rotate(by: .radians(-frame.headTilt))
                    ctx.translateBy(x: -w / 2, y: -pivotY)
                }

                // Wellness "rise": stretch/posture cues scale the body taller,
                // anchored at the FEET (bottom edge) so the creature appears to
                // reach up / sit up while its feet stay planted.
                if frame.bodyStretch != 0 {
                    let scaleY = 1 + frame.bodyStretch
                    ctx.translateBy(x: 0, y: h)
                    ctx.scaleBy(x: 1, y: scaleY)
                    ctx.translateBy(x: 0, y: -h)
                }

                // Stretch ARM nubs: two short raised pixel "arms" going UP from the
                // upper sides of the head, drawn before the body so the body's top
                // row overlaps their base. They extend with `armRaise`.
                if frame.armRaise > 0 {
                    drawStretchArms(ctx, frame: frame)
                }

                for (r, row) in Self.sprite.enumerated() {
                    let isEyeRow = Self.eyeRows.contains(r)
                    let isFootRow = Self.footRows.contains(r)

                    var c = 0
                    while c < row.count {
                        let v = row[c]
                        if v == 0 { c += 1; continue }
                        var end = c
                        while end + 1 < row.count && row[end + 1] == v { end += 1 }

                        let isEye = (v == 2)
                        // Eyes get special-cased below (shape + horizontal glance).
                        if isEye && isEyeRow {
                            drawEyeRun(ctx, row: r, startCol: c, endCol: end, frame: frame)
                            c = end + 1
                            continue
                        }

                        // Walk gait: lift whichever foot is mid-step so the pet
                        // appears to walk. `c` identifies which foot this run is.
                        var footY: CGFloat = 0
                        if isFootRow {
                            if Self.leftFootCols.contains(c) {
                                footY = -frame.leftFootLift * pixelSize
                            } else if Self.rightFootCols.contains(c) {
                                footY = -frame.rightFootLift * pixelSize
                            }
                        }

                        let runWidth = CGFloat(end - c + 1) * pixelSize
                        let rect = CGRect(
                            x: CGFloat(c) * pixelSize,
                            y: CGFloat(r) * pixelSize + footY,
                            width: runWidth,
                            height: pixelSize
                        )
                        ctx.fill(Path(rect), with: .color(tint))
                        c = end + 1
                    }
                }

                // Floating "z" while sleeping — drifts up and fades, looping.
                if frame.zOpacity > 0 {
                    drawSleepZ(ctx, frame: frame, viewWidth: w)
                }

                // Water cue: a little cup/glass at the mouth that drains as the pet
                // gulps, plus a droplet bobbing at the spout.
                if frame.cupOpacity > 0 {
                    drawCup(ctx, frame: frame, viewWidth: w, viewHeight: h)
                }
                if frame.dropletOpacity > 0 {
                    drawDroplet(ctx, frame: frame, viewWidth: w, viewHeight: h)
                }
            }
            .frame(width: w, height: h)
            // Seed the calm timer on first appearance if we're already calm, and
            // re-seed/clear it whenever behavior crosses the calm boundary. Done
            // here (inside the timeline) so we can capture the timeline clock.
            .onAppear {
                if behavior == .calm && calmSince == nil { calmSince = now }
            }
            .onChange(of: behavior) { _, newValue in
                // ANY non-calm behavior wakes the pet (resets the sleep timer);
                // entering calm starts the countdown fresh.
                calmSince = (newValue == .calm) ? now : nil
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture {
            // One-shot happy hop, independent of behavior. Use the same reference
            // clock the timeline reads so the overlap window lines up.
            hopUntil = Date.timeIntervalSinceReferenceDate + tapHopDuration
        }
    }

    // MARK: - Eye drawing

    /// Draw one horizontal run of eye cells, applying the current eye shape
    /// (open / wide / blink / droop / closed / happy-arch) as a vertical slice,
    /// plus a horizontal glance/scan shift. `startCol…endCol` is the run in cells.
    private func drawEyeRun(_ ctx: GraphicsContext, row r: Int, startCol c: Int, endCol end: Int, frame: Frame) {
        let isTopRow = (r == Self.eyeRows.lowerBound)

        // Happy "^ ^": only the TOP eye row paints, and only the OUTER cell of
        // each eye pair, giving a little arch. Skip the rest entirely.
        if frame.happyEyes {
            if !isTopRow { return }
            // Keep the outer pixel of each eye (col 2 of the left pair, col 9 of
            // the right pair) for a "^ ^" arch.
            let outer = (c == Self.leftEyeCols.lowerBound) ? c
                      : (end == Self.rightEyeCols.upperBound ? end : c)
            let x = (CGFloat(outer) + frame.eyeShiftCells) * pixelSize
            let rect = CGRect(x: x, y: CGFloat(r) * pixelSize, width: pixelSize, height: pixelSize)
            ctx.fill(Path(rect), with: .color(eyeColor))
            return
        }

        // Vertical openness: 1 = full cell, →0 = thin slit.
        let openFrac = max(0.06, frame.eyeOpenFraction)
        let cellH = pixelSize * openFrac
        // Drooping (sleepy/closing) collapses toward the BOTTOM of the eye block
        // (lids fall), so anchor the slice to the lower edge; otherwise center it.
        let yBase = CGFloat(r) * pixelSize
        let y = frame.eyeDroop ? yBase + (pixelSize - cellH) : yBase + (pixelSize - cellH) / 2

        let runWidth = CGFloat(end - c + 1) * pixelSize
        let x = (CGFloat(c) + frame.eyeShiftCells) * pixelSize
        let rect = CGRect(x: x, y: y, width: runWidth, height: cellH)
        ctx.fill(Path(rect), with: .color(eyeColor))
    }

    /// Draw a small floating "z" above the pet that rises and fades on a loop.
    private func drawSleepZ(_ ctx: GraphicsContext, frame: Frame, viewWidth w: CGFloat) {
        let text = Text("z")
            .font(.system(size: max(7, pixelSize * 3.2), weight: .bold, design: .rounded))
            .foregroundStyle(Color.cl.onDarkSoft.opacity(frame.zOpacity))
        var resolved = ctx.resolve(text)
        resolved.shading = .color(Color.cl.onDarkSoft.opacity(frame.zOpacity))
        // Float up from near the top-right of the head.
        let x = w * 0.72
        let y = (1.4 - frame.zRise) * pixelSize
        ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
    }

    /// Draw a small water droplet near the pet's mouth/head for the hydrate cue.
    /// A teardrop: a circle with a pointed top, in the brand teal, bobbing gently.
    private func drawDroplet(_ ctx: GraphicsContext, frame: Frame, viewWidth w: CGFloat, viewHeight h: CGFloat) {
        let s = pixelSize
        // Sits just right-of-center, above the head, bobbing with `dropletRise`.
        let cx = w * 0.60
        let cy = h * 0.18 - frame.dropletRise * s
        let r = s * 1.1   // droplet body radius

        var drop = Path()
        // Rounded bottom + pointed top — a classic teardrop.
        drop.move(to: CGPoint(x: cx, y: cy - r * 1.8))      // tip
        drop.addQuadCurve(to: CGPoint(x: cx + r, y: cy),
                          control: CGPoint(x: cx + r * 0.9, y: cy - r))
        drop.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        drop.addQuadCurve(to: CGPoint(x: cx, y: cy - r * 1.8),
                          control: CGPoint(x: cx - r * 0.9, y: cy - r))
        drop.closeSubpath()

        ctx.fill(drop, with: .color(Color.cl.teal.opacity(frame.dropletOpacity)))
    }

    /// Stretch cue: two short pixel "arm" nubs reaching UP from the upper sides of
    /// the head, so the armless mascot clearly reads as arms-up stretching. Each is
    /// a 1-cell-wide column rising from just above the shoulders; length scales with
    /// `armRaise`. Drawn in the body tint so they read as part of the creature.
    private func drawStretchArms(_ ctx: GraphicsContext, frame: Frame) {
        let s = pixelSize
        // Max arm length in cells; grows with the reach.
        let len = frame.armRaise * 2.6
        guard len > 0.05 else { return }
        let height = len * s
        // Anchor the arm bases at the upper-side shoulders (sprite cols ~1 and ~11,
        // top body rows), rising upward off the top of the head.
        let topY = 2 * s                      // around the head's top body rows
        let leftX = 1 * s
        let rightX = 11 * s
        for x in [leftX, rightX] {
            let rect = CGRect(x: x, y: topY - height, width: s, height: height)
            ctx.fill(Path(rect), with: .color(tint))
        }
        // Tiny "hand" cap at the top of each arm for a clearer raised-arm read.
        if frame.armRaise > 0.5 {
            for x in [leftX - s * 0.5, rightX - s * 0.5] {
                let cap = CGRect(x: x, y: topY - height - s * 0.6, width: s * 2, height: s * 0.8)
                ctx.fill(Path(cap), with: .color(tint))
            }
        }
    }

    /// Water cue: a small cup/glass held at the pet's mouth, with a teal "water"
    /// level that drops as the pet gulps (`cupFill` 1→0). A simple trapezoid glass
    /// outline in the eye color with a teal fill rectangle inside.
    private func drawCup(_ ctx: GraphicsContext, frame: Frame, viewWidth w: CGFloat, viewHeight h: CGFloat) {
        let s = pixelSize
        // Sit at the lower-center "mouth" area, slightly right.
        let cw = s * 3.2                       // cup width at the rim
        let ch = s * 3.0                       // cup height
        let cx = w * 0.56
        let topY = h * 0.40
        let bottomNarrow = cw * 0.32           // taper the base (glass shape)

        var glass = Path()
        glass.move(to: CGPoint(x: cx - cw / 2, y: topY))
        glass.addLine(to: CGPoint(x: cx + cw / 2, y: topY))
        glass.addLine(to: CGPoint(x: cx + bottomNarrow / 2, y: topY + ch))
        glass.addLine(to: CGPoint(x: cx - bottomNarrow / 2, y: topY + ch))
        glass.closeSubpath()

        // Water inside: fills from the bottom up to `cupFill` of the cup height.
        let fill = max(0, min(1, frame.cupFill))
        if fill > 0.02 {
            let waterTopY = topY + ch * (1 - fill)
            // Interpolate the cup's taper at the water's top edge.
            let frac = (waterTopY - topY) / ch
            let halfW = (cw / 2) + (bottomNarrow / 2 - cw / 2) * frac
            var water = Path()
            water.move(to: CGPoint(x: cx - halfW, y: waterTopY))
            water.addLine(to: CGPoint(x: cx + halfW, y: waterTopY))
            water.addLine(to: CGPoint(x: cx + bottomNarrow / 2, y: topY + ch))
            water.addLine(to: CGPoint(x: cx - bottomNarrow / 2, y: topY + ch))
            water.closeSubpath()
            ctx.fill(water, with: .color(Color.cl.teal.opacity(frame.cupOpacity)))
        }
        // Glass outline on top so it reads as a cup.
        ctx.stroke(glass, with: .color(Color.cl.onDark.opacity(frame.cupOpacity)),
                   lineWidth: max(1, s * 0.45))
    }

    // MARK: - Expression model

    private struct Frame {
        var bobOffset: CGFloat        // vertical, in cells (×pixelSize at draw)
        var shakeOffset: CGFloat      // horizontal, in cells
        var eyeOpenFraction: CGFloat  // 1 = open, →0 = closed
        var eyeShiftCells: CGFloat    // horizontal eye glance/scan, in cells
        var eyeDroop: Bool            // anchor lids to bottom (sleepy/sleeping)
        var happyEyes: Bool           // render "^ ^" arch instead of eye blocks
        var zOpacity: Double          // sleeping "z" alpha
        var zRise: CGFloat            // sleeping "z" upward travel, in cells
        var leftFootLift: CGFloat     // walk gait: left foot lift, in cells
        var rightFootLift: CGFloat    // walk gait: right foot lift, in cells
        // Wellness cue extras (0 / false when no cue is acting).
        var bodyStretch: CGFloat = 0  // vertical body scale boost (stretch/posture rise)
        var dropletOpacity: Double = 0 // water-cue droplet alpha
        var dropletRise: CGFloat = 0   // water-cue droplet bob, in cells
        // Stretch cue: two raised "arm" nubs reaching up from the upper sides.
        // 0 = no arms; →1 = fully extended. Drawn as extra pixels above the head.
        var armRaise: CGFloat = 0
        // Water cue: a head tilt-BACK (gulp), in radians, pivoting near the neck so
        // the whole head clearly tips up to drink. Positive = tipped back.
        var headTilt: CGFloat = 0
        // Water cue: draw a little cup/glass at the mouth, and how full it is
        // (1 = full, →0 = drained) so it visibly empties as the pet gulps.
        var cupOpacity: Double = 0
        var cupFill: CGFloat = 1
        // Look-away cue: lean the WHOLE body toward the gazed side (radians) for an
        // exaggerated "looking into the distance" turn. Positive = leaning right.
        var bodyLean: CGFloat = 0
    }

    /// Periodic, deterministic motion from the timeline clock. `t` is the
    /// phase-offset clock (for per-instance desync); `now` is the raw clock used
    /// for sleep-timer math and the tap-hop overlap window.
    private func expression(at t: TimeInterval, now: TimeInterval) -> Frame {
        var f = Frame(bobOffset: 0, shakeOffset: 0, eyeOpenFraction: 0.92,
                      eyeShiftCells: 0, eyeDroop: false, happyEyes: false,
                      zOpacity: 0, zRise: 0, leftFootLift: 0, rightFootLift: 0)

        // How long we've been continuously calm (0 if not calm / just woke).
        let calmElapsed: TimeInterval = (behavior == .calm)
            ? max(0, now - (calmSince ?? now))
            : 0
        let isSleepy = behavior == .calm && calmElapsed >= sleepyAfter && calmElapsed < sleepingAfter
        let isSleeping = behavior == .calm && calmElapsed >= sleepingAfter

        switch behavior {
        case .calm:
            if isSleeping {
                // Very slow breathing bob; eyes shut to a line; "z" floats up.
                f.bobOffset = sin(t / 4.2 * 2 * .pi) * 0.35
                f.eyeOpenFraction = 0.07
                f.eyeDroop = true
                let zCycle: TimeInterval = 3.0
                let zp = (t.truncatingRemainder(dividingBy: zCycle)) / zCycle // 0…1
                f.zRise = CGFloat(zp) * 4.0           // rises ~4 cells
                f.zOpacity = sin(zp * .pi) * 0.85     // fade in then out
            } else if isSleepy {
                // Slower bob, half-lidded droopy eyes.
                f.bobOffset = sin(t / 3.4 * 2 * .pi) * 0.4
                f.eyeOpenFraction = 0.42
                f.eyeDroop = true
            } else {
                // Awake-calm: gentle bob, periodic blink, occasional eye-glance.
                f.bobOffset = sin(t / 2.6 * 2 * .pi) * 0.5
                f.eyeOpenFraction = 0.92 * blinkMultiplier(t: t, cycle: 4.0)
                // Occasional glance: ~once per ~9s, hold ~0.8s, ±1 cell.
                let glanceCycle: TimeInterval = 9.0
                let gp = t.truncatingRemainder(dividingBy: glanceCycle)
                if gp < 0.8 {
                    f.eyeShiftCells = (sin(gp / 0.8 * .pi)) * (gp.truncatingRemainder(dividingBy: 2) < 1 ? 1 : -1)
                }
            }

        case .working:
            // Quicker bob; eyes scan left↔right rhythmically (busy/focused).
            f.bobOffset = sin(t / 1.5 * 2 * .pi) * 0.55
            f.eyeShiftCells = sin(t / 1.1 * 2 * .pi) * 1.0   // ±1 cell scan
            f.eyeOpenFraction = 0.95 * blinkMultiplier(t: t, cycle: 5.0)

        case .alert:
            // Eyes held WIDE; a small attention BOUNCE every ~2s.
            f.eyeOpenFraction = 1.0
            let baseBob = sin(t / 2.4 * 2 * .pi) * 0.3
            f.bobOffset = baseBob - hop(t: t, cycle: 2.0, dur: 0.45, height: 1.6)

        case .happy:
            // Content posture + a joyful HOP every ~3s; eyes arch into "^ ^".
            f.happyEyes = true
            let baseBob = sin(t / 2.8 * 2 * .pi) * 0.3
            f.bobOffset = baseBob - hop(t: t, cycle: 3.0, dur: 0.55, height: 2.2)

        case .error:
            // Worried WOBBLE — small horizontal jitter/shake, looping gently.
            f.shakeOffset = sin(t * 9) * 0.55 * (0.6 + 0.4 * sin(t * 1.3))
            f.bobOffset = sin(t / 2.0 * 2 * .pi) * 0.25
            f.eyeOpenFraction = 1.0   // worried wide eyes
        }

        // WALK GAIT — overrides the idle bob while strolling across the panel.
        // The two feet step alternately (one lifts while the other plants), with
        // a brisk body bob synced to the stride and the eyes glancing toward the
        // travel direction so the creature reads as heading somewhere. Active only
        // when the stroll has set `facing`; otherwise the moods above stand.
        if facing != .none {
            let stride = Self.stepPeriod * 2          // one full L+R stride
            let p = (t.truncatingRemainder(dividingBy: stride)) / stride  // 0…1
            // Alternate feet: left foot lifts in the first half of the stride,
            // right foot in the second half — a smooth half-sine lift each.
            if p < 0.5 {
                f.leftFootLift = CGFloat(sin(p / 0.5 * .pi)) * Self.footLift
                f.rightFootLift = 0
            } else {
                f.leftFootLift = 0
                f.rightFootLift = CGFloat(sin((p - 0.5) / 0.5 * .pi)) * Self.footLift
            }
            // Brisk body bob at twice the stride (one bob per step) — a small
            // up-down that peaks as each foot plants.
            f.bobOffset = -abs(sin(p * 2 * .pi)) * 0.45
            // Face the way we're walking: eyes glance + a slight lean toward dir.
            f.eyeShiftCells = facing.sign * 1.0
            f.shakeOffset = facing.sign * 0.3
            // Eyes open and alert while on the move; cancel any droop/blink/arch.
            f.eyeOpenFraction = 0.95
            f.eyeDroop = false
            f.happyEyes = false
            f.zOpacity = 0
            f.zRise = 0
        }

        // WELLNESS CUE — act out the active reminder on top of the mood. Each cue
        // loops on its own ~2-3s cycle so it reads clearly within the ~8s window.
        // We only apply cues while NOT strolling (the stroll owns the body fully).
        if let cue, facing == .none {
            applyCue(cue, to: &f, t: t)
        }

        // One-shot tap hop layered on top of everything (uses raw `now`).
        if now < hopUntil {
            let p = 1 - (hopUntil - now) / tapHopDuration   // 0…1 progress
            // Springy arch: up fast, settle with a tiny overshoot.
            let arch = sin(p * .pi)
            let overshoot = sin(p * .pi * 2) * 0.18 * (1 - p)
            f.bobOffset -= CGFloat(arch * 2.6 + overshoot)
            // Brief happy eyes during the tap hop too (unless mid-scan working).
            if behavior != .working { f.happyEyes = true }
        }

        return f
    }

    /// Layer a wellness cue's animation onto the current frame. Each cue is a
    /// small, loopable performance keyed off the timeline clock `t` so it reads
    /// clearly even in a couple of seconds. Tasteful at small pixel sizes.
    private func applyCue(_ cue: WellnessCue, to f: inout Frame, t: TimeInterval) {
        switch cue {
        case .stretch:
            // BIG STRETCH: reach UP tall in a clear arc — body shoots up (+70%),
            // two raised "arm" nubs go up from the upper sides, the pet briefly
            // HOLDS at the peak with content/closed eyes, then settles down with a
            // little squash-bounce. One full ~3.0s gesture, looping so it's
            // unmistakable across the ~8s window.
            let cycle: TimeInterval = 3.0
            let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle  // 0…1
            // Phases: 0–0.30 reach up (ease-out), 0.30–0.62 HOLD at peak,
            // 0.62–0.82 settle down, 0.82–1.0 squash-bounce recover.
            let reach: CGFloat
            let arms: CGFloat
            if p < 0.30 {
                let l = CGFloat(p / 0.30)
                reach = CGFloat(sin(Double(l) * .pi / 2))   // ease-out up
                arms = reach
            } else if p < 0.62 {
                reach = 1                                    // hold tall
                arms = 1
            } else if p < 0.82 {
                let l = CGFloat((p - 0.62) / 0.20)
                reach = 1 - CGFloat(sin(Double(l) * .pi / 2)) // ease down
                arms = reach
            } else {
                let l = CGFloat((p - 0.82) / 0.18)
                // Small settle-bounce below baseline then back to 0 (squash).
                reach = -CGFloat(sin(Double(l) * .pi)) * 0.12
                arms = 0
            }
            f.bodyStretch = reach * 0.75              // up to +75% taller — bold
            f.bobOffset = -reach * 0.9                // lift as it reaches up
            f.armRaise = arms                         // raised-arm nubs while reaching
            // Eyes content → fully closed at the satisfying peak of the stretch.
            f.eyeOpenFraction = max(0.08, 0.7 - 0.62 * reach)
            f.eyeDroop = true
            f.happyEyes = false

        case .water:
            // CLEAR DRINK: hold a little cup at the mouth and GULP — the head tips
            // back in 3 pronounced gulps over the cycle, the cup drains a bit with
            // each gulp, and a droplet bobs at the spout. Reads as "drinking water".
            let cycle: TimeInterval = 3.6
            let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle  // 0…1
            let gulps = 3.0
            // Three pronounced tilt-backs: a rectified sine gives repeated "up"
            // gulps; clamp to the first ~85% so it lowers the cup briefly at the end.
            let active = min(1.0, p / 0.85)
            let gulp = max(0, sin(Double(active) * .pi * gulps))   // 0…1, 3 humps
            f.headTilt = CGFloat(gulp) * 0.5          // tip head back ~0.5 rad — pronounced
            f.bobOffset -= CGFloat(gulp) * 0.35       // lifts a touch with each gulp
            f.cupOpacity = 0.95
            f.cupFill = 1 - CGFloat(min(1, active))   // drains over the gulps
            f.dropletOpacity = 0.85
            f.dropletRise = CGFloat(sin(t / 0.6 * 2 * .pi)) * 0.5  // quick bob at spout
            f.eyeOpenFraction = 0.85 - 0.5 * CGFloat(gulp)  // eyes ease shut while gulping

        case .lookAway:
            // STRONG LOOK-INTO-THE-DISTANCE: the whole head/body LEANS far to one
            // side and the eyes go fully to that side and HOLD a long time, then
            // switch to the other side once. Exaggerated lean so it clearly turns
            // away to gaze off. One ~7s loop = far-left hold → far-right hold.
            let cycle: TimeInterval = 7.0
            let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle  // 0…1
            let dir: CGFloat = p < 0.5 ? -1 : 1
            let local = p < 0.5 ? p / 0.5 : (p - 0.5) / 0.5            // 0…1 within hold
            // Ease quickly into the turn (first ~18%), park at full extent the rest.
            let ramp = CGFloat(min(1, local / 0.18))
            f.eyeShiftCells = dir * 1.9 * ramp        // eyes pinned hard to the side
            f.bodyLean = dir * 0.32 * ramp            // whole head/body leans far that way
            f.shakeOffset += dir * 1.2 * ramp         // and shifts bodily toward the gaze
            f.eyeOpenFraction = 1.0
            f.eyeDroop = false
            f.happyEyes = false

        case .posture:
            // SLUMP → STRAIGHTEN: start slouched (short + leaning), then RISE up
            // straight and tall and hold proud — the correction is visible, not a
            // static pose. ~4s loop: slump (held briefly) → snap up → hold tall.
            let cycle: TimeInterval = 4.0
            let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle  // 0…1
            let upright: CGFloat   // -1 = slumped, +1 = proud tall
            if p < 0.28 {
                upright = -1                              // hold the slouch
            } else if p < 0.46 {
                let l = CGFloat((p - 0.28) / 0.18)
                upright = -1 + 2 * CGFloat(sin(Double(l) * .pi / 2))  // ease UP straight
            } else {
                upright = 1                               // hold tall & proud
            }
            // Map: slumped → shorter + leaned; proud → +35% taller + level.
            // (slumped `upright` is negative → bodyStretch goes negative = shorter.)
            f.bodyStretch = upright >= 0 ? upright * 0.35 : upright * 0.18
            f.bodyLean = upright < 0 ? CGFloat(-0.2) * (-upright) : 0   // lean while slouched
            if upright >= 0 {
                f.bobOffset = sin(t / 3.0 * 2 * .pi) * 0.1   // composed breathing when up
            } else {
                f.bobOffset = 0.6 * (-upright)               // sit low while slumped
            }
            f.eyeShiftCells = 0
            // Eyes a bit droopy/low when slumped, alert and forward when upright.
            f.eyeOpenFraction = upright >= 0 ? 0.95 : 0.55
            f.eyeDroop = upright < 0
            f.happyEyes = false
        }
    }

    /// A one-shot upward hop pulse repeating every `cycle` seconds: rises to
    /// `height` cells over `dur` seconds (smooth half-sine), then rests at 0.
    /// Returned as a POSITIVE magnitude; callers subtract it to move UP.
    private func hop(t: TimeInterval, cycle: TimeInterval, dur: TimeInterval, height: CGFloat) -> CGFloat {
        let p = t.truncatingRemainder(dividingBy: cycle)
        guard p < dur else { return 0 }
        return CGFloat(sin(p / dur * .pi)) * height
    }

    /// Blink multiplier: 1 most of the time, dipping toward ~0.18 for a quick
    /// ~150ms close once per `cycle` seconds. Multiply into `eyeOpenFraction`.
    private func blinkMultiplier(t: TimeInterval, cycle: TimeInterval) -> CGFloat {
        let blinkDuration: TimeInterval = 0.15
        let p = t.truncatingRemainder(dividingBy: cycle)
        guard p < blinkDuration else { return 1 }
        let closed = 1 - sin(p / blinkDuration * .pi)  // dips to 0 mid-blink
        return max(0.18, 1 - closed)
    }
}
