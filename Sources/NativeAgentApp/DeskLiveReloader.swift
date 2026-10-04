import AppKit
import Foundation
import OSLog
import PersistenceCore

@MainActor
final class DeskLiveReloader {
    static let shared = DeskLiveReloader()
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "workshop-live")
    /// Each mounted page owns its callback, visibility, coalescing and deadline.
    /// FileChangeWatcher already pools identical paths across subscriptions.
    private var subscribers: [UUID: DeskLiveReloader] = [:]
    private var watcher: FileChangeWatcher?
    private var busTask: Task<Void, Never>?
    private var occlusionTask: Task<Void, Never>?
    /// One exact presentation boundary (Desk snapshot stale / live row aged
    /// out). This is deliberately not a repeating timer: file/store edges are
    /// still the only ongoing live-update source.
    private var deadlineTask: Task<Void, Never>?
    private var scheduledDeadline: Date?
    private var viewVisible = false
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
    nonisolated static let tracePath = NSTemporaryDirectory() + InstallPaths.current.name("nativeagent-desk-reloader-trace.log")
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

    /// Binding or removing one page never replaces another page's lifecycle.
    @discardableResult
    func activate(
        subscriber id: UUID,
        paths: [URL],
        reload: @escaping @MainActor @Sendable () async -> Void
    ) -> String? {
        let subscriber = subscribers[id] ?? DeskLiveReloader(
            debounceDelay: debounceDelay, visibilityResolver: visibilityResolver)
        subscribers[id] = subscriber
        subscriber.reload = reload
        let normalized = Set(paths.map(\.standardizedFileURL))
        let changed = !subscriber.started || subscriber.watchedPaths != normalized
        Self.trace("activate subscriber=\(id) paths=\(paths.count) changed=\(changed)")
        guard subscriber.start(paths: paths) else {
            subscriber.setViewVisible(false)
            return subscriber.configurationError
        }
        subscriber.setViewVisible(true)
        // Initial binding and newly discovered record paths each need one
        // registration-race read. An unchanged binding adds no dirty edge.
        if changed { subscriber.sourceDidChange() }
        return nil
    }

    func deactivate(subscriber id: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        Self.trace("deactivate subscriber=\(id)")
        subscriber.setViewVisible(false)
        subscriber.reload = nil
        subscriber.stop()
    }

    func refreshVisibility(subscriber id: UUID) {
        subscribers[id]?.refreshWindowVisibility()
    }

    func sourceDidChange(subscriber id: UUID) {
        subscribers[id]?.sourceDidChange()
    }

    func scheduleRefresh(subscriber id: UUID, at deadline: Date?) {
        subscribers[id]?.scheduleRefresh(at: deadline)
    }

    @discardableResult
    private func start(paths: [URL]) -> Bool {
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

    private func setViewVisible(_ value: Bool) { Self.trace("setViewVisible \(value)"); viewVisible = value; updateVisibility() }
    /// Schedule the next semantic freshness transition. Replacing the value
    /// replaces the single sleeper; nil cancels it. If the deadline fires while
    /// hidden, StoreReloadDebouncer retains one dirty edge for the next visible
    /// activation exactly as it does for a file change.
    private func scheduleRefresh(at deadline: Date?) {
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
    private func sourceDidChange() {
        Task { await debouncer.signal() }
    }
    private func stop() {
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
        // Scene changes only refresh the window facts.
        let value = viewVisible && windowVisible
        Self.trace("updateVisibility view=\(viewVisible) window=\(windowVisible) -> \(value)")
        if value != effectivelyVisible {
            effectivelyVisible = value
            Self.logger.notice("visibility active=\(value, privacy: .public)")
        }
        Task { [weak self] in
            guard let self else { return }
            await self.debouncer.setVisible(self.started && self.viewVisible && self.windowVisible)
        }
    }
    private func performReload() async {
        Self.trace("performReload viewVisible=\(viewVisible) reloadNil=\(reload == nil)")
        guard started, viewVisible, let reload else { return }
        guard windowVisible else {
            // A visibility update can cross the actor hop just after a pending
            // fire. Preserve the edge for the next glance instead of consuming
            // it against a window that has already become hidden.
            await debouncer.setVisible(started && viewVisible && windowVisible)
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
