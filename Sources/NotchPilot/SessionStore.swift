import Foundation
import Combine

/// Watches `~/.notchpilot/sessions/` and publishes the current set of sessions.
///
/// Uses a `DispatchSource` file-system monitor on the directory fd for low-latency
/// updates, plus a 2s polling timer as a safety net (the directory monitor can
/// miss events if the fd is recreated, e.g. when the dir is deleted/recreated).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    /// Fires when a session transitions into a given status. Used for notifications.
    var onTransition: ((_ session: Session, _ from: SessionStatus?, _ to: SessionStatus) -> Void)?

    private let sessionsDir: URL
    /// Active-session cap: `working`/`waiting` sessions stay on the board this long.
    /// They're either running or awaiting the human, so they must not vanish early.
    private let staleAfter: TimeInterval = 6 * 60 * 60 // 6 hours
    /// `done`/`error` sessions are finished; self-clear from the board shortly after
    /// so a completed run doesn't linger for hours.
    private let finishedStaleAfter: TimeInterval = 10 * 60 // 10 minutes
    /// An `idle` session that hasn't updated in a while is probably dead/abandoned;
    /// drop it sooner than the 6h active cap but later than a finished run.
    private let idleStaleAfter: TimeInterval = 30 * 60 // 30 minutes
    /// A non-finished session not updated within this window is considered dead
    /// for the purposes of the manual "Clear finished/stale sessions" action.
    private let clearStaleAfter: TimeInterval = 30 * 60 // 30 minutes

    private var dirFD: CInt = -1
    private var dirSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    /// Coalesces bursts of directory events into a single reload ~150ms later, so a
    /// flurry of hook writes across many sessions doesn't re-decode the dir N times.
    private var reloadWork: DispatchWorkItem?
    /// mtime cache so unchanged session files are reused instead of re-decoded each
    /// reload (cheap with many sessions). Keyed by file URL; evicted when the file
    /// disappears. Staleness is still recomputed every reload from `updatedAt`.
    private var fileCache: [URL: (mtime: Date, session: Session)] = [:]

    /// Last seen status per session id, to detect transitions.
    private var lastStatus: [String: SessionStatus] = [:]

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(sessionsDir: URL? = nil) {
        self.sessionsDir = sessionsDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".notchpilot/sessions", isDirectory: true)
    }

    func start() {
        ensureDirectoryExists()
        reload()
        startDirectoryMonitor()
        startPollTimer()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cancelDirectoryMonitor()
    }

    // MARK: - Directory plumbing

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
    }

    private func startPollTimer() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startDirectoryMonitor() {
        cancelDirectoryMonitor()

        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            // If the directory itself was removed/renamed, rebuild the monitor now.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.ensureDirectoryExists()
                self.startDirectoryMonitor()
            }
            // Coalesce the reload so a burst of writes triggers one decode pass.
            self.scheduleReload()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        dirSource = source
    }

    private func cancelDirectoryMonitor() {
        dirSource?.cancel()
        dirSource = nil
        dirFD = -1
    }

    // MARK: - Loading

    /// Debounced reload: collapse a burst of directory-change events into one decode
    /// pass ~150ms later. The 2s poll and manual actions still call `reload()` directly.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        let now = Date()
        var loaded: [Session] = []
        var present: Set<URL> = []
        for url in urls where url.pathExtension == "json" {
            present.insert(url)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Unchanged file → reuse the cached decode (still re-checking staleness,
            // which depends on `now`, not the file).
            if let mtime, let cached = fileCache[url], cached.mtime == mtime {
                if !isStale(cached.session, now: now) { loaded.append(cached.session) }
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(Session.self, from: data) else {
                continue
            }
            if let mtime { fileCache[url] = (mtime, session) }
            // Drop stale sessions (per-status windows; see `isStale`).
            if isStale(session, now: now) { continue }
            loaded.append(session)
        }
        // Bound the cache: forget files that are no longer present.
        if fileCache.count != present.count {
            fileCache = fileCache.filter { present.contains($0.key) }
        }

        let sorted = loaded.sorted { lhs, rhs in
            if lhs.status.sortRank != rhs.status.sortRank {
                return lhs.status.sortRank < rhs.status.sortRank
            }
            // Within the WAITING group, oldest-blocked floats to the top (you've
            // neglected it longest); every other status keeps most-recent-first.
            if lhs.status == .waiting {
                return (lhs.enteredStatusAt ?? lhs.updatedAt) < (rhs.enteredStatusAt ?? rhs.updatedAt)
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        detectTransitions(in: sorted)
        if sorted != sessions {
            sessions = sorted
        }
    }

    /// Whether a session should be auto-hidden from the board, using a per-status
    /// stale window keyed off `updatedAt` age:
    /// - `working`/`waiting`: kept up to `staleAfter` (6h) — active / awaiting human.
    /// - `done`/`error`: dropped after `finishedStaleAfter` (10m) — finished runs.
    /// - `idle`: dropped after `idleStaleAfter` (30m) — likely dead/abandoned.
    private func isStale(_ session: Session, now: Date) -> Bool {
        let age = now.timeIntervalSince(session.updatedAt)
        switch session.status {
        case .working, .waiting:
            return age > staleAfter
        case .done, .error:
            return age > finishedStaleAfter
        case .idle:
            return age > idleStaleAfter
        }
    }

    /// Delete session files that are finished (`done`/`error`) or stale (any
    /// status not updated within `clearStaleAfter`), plus any unparseable junk.
    /// Non-destructive in practice: a still-live session re-appears on its next
    /// hook event. Returns how many files were removed.
    @discardableResult
    func clearFinishedAndStale() -> Int {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        let now = Date()
        var removed = 0
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(Session.self, from: data) else {
                // Unparseable file — treat as junk and remove it.
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
                continue
            }
            let finished = session.status == .done || session.status == .error
            let stale = now.timeIntervalSince(session.updatedAt) > clearStaleAfter
            if finished || stale {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }

        if removed > 0 { reload() }
        return removed
    }

    private func detectTransitions(in incoming: [Session]) {
        let liveIDs = Set(incoming.map(\.id))
        for session in incoming {
            let previous = lastStatus[session.id]
            if previous != session.status {
                onTransition?(session, previous, session.status)
                lastStatus[session.id] = session.status
            }
        }
        // Forget sessions that disappeared so a future reuse re-notifies.
        lastStatus = lastStatus.filter { liveIDs.contains($0.key) }
    }
}
