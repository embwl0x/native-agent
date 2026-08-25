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

    init(
        debounceDelay: Duration = .milliseconds(500),
        visibilityResolver: @escaping @MainActor @Sendable () -> Bool = {
            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                return window.isVisible && window.occlusionState.contains(.visible)
            }
            return NSApp.isActive
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
        guard start(paths: paths) else {
            setViewVisible(false)
            return configurationError
        }
        setViewVisible(true)
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

    func setViewVisible(_ value: Bool) { viewVisible = value; updateVisibility() }
    func setSceneActive(_ value: Bool) { sceneActive = value; refreshWindowVisibility(); updateVisibility() }
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
        updateVisibility()
    }
    private func updateVisibility() {
        let value = viewVisible && sceneActive && windowVisible
        if value != effectivelyVisible {
            effectivelyVisible = value
            Self.logger.notice("visibility active=\(value, privacy: .public)")
        }
        Task { await debouncer.setVisible(value) }
    }
    private func performReload() async {
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
    }

    deinit {
        watcher?.cancel()
        busTask?.cancel()
        occlusionTask?.cancel()
    }
}
