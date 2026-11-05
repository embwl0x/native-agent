#if canImport(AppKit)
import Foundation
import Experiences
import Observation
import PersistenceCore
import NativeAgentCore
// Blueprint: | `ActivityWatchController.swift` | `ActivityWatchController`, `ActivityCaptureIssue`: policy, lifecycle, ordered purge and retention |

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

/// One owner serves launch, Trust and the indicator so stopping capture cannot leave another owner running.
/// Read isCapturing from the watcher; required observation failure is degraded even with recovery sources installed.
@MainActor
@Observable
public final class ActivityWatchController {
    public static let didChange = Notification.Name("NativeAgent.activityWatchDidChange")
    public enum PolicyAvailability: Equatable, Sendable {
        case loading
        case available
        case unavailable(String)
    }
    public enum DeletionResult: Sendable {
        case deleted(rows: Int)
        case failed(message: String)
    }

    /// Persist policy before propagating it so a crash cannot leave capture running under unrecorded consent.
    public private(set) var policy: ActivityPolicy
    /// `policy` retains its last checked values on failure; these are not current authority.
    public private(set) var policyAvailability: PolicyAvailability = .loading
    public var isPolicyAvailable: Bool { policyAvailability == .available }
    /// Initial UI defaults are not consent; tighten external changes against the first checked saved policy.
    private var hasCheckedPolicy = false

    public private(set) var isCapturing = false

    /// Bound failure history without letting a later benign notice erase capture-stop or purge evidence.
    public private(set) var issues: [ActivityCaptureIssue] = []

    public var lastError: String? { primaryIssue?.message }
    public var primaryIssue: ActivityCaptureIssue? {
        presentationIssues.first
    }

    /// Sort by impact then recency so harmless notices cannot bury consequential failures.
    public var presentationIssues: [ActivityCaptureIssue] {
        issues.sorted {
            $0.severity == $1.severity
                ? $0.occurredAt > $1.occurredAt
                : $0.severity > $1.severity
        }
    }

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

    /// Gate before store construction as well as observer installation: capture-off must create no activity database.
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
                await self.recordIssue(
                    """
                    Activity retention file observation is unavailable. Cleanup is paused; reopen NativeAgent after repairing the cadence path \
                    to rearm observation.
                    """,
                    severity: .warning
                )
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
                await self.recordIssue(
                    "Activity capture did not reach running state. Check the activity capture notices; its lifecycle retains any unfinished shutdown.",
                    severity: .critical
                )
            }
            self.scheduleRetention()
        }
    }

    public func shutdown() async {
        await makeTerminationDrain().value
        refreshCapturingFlag()
    }

    /// Start watcher settlement before termination blocks the main actor; scheduling teardown there would deadlock.
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
                            await self?.recordIssue(
                                """
                                Activity capture is degraded; it is not reporting a running capture service. Observation repair or unfinished \
                                shutdown remains owned by the watcher.
                                """,
                                severity: .critical
                            )
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

    /// Open only an existing store: checking for rows to purge must not create a database before capture consent.
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

    /// Persist before propagating: failed writes must never leave capture under consent absent from disk.
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

    /// Hold policy order through purge and physical WAL/VACUUM cleanup; logically hidden rows are not private deletion.
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
                await recordIssue(
                    "Excluded \(trimmed), but couldn't delete what was already recorded. " + errorCause(error, "delete excluded activity rows"),
                    severity: .critical
                )
            }
            return true
        }
        policyTask = task
        _ = await task.value
    }

    public func removeExclusion(bundleID: String) async {
        await apply { $0.excludedBundleIDs.remove(bundleID) }
    }

    /// Hide non-overridable exclusions so the UI cannot offer a control that silently does nothing.
    public var removableExclusions: [String] {
        policy.excludedBundleIDs
            .subtracting(ActivityPolicy.alwaysExcludedBundleIDs)
            .sorted()
    }

    // MARK: - Wipe / retention

    /// Wiping history preserves settings so forgetting observations cannot reset the user’s consent.
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
            NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
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
                    // A failed pass still owes work; retain its stamp and avoid spinning on an already-past due time.
                    delay = ActivityRetentionRunner.defaultInterval
                case .checked:
                    do { delay = try ActivityRetentionRunner(dataRoot: self.dataRoot).nextRunDelay() }
                    catch {
                        await self.recordIssue(
                            "Activity retention is paused until its saved cadence is repaired. " + self.errorCause(error, "read retention cadence"),
                            severity: .warning
                        )
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
            // Retention failure leaves older local history in place and must remain visible.
            await recordIssue(
                """
                Activity retention could not complete this pass; cleanup will retry in six hours. Repair its policy, cadence or store \
                if the problem persists.\u{20}
                """
                    + errorCause(error, "remove expired activity rows"),
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
        NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
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
