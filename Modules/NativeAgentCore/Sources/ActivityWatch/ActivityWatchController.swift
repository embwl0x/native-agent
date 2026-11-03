#if canImport(AppKit)
import Foundation
import Experiences
import Observation
import PersistenceCore
import NativeAgentCore
// Blueprint: | `ActivityWatchController.swift` | `ActivityWatchController`, `ActivityCaptureIssue`; last-checked policy and explicit availability, serialized writes and capture-ordered exclusion purges; exact policy/cadence events rearm checked retention, failed passes retain their issue and retry on the runner's interval without advancing its completed-run stamp; termination retains the watcher's eventual settlement alongside startup, policy and event bodies; issues join Experience receipts; Trust controls, quiet settings and the running indicator reach this owner through engine.activityWatch |

public struct ActivityCaptureIssue: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Equatable, Sendable {
        case notice = 0
        case warning = 1
        case critical = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: UUID
    public let occurredAt: Date
    public let severity: Severity
    public let message: String
}

/// The single owner of the ambient activity watcher's lifecycle and policy.
///
/// One object holds the policy, the store, the watcher and the retention
/// runner, and it is the single place the Trust Center panel, the menu-bar
/// indicator and app launch all talk to. That matters more than it looks:
/// a capture organ with two owners is a capture organ that keeps running after
/// one of them has been told to stop.
///
/// **The invariant this type exists to hold:** `isCapturing` is TRUE if and
/// only if `ActivityWatcher` reports a running capture service. It is not a
/// separate belief about what should be happening — it is read straight off the
/// watcher. A failed required attachment reports degraded capture even while
/// workspace/timer sources remain installed to observe its recovery.
@MainActor
@Observable
public final class ActivityWatchController {
    public enum PolicyAvailability: Equatable, Sendable {
        case loading
        case available
        case unavailable(String)
    }
    public enum DeletionResult: Sendable {
        case deleted(rows: Int)
        case failed(message: String)
    }

    /// The live policy. Every mutation goes through `apply(_:)`, which writes
    /// to disk FIRST and only then tells the watcher — so a crash between the
    /// two leaves capture off-or-unchanged rather than running under a policy
    /// nothing recorded.
    public private(set) var policy: ActivityPolicy
    /// `policy` retains its last checked values on failure; these are not current authority.
    public private(set) var policyAvailability: PolicyAvailability = .loading
    public var isPolicyAvailable: Bool { policyAvailability == .available }
    /// Initial UI storage is not a checked policy. The first successful read
    /// (even after repair) establishes saved consent; later external changes
    /// obey the tightening-only rule against that established snapshot.
    private var hasCheckedPolicy = false

    /// True while the watcher reports a running capture service. Drives the
    /// menu-bar indicator.
    public private(set) var isCapturing = false

    /// Bounded, ordered failure history. A benign later failure must not erase
    /// the more consequential capture-stop or failed-purge evidence.
    public private(set) var issues: [ActivityCaptureIssue] = []

    public var lastError: String? { primaryIssue?.message }
    public var primaryIssue: ActivityCaptureIssue? {
        presentationIssues.first
    }

    /// Highest impact first, then newest within one severity. This is the
    /// user-facing order and makes a later harmless notice unable to bury a
    /// capture-stop or failed-purge failure.
    public var presentationIssues: [ActivityCaptureIssue] {
        issues.sorted {
            $0.severity == $1.severity
                ? $0.occurredAt > $1.occurredAt
                : $0.severity > $1.severity
        }
    }

    /// Rows purged by the most recent retro-delete or wipe, for the UI to
    /// report honestly ("removed 412 recorded spans").
    public private(set) var lastPurgedRowCount: Int?

    private let dataRoot: URL
    private let policyStore: ActivityPolicyStore
    private let errorMessage: @MainActor (Error, String) -> String
    private let errorCause: @MainActor (Error, String) -> String
    private let criticalIssueNotifier: @MainActor (ActivityCaptureIssue) -> Void
    private var spanStore: ActivitySpanStore?
    @ObservationIgnored private var policyTask: Task<Bool, Never>?
    private var shuttingDown = false
    private var watcher: ActivityWatcher?
    private var startupTask: Task<Void, Never>?
    private var policyEventsTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var retentionEventsTask: Task<Void, Never>?
    @ObservationIgnored private var terminationDrain: Task<Void, Never>?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        errorMessage: @escaping @MainActor (Error, String) -> String,
        errorCause: @escaping @MainActor (Error, String) -> String,
        criticalIssueNotifier: @escaping @MainActor (ActivityCaptureIssue) -> Void = { _ in }
    ) {
        self.dataRoot = dataRoot
        self.policyStore = ActivityPolicyStore(dataRoot: dataRoot)
        self.errorMessage = errorMessage
        self.errorCause = errorCause
        self.criticalIssueNotifier = criticalIssueNotifier
        self.policy = ActivityPolicy()
        policyTask = Task { [policyStore] in
            do {
                policy = try await Task.detached(priority: .utility) { try policyStore.loadChecked() }.value
                hasCheckedPolicy = true
                policyAvailability = .available
                return true
            } catch {
                let message = errorMessage(error, "read the activity policy")
                policyAvailability = .unavailable(message)
                await recordIssue(message, severity: .critical)
                return false
            }
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
    /// `startBounded()` refuses to *install observers*, but reaching it means
    /// constructing the store, which CREATES the SQLite file. Returning
    /// first means a fresh install with capture off never opens that file at
    /// all, so the disk carries no activity store until consent exists. The
    /// inner gate protects the observers; this one protects the filesystem.
    public func startAtLaunch() {
        guard !shuttingDown else { return }
        if policyEventsTask == nil {
            let events = FileChangeEvents(paths: [policyStore.fileURL], emitInitial: true)
            policyEventsTask = Task { @MainActor [weak self] in
                defer { events.cancel() }
                for await _ in events.stream {
                    guard let self else { return }
                    await self.reloadPolicy()
                }
            }
        }
        if retentionTask == nil {
            scheduleRetention()
        }
        if retentionEventsTask == nil {
            let events = FileChangeEvents(paths: [ActivityWatchPaths.retentionStateURL(dataRoot: dataRoot)])
            retentionEventsTask = Task { @MainActor [weak self] in
                defer { events.cancel() }
                for await _ in events.stream {
                    guard let self, !self.shuttingDown else { return }
                    self.scheduleRetention()
                }
                guard let self, !Task.isCancelled, !self.shuttingDown else { return }
                self.retentionTask?.cancel()
                await self.recordIssue("Activity retention file observation is unavailable. Cleanup is paused; reopen NativeAgent after repairing the cadence path to rearm observation.", severity: .warning)
            }
        }
        startCapture()
    }

    private func startCapture() {
        guard startupTask == nil else { return }
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startupTask = nil }
            _ = await self.policyTask?.value
            guard !Task.isCancelled, !self.shuttingDown, self.isPolicyAvailable,
                  self.policy.captureEnabled else { return }
            guard let watcher = await self.ensureWatcher(), !Task.isCancelled,
                  self.isPolicyAvailable, self.policy.captureEnabled else { return }
            let started = await watcher.startBounded()
            guard !Task.isCancelled else { return }
            self.refreshCapturingFlag()
            if !started {
                await self.recordIssue("Activity capture did not reach running state. Check the activity capture notices; its lifecycle retains any unfinished shutdown.", severity: .critical)
            }
            self.scheduleRetention()
        }
    }

    public func shutdown() async {
        await makeTerminationDrain().value
        refreshCapturingFlag()
    }

    /// Starts the termination drain while the main actor is still available
    /// and returns a handle that can be joined from the app delegate's bounded
    /// shutdown group. `applicationWillTerminate` blocks the main thread while
    /// that group drains, so scheduling `shutdown()` itself on `@MainActor`
    /// would deadlock until the group timed out and never begin the watcher
    /// teardown in time. Capturing the Sendable watcher here lets the actual
    /// stop run independently; UI state no longer matters once termination has
    /// begun.
    public func makeTerminationDrain() -> Task<Void, Never> {
        if let terminationDrain { return terminationDrain }
        shuttingDown = true
        let startup = startupTask
        let events = policyEventsTask
        let retention = retentionTask
        let retentionEvents = retentionEventsTask
        let policy = policyTask
        startup?.cancel()
        events?.cancel()
        retention?.cancel()
        retentionEvents?.cancel()
        policy?.cancel()
        let watcher = watcher
        let drain = Task.detached(priority: .utility) {
            await settle {
                if let watcher {
                    let request = await watcher.requestStop()
                    if request.outcome == .settlementPending {
                        FileHandle.standardError.write(Data("activity-watch: stop request bounded; settlement pending\n".utf8))
                    }
                    await request.settlement?.value
                }
                await startup?.value
                await events?.value
                await retention?.value
                await retentionEvents?.value
                _ = await policy?.value
            }
        }
        terminationDrain = drain
        return drain
    }

    private func ensureWatcher() async -> ActivityWatcher? {
        if let watcher { return watcher }
        do {
            guard let store = try await ActivitySpanStore.acquire(dataRoot: dataRoot),
                  !Task.isCancelled else { return nil }
            await reloadPolicy()
            guard !shuttingDown, !Task.isCancelled, isPolicyAvailable, policy.captureEnabled else { return nil }
            if let watcher { return watcher }
            let created = ActivityWatcher(
                store: store,
                policy: policy,
                lifecycleChanged: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.refreshCapturingFlag()
                        if state == .degraded {
                            await self?.recordIssue("Activity capture is degraded; it is not reporting a running capture service. Observation repair or unfinished shutdown remains owned by the watcher.", severity: .critical)
                        }
                    }
                },
                observationIssue: { [weak self] detail in
                    Task { @MainActor [weak self] in
                        await self?.recordIssue(detail, severity: .warning)
                    }
                }
            )
            spanStore = store
            watcher = created
            return created
        } catch {
            await recordIssue(errorMessage(error, "open the activity store"), severity: .critical)
            return nil
        }
    }

    private func refreshCapturingFlag() {
        isCapturing = watcher?.isCapturing ?? false
    }

    private func reloadPolicy() async {
        let previous = policyTask
        let task = Task { [self] in
            _ = await previous?.value
            guard !shuttingDown else { return false }
            let loaded: ActivityPolicy
            do {
                let policyStore = policyStore
                loaded = try await Task.detached(priority: .utility) { try policyStore.loadChecked() }.value
            } catch {
                let message = errorMessage(error, "read the activity policy")
                policyAvailability = .unavailable(message)
                await watcher?.policyUnavailable()
                refreshCapturingFlag()
                await recordIssue(message, severity: .critical)
                return false
            }
            guard !shuttingDown else { return false }
            if !hasCheckedPolicy {
                policy = loaded
                hasCheckedPolicy = true
                policyAvailability = .available
                if loaded.captureEnabled { startCapture() }
                scheduleRetention()
                return true
            }
            let wasAvailable = isPolicyAvailable
            guard let safe = ActivityWatcher.safelyPolled(
                loaded, current: policy, currentlyEnabled: policy.captureEnabled
            ) else {
                // A readable external enable is still not consent. Keep the
                // existing choices and require a settings decision to enable.
                policyAvailability = .available
                scheduleRetention()
                return true
            }
            policyAvailability = .available
            scheduleRetention()
            guard safe != policy || !wasAvailable else { return true }
            policy = safe
            watcher?.updatePolicy(safe)
            refreshCapturingFlag()
            return true
        }
        policyTask = task
        _ = await task.value
    }

    /// The store, but ONLY if it already exists on disk.
    ///
    /// Opening a new `ActivitySpanStore` is not a read — it CREATES the
    /// directory and the SQLite file. Using it to answer "is there anything to
    /// purge?" would therefore manufacture the very thing it is asking about:
    /// hitting Exclude or Wipe on a fresh install, with capture never once
    /// enabled, would leave an empty activity_spans.sqlite on disk. That breaks
    /// the promise `startAtLaunch` makes — no activity store until consent
    /// exists — and it is exactly the sort of file a privacy-minded user would
    /// find later and reasonably assume had been recording.
    private func existingStore() async throws -> ActivitySpanStore? {
        if let spanStore { return spanStore }
        let store = try await ActivitySpanStore.acquire(dataRoot: dataRoot, existingOnly: true)
        spanStore = store
        return store
    }

    // MARK: - Policy mutation

    /// Settings readers await the same serialized policy owner; stale checked
    /// choices are never presented as current consent while authority is unavailable.
    public func checkedPolicy() async throws -> ActivityPolicy {
        _ = await policyTask?.value
        guard isPolicyAvailable else {
            if case .unavailable(let detail) = policyAvailability {
                throw ActivityPolicyStore.StoreError.unavailable(detail)
            }
            throw ActivityPolicyStore.StoreError.unavailable("the initial read has not completed")
        }
        return policy
    }

    /// The ONE write path. Persists, then propagates.
    ///
    /// Order is load-bearing. The policy file is what `activity_query` and a
    /// future launch both read; if the watcher were told first and the write
    /// then failed, the running process would be capturing under a policy that
    /// no longer exists on disk — invisible, and wrong in the dangerous
    /// direction.
    @discardableResult
    public func apply(_ change: @escaping @MainActor (inout ActivityPolicy) -> Void) async -> Bool {
        guard !shuttingDown else { return false }
        let previous = policyTask
        let task = Task { [self] in
            _ = await previous?.value
            guard isPolicyAvailable else { return false }
            var next = policy
            change(&next)
            return await persist(next)
        }
        policyTask = task
        return await task.value
    }

    private func persist(_ next: ActivityPolicy) async -> Bool {
        do {
            let policyStore = policyStore
            try await Task.detached(priority: .utility) { try policyStore.save(next) }.value
        } catch {
            await recordIssue(errorMessage(error, "save the activity policy"), severity: .critical)
            return false
        }
        policy = next
        hasCheckedPolicy = true
        policyAvailability = .available
        guard !shuttingDown else { return true }

        if let watcher {
            // The watcher fences capture immediately, before asynchronous teardown.
            watcher.updatePolicy(next)
        } else if next.captureEnabled {
            startCapture()
        }
        // Lifecycle invalidations keep this exact after asynchronous teardown;
        // this immediate read covers the mutation edge itself without a timer.
        refreshCapturingFlag()
        scheduleRetention()
        return true
    }

    public func setCaptureEnabled(_ enabled: Bool) async {
        await apply { $0.captureEnabled = enabled }
    }

    public func setModelAccessEnabled(_ enabled: Bool) async {
        await apply { $0.allowModelAccess = enabled }
    }

    public func setRetentionDays(_ days: Int) async {
        guard await apply({ $0.retentionDays = max(1, min(365, days)) }) else { return }
        scheduleRetention()
    }

    // MARK: - Exclusions (W5 layer 3 — retro-delete)

    /// Adding an exclusion RETRO-DELETES that app's existing rows.
    ///
    /// This is the promise the UI makes before the user confirms, and it is
    /// kept through the store's own purge path — which checkpoints the WAL and
    /// VACUUMs, because rows deleted but still legible in the `-wal` sidecar
    /// are not deleted, they are hidden. The policy slot covers the purge too;
    /// the watcher orders it after applying the exclusion and older writes.
    public func addExclusion(bundleID: String) async {
        guard !shuttingDown else { return }
        lastPurgedRowCount = nil
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = policyTask
        let task = Task { [self] in
            _ = await previous?.value
            guard isPolicyAvailable else { return false }
            var next = policy
            next.excludedBundleIDs.insert(trimmed)
            // Never purge rows unless the exclusion first became durable.
            guard await persist(next) else { return false }
            do {
                if let watcher {
                    lastPurgedRowCount = try await watcher.purgeExcluded(bundleID: trimmed)
                } else {
                    // An absent store has no rows; an unavailable store throws.
                    lastPurgedRowCount = try await existingStore()?.purge(bundleID: trimmed) ?? 0
                }
            } catch {
                await recordIssue("Excluded \(trimmed), but couldn't delete what was already recorded. " + errorCause(error, "delete excluded activity rows"), severity: .critical)
            }
            return true
        }
        policyTask = task
        _ = await task.value
    }

    public func removeExclusion(bundleID: String) async {
        await apply { $0.excludedBundleIDs.remove(bundleID) }
    }

    /// Bundle ids the user may remove. The non-overridable set (loginwindow,
    /// NativeAgent itself) is filtered out because offering a control that
    /// silently does nothing is worse than not offering it.
    public var removableExclusions: [String] {
        policy.excludedBundleIDs
            .subtracting(ActivityPolicy.alwaysExcludedBundleIDs)
            .sorted()
    }

    // MARK: - Wipe / retention

    /// Deletes every recorded span. The policy survives — this is "forget what
    /// you saw", not "reset my settings", and conflating the two would silently
    /// re-enable capture defaults the user had changed.
    @discardableResult
    public func wipeAll() async -> DeletionResult {
        lastPurgedRowCount = nil
        do {
            let removed: Int
            if let watcher {
                removed = try await watcher.wipeAll()
            } else {
                removed = try await existingStore()?.wipeAll() ?? 0
            }
            lastPurgedRowCount = removed
            return .deleted(rows: removed)
        } catch {
            let message = errorMessage(error, "wipe recorded activity")
            await recordIssue(message, severity: .critical)
            return .failed(message: message)
        }
    }

    private enum RetentionPass {
        case checked
        case retry
        case paused
    }

    private func scheduleRetention() {
        guard !shuttingDown else { return }
        let previous = retentionTask
        previous?.cancel()
        retentionTask = Task { @MainActor [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                let delay: TimeInterval
                switch await self.runRetention() {
                case .paused:
                    return
                case .retry:
                    // A failed pass owes another attempt, not a completed-run
                    // stamp. Its old due time may already be past; do not spin.
                    delay = ActivityRetentionRunner.defaultInterval
                case .checked:
                    do { delay = try ActivityRetentionRunner(dataRoot: self.dataRoot).nextRunDelay() }
                    catch {
                        await self.recordIssue("Activity retention is paused until its saved cadence is repaired. " + self.errorCause(error, "read retention cadence"), severity: .warning)
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }

    private func runRetention() async -> RetentionPass {
        _ = await policyTask?.value
        guard isPolicyAvailable, !Task.isCancelled else { return .paused }
        let runner = ActivityRetentionRunner(dataRoot: dataRoot)
        do {
            let policyStore = policyStore
            let current = try await Task.detached(priority: .utility) { try policyStore.loadChecked() }.value
            guard let store = try await existingStore() else { return .paused }
            try await runner.runIfDue(
                store: store,
                policy: policy.captureEnabled ? policy : current,
                now: Date().timeIntervalSince1970
            )
            return .checked
        } catch {
            // Retention failure does not expand collection authority, but it
            // does leave older local rows in place and must stay visible.
            await recordIssue(
                "Activity retention could not complete this pass; cleanup will retry in six hours. Repair its policy, cadence or store if the problem persists. " + errorCause(error, "remove expired activity rows"),
                severity: .warning
            )
            return .retry
        }
    }

    public func recordIssue(_ message: String, severity: ActivityCaptureIssue.Severity) async {
        guard issues.last?.message != message else { return }
        let issue = ActivityCaptureIssue(id: UUID(), occurredAt: Date(), severity: severity, message: message)
        issues.append(issue)
        if issues.count > 12 { issues = Array(presentationIssues.prefix(12)) }
        if issue.severity == .critical {
            criticalIssueNotifier(issue)
        }
        await ExperienceStore.record(dataRoot, issue.id.uuidString) { store in
            try await store.begin(Experience(id: issue.id.uuidString, kind: .run,
                outcome: .init(domain: "activity_watch", status: "failed", effects: .unknown),
                face: .init(words: issue.message, artifacts: [])))
        }.value
    }
}
#endif
