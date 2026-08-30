import AppKit
import Foundation
import OSLog
import PersistenceCore

@MainActor
final class DeskLiveReloader {
    static let shared = DeskLiveReloader()
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "workshop-live")
    private var watcher: FileChangeWatcher?
    private var busTask: Task<Void, Never>?
    private var occlusionTask: Task<Void, Never>?
    /// One exact presentation boundary (Desk snapshot stale / live row aged
    /// out). This is deliberately not a repeating timer: file/store edges are
    /// still the only ongoing live-update source.
    private var deadlineTask: Task<Void, Never>?
    private var scheduledDeadline: Date?
    private var viewVisible = false
    private var sceneActive = true
    private var windowVisible = true
    private var effectivelyVisible = false
    private var started = false
    /// Invalidates callbacks from a retired file/bus subscription. Cancellation
    /// is cooperative, so a callback already queued when the Desk rebinds must
    /// prove it still belongs to the current root before it can signal reload.
    private var watchGeneration: UInt64 = 0
    /// The active Desk view normally keeps one stable root, but a process-wide
    /// reloader must not silently retain a previous root after the view is
    /// reconstructed with another configured data root (tests, recovery, and
    /// alternate runtimes all do this).  Keeping the normalized set lets an
    /// equal activation stay cheap while a changed root replaces every exact
    /// watcher and bus subscription.
    private var watchedPaths: Set<URL> = []
    private(set) var configurationError: String?
    private var reloadSequence: UInt64 = 0
    private var reload: (@MainActor @Sendable () async -> Void)?
    private let debounceDelay: Duration
    private let visibilityResolver: @MainActor @Sendable () -> Bool
    private lazy var debouncer = StoreReloadDebouncer(delay: debounceDelay) { [weak self] in
        await self?.performReload()
    }

    /// Diagnostic file trace (2026-08-27): this app emits nothing to the
    /// unified log and refuses lldb, so the desk-never-loads class of bug is
    /// otherwise unobservable in the installed build. One appended line per
    /// lifecycle event, /tmp-rooted so reboots clean it up.
    nonisolated static let tracePath = NSTemporaryDirectory() + "nativeagent-desk-reloader-trace.log"
    /// Instance spelling for call sites whose source-scrape pins require the
    /// `.shared` form (DeskViewHonestySurfaceTests single-activation tripwire).
    nonisolated func traceEvent(_ line: String) { Self.trace(line) }

    nonisolated static func trace(_ line: String) {
        let msg = "\(Date().timeIntervalSince1970) \(line)\n"
        guard let data = msg.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: tracePath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: tracePath))
        }
    }

    /// The facts about one window that decide glanceability, separated from
    /// NSWindow so the decision is testable headless.
    struct WindowFacts {
        var isVisible: Bool
        var occlusionVisible: Bool
        var canBecomeMain: Bool
    }

    /// Is the desk glanceable? Per-WINDOW visibility, never app activation:
    /// User's core use is NativeAgent visible in the background while he works
    /// in another app. When the app is inactive, mainWindow/keyWindow are both
    /// nil — the old fallback read `NSApp.isActive` there, so a plainly
    /// visible background window counted as hidden, and since occlusion never
    /// actually changes in that scenario, no notification ever corrected it:
    /// the desk mounted to a spinner that never resolved. Every window is
    /// evaluated uniformly — privileging main/key would let a key panel keep
    /// reloads on, or an occluded main window veto another visible one. Any
    /// visible, unoccluded, main-capable window (panels and status windows
    /// excluded) keeps live updates on.
    static func resolveGlanceVisibility(windows: [WindowFacts]) -> Bool {
        windows.contains { $0.canBecomeMain && $0.isVisible && $0.occlusionVisible }
    }

    init(
        debounceDelay: Duration = .milliseconds(500),
        visibilityResolver: @escaping @MainActor @Sendable () -> Bool = {
            {
                let facts = NSApp.windows.map { window in
                    WindowFacts(
                        isVisible: window.isVisible,
                        occlusionVisible: window.occlusionState.contains(.visible),
                        canBecomeMain: window.canBecomeMain)
                }
                trace("resolver windows=" + facts.map {
                    "[v:\($0.isVisible) o:\($0.occlusionVisible) m:\($0.canBecomeMain)]"
                }.joined())
                return resolveGlanceVisibility(windows: facts)
            }()
        }
    ) {
        self.debounceDelay = debounceDelay
        self.visibilityResolver = visibilityResolver
    }

    /// Bind the currently visible DeskView to the app-lifetime watcher. The
    /// coordinator survives navigation reconstruction, so hidden file events
    /// remain dirty and produce one logged catch-up load for the new view.
    @discardableResult
    func activate(
        paths: [URL],
        reload: @escaping @MainActor @Sendable () async -> Void
    ) -> String? {
        self.reload = reload
        Self.trace("activate paths=\(paths.count)")
        guard start(paths: paths) else {
            setViewVisible(false)
            return configurationError
        }
        setViewVisible(true)
        Self.trace("activate ok -> signal")
        Task { await debouncer.signal() }
        return nil
    }

    func deactivate() {
        setViewVisible(false)
        reload = nil
    }

    @discardableResult
    func start(paths: [URL]) -> Bool {
        let normalized = Set(paths.map(\.standardizedFileURL))
        if started {
            guard watchedPaths != normalized else { return true }
            stop()
        }
        for path in normalized {
            do {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                configurationError = "Desk live updates are unavailable: \(error.localizedDescription)"
                return false
            }
        }
        started = true
        watchedPaths = normalized
        configurationError = nil
        watchGeneration &+= 1
        let generation = watchGeneration
        // A vnode source can watch an absent file only through an existing
        // parent. These are generated store directories, not state rows; make
        // the two canonical parents available before arming so a blank-slate
        // install cannot permanently miss its first out-of-process append.
        watcher = FileChangeWatcher(paths: paths) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started, self.watchGeneration == generation else { return }
                self.sourceDidChange()
            }
        }
        let changes = StoreChangeBus.shared.changes()
        busTask = Task { [weak self] in
            for await change in changes where normalized.contains(change.path.standardizedFileURL) {
                guard let self else { return }
                guard self.started, self.watchGeneration == generation else { return }
                sourceDidChange()
            }
        }
        let occlusionNotifications = NotificationCenter.default.notifications(
            named: NSWindow.didChangeOcclusionStateNotification
        )
        occlusionTask = Task { [weak self] in
            for await _ in occlusionNotifications {
                guard let self else { return }
                refreshWindowVisibility()
            }
        }
        refreshWindowVisibility()
        updateVisibility()
        return true
    }

    func setViewVisible(_ value: Bool) { Self.trace("setViewVisible \(value)"); viewVisible = value; updateVisibility() }
    func setSceneActive(_ value: Bool) { Self.trace("setSceneActive \(value)"); sceneActive = value; refreshWindowVisibility(); updateVisibility() }
    /// Schedule the next semantic freshness transition. Replacing the value
    /// replaces the single sleeper; nil cancels it. If the deadline fires while
    /// hidden, StoreReloadDebouncer retains one dirty edge for the next visible
    /// activation exactly as it does for a file change.
    func scheduleRefresh(at deadline: Date?) {
        guard deadline != scheduledDeadline else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        scheduledDeadline = deadline
        guard started, let deadline else { return }
        let generation = watchGeneration
        deadlineTask = Task { [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.started,
                  self.watchGeneration == generation,
                  self.scheduledDeadline == deadline
            else { return }
            self.deadlineTask = nil
            self.scheduledDeadline = nil
            await self.debouncer.signal()
        }
    }
    /// One source edge for process-local bus and vnode watcher paths. Keeping
    /// both lanes on this helper makes lifecycle gating directly testable.
    func sourceDidChange() {
        Task { await debouncer.signal() }
    }
    func stop() {
        watcher?.cancel()
        watcher = nil
        busTask?.cancel()
        busTask = nil
        occlusionTask?.cancel()
        occlusionTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        scheduledDeadline = nil
        started = false
        watchedPaths = []
        watchGeneration &+= 1
        let stoppedGeneration = watchGeneration
        // If a new root activates before this actor hop executes, that new
        // activation owns visibility/dirty state.  Do not let an old stop
        // cancel its initial refresh.
        Task { [weak self] in
            guard let self, !self.started, self.watchGeneration == stoppedGeneration else { return }
            await self.debouncer.cancel()
        }
    }
    private func refreshWindowVisibility() {
        windowVisible = visibilityResolver()
        Self.trace("refreshWindowVisibility -> \(windowVisible)")
        updateVisibility()
    }
    private func updateVisibility() {
        // sceneActive deliberately does NOT gate: on macOS the scene goes
        // inactive whenever another app is frontmost, which is exactly the
        // background-glance case this reloader serves (proven live 2026-08-27:
        // with the window-facts resolver already fixed, the desk still only
        // loaded once the app was activated). Window visibility alone owns
        // pausing — occluded, minimized, and closed all read as not visible.
        // setSceneActive stays as a refresh trigger for the window facts.
        let value = viewVisible && windowVisible
        Self.trace("updateVisibility view=\(viewVisible) window=\(windowVisible) -> \(value)")
        if value != effectivelyVisible {
            effectivelyVisible = value
            Self.logger.notice("visibility active=\(value, privacy: .public)")
        }
        Task { await debouncer.setVisible(value) }
    }
    private func performReload() async {
        Self.trace("performReload viewVisible=\(viewVisible) reloadNil=\(reload == nil)")
        guard viewVisible, let reload else {
            // A visibility update can cross the actor hop just after a pending
            // fire. Preserve the edge for the next activation instead of
            // consuming it against a view that has already disappeared.
            await debouncer.signal()
            return
        }
        reloadSequence &+= 1
        let sequence = reloadSequence
        let clock = ContinuousClock()
        let startedAt = clock.now
        Self.logger.notice("reload begin sequence=\(sequence, privacy: .public)")
        await reload()
        let elapsed = startedAt.duration(to: clock.now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        Self.logger.notice(
            "reload complete sequence=\(sequence, privacy: .public) duration_ms=\(milliseconds, privacy: .public)"
        )
        Self.trace("reload complete ms=\(milliseconds)")
    }

    deinit {
        watcher?.cancel()
        busTask?.cancel()
        occlusionTask?.cancel()
        deadlineTask?.cancel()
    }
}
