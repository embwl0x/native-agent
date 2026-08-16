import Foundation
import Observation
import ActivityWatch
import PersistenceCore

/// W8 — the app-side owner of the ambient activity watcher's lifecycle.
///
/// One object holds the policy, the store, the watcher and the retention
/// runner, and it is the single place the Trust Center panel, the menu-bar
/// indicator and app launch all talk to. That matters more than it looks:
/// a capture organ with two owners is a capture organ that keeps running after
/// one of them has been told to stop.
///
/// **The invariant this type exists to hold:** `isCapturing` is TRUE if and
/// only if `ActivityWatcher` currently has observers installed. It is not a
/// separate belief about what should be happening — it is read straight off the
/// watcher. That is what makes the menu-bar dot honest: it cannot say "not
/// recording" while the observers are live, because it has no state of its own
/// in which to be wrong.
@MainActor
@Observable
final class ActivityWatchController {
    static let shared = ActivityWatchController()

    /// The live policy. Every mutation goes through `apply(_:)`, which writes
    /// to disk FIRST and only then tells the watcher — so a crash between the
    /// two leaves capture off-or-unchanged rather than running under a policy
    /// nothing recorded.
    private(set) var policy: ActivityPolicy

    /// True while the watcher actually has observers installed. Drives the
    /// menu-bar indicator.
    private(set) var isCapturing = false

    /// Last error surfaced to the UI (store open failure, policy write
    /// failure). Never a silent swallow: a capture toggle that fails to save
    /// and says nothing is the worst possible outcome for this feature.
    private(set) var lastError: String?

    /// Rows purged by the most recent retro-delete or wipe, for the UI to
    /// report honestly ("removed 412 recorded spans").
    private(set) var lastPurgedRowCount: Int?

    private let dataRoot: URL
    private let policyStore: ActivityPolicyStore
    private var spanStore: ActivitySpanStore?
    private var watcher: ActivityWatcher?

    init(dataRoot: URL = NativeAgentPaths.dataRoot) {
        self.dataRoot = dataRoot
        self.policyStore = ActivityPolicyStore(dataRoot: dataRoot)
        do {
            self.policy = try policyStore.loadChecked()
            self.lastError = nil
        } catch {
            self.policy = ActivityPolicy()
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Lifecycle

    /// Called once at app launch.
    ///
    /// There are deliberately TWO gates here, and the usual objection to that —
    /// a second gate can drift out of agreement with the first — does not apply,
    /// because both read the same `policy.captureEnabled` field rather than two
    /// separate beliefs about it. They cannot disagree; they can only both be
    /// off or both be on.
    ///
    /// The outer gate earns its place by buying something the inner one cannot:
    /// `ActivityWatcher.start()` refuses to *install observers*, but reaching it
    /// means constructing the store, which CREATES the SQLite file. Returning
    /// first means a fresh install with capture off never opens that file at
    /// all, so the disk carries no activity store until consent exists. The
    /// inner gate protects the observers; this one protects the filesystem.
    func startAtLaunch() {
        guard policy.captureEnabled else {
            // Nothing to start, and deliberately nothing constructed either:
            // a fresh install with capture off never even opens the SQLite
            // file, so the disk shows no activity store until consent exists.
            isCapturing = false
            return
        }
        guard let watcher = ensureWatcher() else { return }
        Task { @MainActor [weak self, weak watcher] in
            guard let self, let watcher else { return }
            if !(await watcher.startBounded()) {
                self.lastError = "Activity capture could not start cleanly. Its partial startup was rolled back."
            }
            self.refreshCapturingFlag()
        }
        refreshCapturingFlag()
    }

    func shutdown() async {
        await watcher?.stop()
        refreshCapturingFlag()
    }

    private func ensureWatcher() -> ActivityWatcher? {
        if let watcher { return watcher }
        do {
            let store = try ActivitySpanStore(dataRoot: dataRoot)
            // Watches the policy FILE as well as taking direct updates, so a
            // change written by another process (or another window) is picked
            // up within one tick rather than at next launch.
            let created = ActivityWatcher(
                store: store,
                policy: policy,
                policySource: ActivityPolicyFileSource(dataRoot: dataRoot),
                lifecycleChanged: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.refreshCapturingFlag()
                        if state == .degraded {
                            self?.lastError = "Activity capture stopped because its live watcher became unavailable."
                        }
                    }
                },
                policyChanged: { [weak self] applied in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.policy = applied
                        do {
                            _ = try self.policyStore.loadChecked()
                        } catch {
                            self.lastError = error.localizedDescription
                        }
                    }
                }
            )
            spanStore = store
            watcher = created
            lastError = nil
            return created
        } catch {
            lastError = "Could not open the activity store: \(error.localizedDescription)"
            return nil
        }
    }

    private func refreshCapturingFlag() {
        isCapturing = watcher?.isCapturing ?? false
    }

    /// The store, but ONLY if it already exists on disk.
    ///
    /// `try? ActivitySpanStore(dataRoot:)` is not a read — it CREATES the
    /// directory and the SQLite file. Using it to answer "is there anything to
    /// purge?" would therefore manufacture the very thing it is asking about:
    /// hitting Exclude or Wipe on a fresh install, with capture never once
    /// enabled, would leave an empty activity_spans.sqlite on disk. That breaks
    /// the promise `startAtLaunch` makes — no activity store until consent
    /// exists — and it is exactly the sort of file a privacy-minded user would
    /// find later and reasonably assume had been recording.
    private func existingStore() -> ActivitySpanStore? {
        if let spanStore { return spanStore }
        guard FileManager.default.fileExists(
            atPath: ActivityWatchPaths.databaseURL(dataRoot: dataRoot).path
        ) else { return nil }
        let store = try? ActivitySpanStore(dataRoot: dataRoot)
        spanStore = store
        return store
    }

    // MARK: - Policy mutation

    /// The ONE write path. Persists, then propagates.
    ///
    /// Order is load-bearing. The policy file is what `activity_query` and a
    /// future launch both read; if the watcher were told first and the write
    /// then failed, the running process would be capturing under a policy that
    /// no longer exists on disk — invisible, and wrong in the dangerous
    /// direction.
    @discardableResult
    func apply(_ next: ActivityPolicy) -> Bool {
        do {
            try policyStore.save(next)
        } catch {
            lastError = "Could not save the activity policy: \(error.localizedDescription)"
            return false
        }
        lastError = nil
        policy = next

        if next.captureEnabled {
            guard let watcher = ensureWatcher() else { return false }
            watcher.updatePolicy(next)
        } else if let watcher {
            // INSTANT PAUSE. updatePolicy tears the observers down and closes
            // the open span; we do not wait for it before flipping the
            // indicator, because the user's question is "did it stop", and the
            // honest answer the moment capture is disallowed is yes.
            watcher.updatePolicy(next)
        }
        // Lifecycle invalidations keep this exact after asynchronous teardown;
        // this immediate read covers the mutation edge itself without a timer.
        refreshCapturingFlag()
        return true
    }

    func setCaptureEnabled(_ enabled: Bool) {
        var next = policy
        next.captureEnabled = enabled
        apply(next)
    }

    func setCaptureTitles(_ enabled: Bool) {
        var next = policy
        next.captureTitles = enabled
        apply(next)
    }

    func setBrowserTitlesEnabled(_ enabled: Bool) {
        var next = policy
        next.browserTitlesEnabled = enabled
        apply(next)
    }

    func setAppNameOnlyMode(_ enabled: Bool) {
        var next = policy
        next.appNameOnlyMode = enabled
        apply(next)
    }

    func setModelAccessEnabled(_ enabled: Bool) {
        var next = policy
        next.allowModelAccess = enabled
        apply(next)
    }

    func setRetentionDays(_ days: Int) {
        var next = policy
        next.retentionDays = max(1, min(365, days))
        guard apply(next) else { return }
        Task { await runRetention() }
    }

    // MARK: - Exclusions (W5 layer 3 — retro-delete)

    /// Adding an exclusion RETRO-DELETES that app's existing rows.
    ///
    /// This is the promise the UI makes before the user confirms, and it is
    /// kept through the store's own purge path — which checkpoints the WAL and
    /// VACUUMs, because rows deleted but still legible in the `-wal` sidecar
    /// are not deleted, they are hidden.
    func addExclusion(bundleID: String) async {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = policy
        next.excludedBundleIDs.insert(trimmed)
        // Never purge rows unless the exclusion first became durable.
        guard apply(next) else { return }

        guard let store = existingStore() else {
            // Nothing on disk to purge — capture has never been on, so no store
            // was ever created. Not an error, and NOT a reason to create one.
            lastPurgedRowCount = 0
            return
        }
        do {
            lastPurgedRowCount = try await store.purge(bundleID: trimmed)
        } catch {
            lastError = "Excluded \(trimmed), but could not delete its recorded rows: \(error.localizedDescription)"
        }
    }

    func removeExclusion(bundleID: String) {
        var next = policy
        next.excludedBundleIDs.remove(bundleID)
        apply(next)
    }

    /// Bundle ids the user may remove. The non-overridable set (loginwindow,
    /// NativeAgent itself) is filtered out because offering a control that
    /// silently does nothing is worse than not offering it.
    var removableExclusions: [String] {
        policy.excludedBundleIDs
            .subtracting(ActivityPolicy.alwaysExcludedBundleIDs)
            .sorted()
    }

    // MARK: - Wipe / retention

    /// Deletes every recorded span. The policy survives — this is "forget what
    /// you saw", not "reset my settings", and conflating the two would silently
    /// re-enable capture defaults the user had changed.
    func wipeAll() async {
        guard let store = existingStore() else {
            // Nothing recorded, nothing to forget.
            lastPurgedRowCount = 0
            return
        }
        do {
            lastPurgedRowCount = try await store.wipeAll()
        } catch {
            lastError = "Wipe failed: \(error.localizedDescription)"
        }
    }

    func runRetention() async {
        guard let store = spanStore else { return }
        let runner = ActivityRetentionRunner(dataRoot: dataRoot)
        _ = try? await runner.runIfDue(
            store: store,
            policy: policy,
            now: Date().timeIntervalSince1970
        )
    }
}
