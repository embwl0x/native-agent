import Cognition
import NativeAgentCore
import StandingBots
import BackgroundWork
import BackgroundLoops
import TrustCenter
import ChatTurnRuntime
import ChatToolRuntime
import ProviderRouting
import ApprovalTransactions
import AppToolRuntime
import Desk
import WorkflowOrchestration
import Foundation
import OSLog
import Observation
import PersistenceCore
import Research
import TriggerScheduler
import SchedulerExecution
import WorkshopExecution
import ApprovalInbox
import NativeAgentShared
import NotificationInbox
import Experiences
// Blueprint: | `EngineDesk.swift` | DeskFacade retains one complete board/overview/page snapshot for Mac and DeviceSync, including prepared attention rows and deadlines; engine inbox/approvals/bots supply its lanes. LatestRead orders board, workflow, research and scheduler publication; committed research receipts use write, scheduler repairs fence older reads before checked feed readback. Job observation and refresh coalescing share the retained feed. DeskToolDispatchRouter retains checked routing and the local-click approval filer while dispatching through the canonical part door, including Make's Try again. |

/// Scheduler refreshes come from Desk invalidations, the mounted jobs watcher
/// and explicit Retry. Keep those refreshes single-flight,
/// while preserving one edge that arrives during the active read so a mutation
/// is not lost merely because the first snapshot was still being decoded.
private struct SchedulerJobsRefreshCoalescer: Equatable {
    private(set) var isRefreshing = false
    private(set) var trailingRefreshQueued = false

    mutating func requestRefresh() -> Bool {
        guard !isRefreshing else {
            trailingRefreshQueued = true
            return false
        }
        isRefreshing = true
        trailingRefreshQueued = false
        return true
    }

    mutating func completeRefresh() -> Bool {
        guard isRefreshing else { return false }
        if trailingRefreshQueued {
            trailingRefreshQueued = false
            return true
        }
        cancel()
        return false
    }

    mutating func cancel() {
        isRefreshing = false
        trailingRefreshQueued = false
    }
}

/// One root's retained Desk revision: board, overview and page lanes. Mac,
/// diagnostics, status publication and DeviceSync all render this owner.
@MainActor
@Observable
public final class DeskFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let inbox: InboxFacade
    private nonisolated let approvals: ApprovalsFacade
    private nonisolated let bots: BotRunnerScheduler

    public private(set) var workflows: [WorkflowRecord] = []
    public private(set) var workflowsReadError: String?

    /// Every scheduled job, as of the last read that returned rows.
    public private(set) var jobs: [ScheduledJob] = []
    public private(set) var jobsFeedState: SchedulerJobsFeedState?
    @ObservationIgnored private lazy var jobsRead = LatestRead()
    private var jobsRefresh = SchedulerJobsRefreshCoalescer()
    public var isRefreshingJobs: Bool { jobsRefresh.isRefreshing }

    public func watchJobs() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [jobsPath], debounceDelay: .milliseconds(100)) {
            _ = await self.refreshJobs()
        }
    }
    /// Research lab runs, newest first, as of the last read.
    public private(set) var researchRuns: [ResearchLabRun] = []
    @ObservationIgnored private lazy var researchRead = LatestRead()
    public private(set) var researchRunsLoaded = false
    public private(set) var researchRunsError: String?
    @ObservationIgnored private let workflowsRead = LatestRead()

    public func refreshWorkflows() async throws {
        let result: Result<[WorkflowRecord], Error> = await workflowsRead.read({
            do { return .success(try await SwiftNativeWorkflowOrchestrationClient(root: dataRoot).listWorkflowRecords()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let rows): workflows = rows; workflowsReadError = nil
            case .failure(let error): workflowsReadError = error.localizedDescription
            }
        })
        _ = try result.get()
    }

    public nonisolated init(dataRoot: URL, inbox: InboxFacade, approvals: ApprovalsFacade, bots: BotRunnerScheduler) {
        self.dataRoot = dataRoot
        self.inbox = inbox
        self.approvals = approvals
        self.bots = bots
    }

    /// The desk-item store for this root.
    public nonisolated var store: SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    // MARK: board

    public var board: DeskBoardRead { page.board ?? DeskBoardRead() }
    public private(set) var page = DeskPageSnapshot.empty
    public private(set) var readCount = 0
    public private(set) var liveUpdateError: String?
    @ObservationIgnored private lazy var boardRead = LatestRead()
    @ObservationIgnored private var refreshTask: Task<DeskPageSnapshot, Never>?
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var busTask: Task<Void, Never>?
    @ObservationIgnored private var experienceTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var watchedPaths: Set<URL> = []
    @ObservationIgnored private lazy var debouncer = StoreReloadDebouncer { [weak self] in
        _ = await self?.refresh()
    }

    /// Readers receive the retained revision. Explicit refresh and source edges
    /// replace it once for every surface, including pages that are offscreen.
    public func loadBoard() async -> DeskBoardRead {
        await loadPage().board!
    }

    public func loadPage() async -> DeskPageSnapshot {
        if page.loaded { return page }
        if let refreshTask { return await refreshTask.value }
        return await refreshPage()
    }

    private nonisolated func readBoard() async -> DeskBoardRead {
        var read = DeskBoardRead()
        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
        async let deskState = store.liveState()
        async let records = runner.listAll()
        do {
            read.deskState = try await deskState
            read.debugProjection = read.deskState.map { DeskProjection.render($0) } ?? ""
        } catch {
            read.deskError = Self.loadFailure(error)
        }
        // "Lenient" used to mean "silent": a corrupt store returned [] and the
        // surface said "Quiet right now". Each lane reports rows OR a reason.
        read.executions = DeskLaneState.classify(rows: await records, root: runner.executionRecordsRoot)
        let overview = await loadOverview(read)
        read.overview = overview.overview
        read.approvals = overview.approvals
        read.inbox = overview.inbox
        return read
    }

    /// The overview and its checked authority lanes share one read with phone snapshots.
    private nonisolated func loadOverview(_ board: DeskBoardRead) async -> (
        overview: WorkOverview,
        approvals: Result<[ApprovalRecord], Error>,
        inbox: Result<[NotificationInbox.InboxItemRecord], Error>
    ) {
        async let approvalsRead = self.approvals.list()
        async let inboxRead = self.inbox.list()
        var unavailable: [String] = []
        if let reason = board.deskError { unavailable.append("Desk: \(reason)") }
        if let reason = board.executions.unavailableReason { unavailable.append("Executions: \(reason)") }
        var approvalRows: [ApprovalRecord] = []
        var inboxRows: [NotificationInbox.InboxItemRecord] = []
        let approvals: Result<[ApprovalRecord], Error>
        let inbox: Result<[NotificationInbox.InboxItemRecord], Error>
        var experiences: [Experience] = []
        do { experiences = try await ExperienceStore.at(dataRoot).projection() }
        catch { unavailable.append("Experiences: \(Self.loadFailure(error))") }
        do {
            approvalRows = try await approvalsRead
            approvals = .success(approvalRows)
        } catch {
            approvals = .failure(error)
            unavailable.append("Approvals: \(Self.loadFailure(error))")
        }
        do {
            inboxRows = try await inboxRead
            inbox = .success(inboxRows)
        } catch {
            inbox = .failure(error)
            unavailable.append("Inbox: \(Self.loadFailure(error))")
        }
        return (WorkOverviewRead.project(board: board, approvals: approvalRows,
            inbox: inboxRows, experiences: experiences, unavailable: unavailable, now: Date()), approvals, inbox)
    }

    /// Every Desk execution, queue then legacy, as the phone's
    /// workshop_tasks.json and the graph's execution count read them. A row
    /// that is not an execution is skipped, but a feed where no row reads is
    /// corruption, never an empty bench, and throws.
    public nonisolated func taskRows() async throws -> [WorkshopTaskRow] {
        let rows = try await SwiftNativeWorkshopRunner(root: dataRoot).listWorkshopExecutions()
        let tasks = rows.compactMap(WorkshopTaskRow.init(row:))
        if tasks.count < rows.count {
            nativeLog("[DeskFacade] taskRows dropped \(rows.count - tasks.count) of \(rows.count) malformed execution row(s)")
        }
        if !rows.isEmpty && tasks.isEmpty {
            throw NSError(domain: "NativeAgent", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "getWorkshopExecutions(swift Workshop; surface=executions): all \(rows.count) element(s) failed to decode"
            ])
        }
        return tasks
    }

    deinit {
        watcher?.cancel()
        busTask?.cancel()
        experienceTask?.cancel()
        deadlineTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: schedule

    public nonisolated var jobsPath: URL {
        dataRoot
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    /// Read the canonical jobs feed without treating absent, damaged, or
    /// partially readable durable state as an empty schedule. The final row
    /// projection comes from `SchedulerJobWriter.listJobs()` so callers retain
    /// the same next-run decoration as the production list route.
    public func jobsFeed() async -> SchedulerJobsFeedState {
        await jobsRead.read({ await self.readJobsFeed() }) { feed in
            jobsFeedState = feed
            switch feed {
            case .current(let rows), .partial(let rows, _): jobs = rows
            case .sourceAbsent, .unavailable: break
            }
        }
    }

    private nonisolated func readJobsFeed() async -> SchedulerJobsFeedState {
        let path = jobsPath
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return .sourceAbsent
        }
        guard !isDirectory.boolValue else {
            return .unavailable("scheduler/jobs.json is a directory")
        }

        do {
            guard let rows = try await SwiftNativeTriggerScheduler(root: dataRoot).listJobsIfPresent() else {
                return .sourceAbsent
            }

            var jobs: [ScheduledJob] = []
            var rejectedRows = 0
            jobs.reserveCapacity(rows.count)
            for row in rows {
                do {
                    jobs.append(try ScheduledJob(row: row))
                } catch {
                    rejectedRows += 1
                }
            }
            return rejectedRows == 0 ? .current(jobs) : .partial(jobs, rejectedRows: rejectedRows)
        } catch TriggerSchedulerError.persistenceFailure(let detail) {
            switch detail {
            case "scheduler jobs file exceeds 4 MiB":
                return .unavailable("scheduler/jobs.json exceeds \(4 * 1_024 * 1_024) bytes")
            case "scheduler jobs file exceeds 1024 rows":
                return .unavailable("scheduler/jobs.json exceeds \(1_024) rows")
            case "scheduler jobs file must contain a JSON array":
                return .unavailable("scheduler/jobs.json must contain a JSON array")
            default:
                let prefix = "scheduler jobs file is unreadable or malformed: "
                return .unavailable(detail.hasPrefix(prefix) ? String(detail.dropFirst(prefix.count))
                    : TriggerSchedulerError.persistenceFailure(detail).localizedDescription)
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// The whole schedule, or why it cannot be shown whole.
    public func listJobs() async throws -> [ScheduledJob] {
        switch await jobsFeed() {
        case .current(let jobs):
            return jobs
        case .sourceAbsent:
            throw SchedulerJobsFeedError.sourceAbsent
        case .partial(_, let rejectedRows):
            throw SchedulerJobsFeedError.partial(rejectedRows: rejectedRows)
        case .unavailable(let detail):
            throw SchedulerJobsFeedError.unavailable(detail)
        }
    }

    @discardableResult
    public func refreshJobs() async -> SchedulerJobsFeedState? {
        if jobsRefresh.requestRefresh() {
            repeat {
                _ = await jobsFeed()
                if Task.isCancelled { jobsRefresh.cancel(); break }
            } while jobsRefresh.completeRefresh()
        }
        return jobsFeedState
    }

    public func setJobEnabled(id: String, enabled: Bool) async throws -> ScheduledJob {
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Set(connectorActionDescriptors().map(\.id)), dataRoot: dataRoot)
        let result = try await writer.setJobEnabled(jobId: id, enabled: enabled)
        // Readback follows the commit; pre-commit reads may no longer publish.
        jobsRead.write {}
        guard case .object(let object) = result, let row = object["job"] else {
            throw SchedulerJobsFeedError.unavailable("scheduler pause/resume returned no job")
        }
        let saved = try ScheduledJob(row: row)
        jobsRead.write {
            if let index = jobs.firstIndex(where: { $0.id == saved.id }) { jobs[index] = saved }
        }
        return saved
    }

    public func ensureNightlyReflection(scheduler: SchedulerDueJobRunner) async throws -> NightlyReflectionJobOutcome {
        let prior: [ScheduledJob]
        do {
            prior = try await listJobs()
        } catch SchedulerJobsFeedError.sourceAbsent {
            // Only explicit creation may repair an absent feed; damage stays unavailable.
            prior = []
        }
        // Explicit re-enable clears cancellation, unlike passive bootstrap.
        let resolved = try await scheduler.ensureDefaultCycleJobs(now: Date(), reactivateCancelled: true).nightlyDream
        // Keep the retained feed until readback, without admitting older reads.
        jobsRead.write {}
        let id = try ScheduledJob(row: resolved).id
        let refreshed = try await listJobs()
        guard let after = refreshed.first(where: { $0.id == id }) else {
            return .failed("the canonical scheduler job was not persisted")
        }
        if let before = prior.first(where: { $0.id == id }) { return before == after ? .alreadyPresent : .repaired }
        return .added
    }

    // MARK: research

    /// Publish one receipt history and read outcome for every research surface.
    public func refreshResearchRuns() async {
        let _: Result<[ResearchLabRun], Error> = await researchRead.read({
            do { return .success(try await self.listResearchRuns()) }
            catch { return .failure(error) }
        }, publish: { result in
            researchRunsLoaded = true
            switch result {
            case .success(let rows): researchRuns = rows; researchRunsError = nil
            case .failure(let error):
                let detail = UserFacingError.cause(error, action: "list research runs")
                researchRunsError = detail.count > 240 ? String(detail.prefix(240)) + "…" : detail
            }
        })
    }

    public func recordResearchRun(_ run: ResearchLabRun) {
        researchRead.write {
            researchRuns.removeAll { $0.id == run.id }
            researchRuns.insert(run, at: 0)
        }
    }

    /// Research lab runs from `research/lab/runs.json`, newest first. A run
    /// that does not read is skipped.
    public nonisolated func listResearchRuns() async throws -> [ResearchLabRun] {
        try await SwiftNativeResearchClient(dataRoot: dataRoot).researchLabRuns()
            .compactMap(ResearchLabRun.init(row:))
    }
}

public enum NightlyReflectionJobOutcome: Equatable, Sendable {
    case added
    case alreadyPresent
    case repaired
    case failed(String)
}


extension DeskFacade {
    /// Exact sources formerly covered by the page's poll. Watching the record
    /// names in every existing directory also catches a first write after a
    /// reservation, and repairs to a record that could not yet be decoded.
    public nonisolated func liveUpdatePaths() async throws -> [URL] {
        let executions = dataRoot.appendingPathComponent("workshop/executions", isDirectory: true)
        var paths = [
            SwiftNativeDeskStore(dataRoot: dataRoot).opsPath,
            SwiftNativeDeskStore(dataRoot: dataRoot).basePath,
            await approvals.requestsPath(),
            LiveNotificationInbox.livePath(dataRoot: dataRoot),
            executions,
            jobsPath,
            dataRoot.appendingPathComponent("bots/definitions", isDirectory: true),
            dataRoot.appendingPathComponent("bots/runner-jobs.json"),
            DeskNagConfigStore(dataRoot: dataRoot).configPath,
            StudioWanderLane.statePath(dataRoot: dataRoot),
            dataRoot.appendingPathComponent("trust/policy.json"),
        ]
        for parent in Set(paths.map { $0.deletingLastPathComponent() }) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let directories: [URL]
        do {
            directories = try FileManager.default.contentsOfDirectory(
                at: executions, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return paths
        }
        for directory in directories where try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            paths.append(ExecutionRecordFile.canonicalPath(in: directory))
        }
        return paths
    }

    @discardableResult
    public func refresh() async -> Bool {
        let read = await refreshPage()
        return !Task.isCancelled && page.id == read.id
    }

    public func refreshPage() async -> DeskPageSnapshot {
        readCount += 1
        defer { readCount -= 1 }
        let preceding = refreshTask
        // A source edge arriving during a read must run after that read. Joining
        // it would consume the edge against bytes captured before the change.
        let task = Task {
            _ = await preceding?.value
            return await readRevision()
        }
        refreshTask = task
        let read = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if readCount == 1 { refreshTask = nil }
        return read
    }

    /// The complete bundle returns to its reader and publishes once for every
    /// mount. No presentation field is stored beside this retained revision.
    private func readRevision() async -> DeskPageSnapshot {
        await boardRead.read {
            await bindLiveUpdates()
            var snapshot = await Task.detached(priority: .userInitiated) {
                DeskPageSnapshot(read: await self.readBoard())
            }.value
            // The armed parent catches later membership changes; rescan for any
            // execution directory created between the first enumeration and arm.
            await bindLiveUpdates()
            _ = await refreshJobs()
            let dataRoot = self.dataRoot
            let timing = try? await bots.effectiveSchedule()
            snapshot.missedBots = await Task.detached(priority: .userInitiated) {
                timing.map { DeskMissedBot.load(root: dataRoot, timing: $0) } ?? []
            }.value
            if let timing, timing.unattended {
                snapshot.timedBots = await Task.detached(priority: .userInitiated) {
                    DeskTimedBot.load(root: dataRoot, timing: timing)
                }.value
            }
            snapshot.now = Date()
            snapshot.nagConfig = await DeskNagConfigStore(dataRoot: dataRoot).load()
            let hour: StudioWanderLane.TraceEntry?
            do {
                hour = try await Self.residentHour(dataRoot: dataRoot)
                snapshot.herHour = DeskHerHourPresentation.state(installed: true, entry: hour, now: snapshot.now)
            } catch {
                hour = nil
                snapshot.herHour = .line(text: "Her hour’s saved state is unavailable.", symbol: "exclamationmark.triangle")
            }
            let hourExpiry = hour.flatMap { UserDisplayFormatters.parseISOTimestamp($0.at) }
                .map { DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: snapshot.now) }
            snapshot.jobs = jobs
            snapshot.rows = await Task.detached(priority: .userInitiated) { [snapshot] in
                DeskPageContent.project(snapshot: snapshot, now: snapshot.now, nags: snapshot.nagConfig,
                    timedBots: snapshot.timedBots, jobStamps: snapshot.jobs.compactMap(\.nextRunAt), hourExpiry: hourExpiry)
            }.value
            return snapshot
        } publish: { snapshot in
            page = snapshot
            deadlineTask?.cancel()
            deadlineTask = snapshot.rows.deadline.map { deadline in
                Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                    catch { return }
                    await self?.signalRefresh()
                }
            }
        }
    }

    public func signalRefresh() async { await debouncer.signal() }

    private func bindLiveUpdates() async {
        if experienceTask == nil {
            let changes = await ExperienceStore.at(dataRoot).changes()
            experienceTask = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.signalRefresh()
                }
            }
        }
        do {
            let paths = try await liveUpdatePaths()
            let normalized = Set(paths.map(\.standardizedFileURL))
            liveUpdateError = nil
            guard normalized != watchedPaths else { return }
            watcher?.cancel()
            busTask?.cancel()
            watchedPaths = normalized
            let changes = StoreChangeBus.shared.changes()
            busTask = Task { [weak self] in
                for await change in changes where normalized.contains(change.path.standardizedFileURL) {
                    guard !Task.isCancelled else { return }
                    await self?.signalRefresh()
                }
            }
            watcher = await FileChangeWatcher.armed(paths: paths) { [weak self] _ in
                Task { await self?.signalRefresh() }
            }
            await debouncer.setVisible(true)
        } catch {
            liveUpdateError = UserFacingError.message(error, action: "turn on Desk live updates")
        }
    }

}
// MARK: - The schedule feed

public enum SchedulerJobsFeedState: Equatable, Sendable {
    case current([ScheduledJob])
    case partial([ScheduledJob], rejectedRows: Int)
    case sourceAbsent
    case unavailable(String)

    public var failureDetail: String? {
        switch self {
        case .current:
            nil
        case .partial(let rows, let rejectedRows):
            "Schedule is partially unavailable: \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows") were withheld; \(rows.count) valid \(rows.count == 1 ? "row remains" : "rows remain")."
        case .sourceAbsent:
            "Schedule source is absent. No job count is available until scheduler/jobs.json is created."
        case .unavailable(let detail):
            "Schedule source is unavailable: \(detail)"
        }
    }
}
public enum SchedulerJobsFeedError: LocalizedError, Sendable {
    case sourceAbsent
    case partial(rejectedRows: Int)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .sourceAbsent:
            "Schedule source is absent. No job count is available."
        case .partial(let rejectedRows):
            "Schedule has \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows")."
        case .unavailable(let detail):
            "Schedule source is unavailable: \(detail)"
        }
    }
}

// MARK: - The phone's execution row

/// One Desk execution as workshop_tasks.json has always carried it, read from
/// Core's merged wire row. The queue writes snake_case and the legacy store
/// camelCase, so both spellings read; a queue row with no phase repeats its
/// status. A present field of the wrong type makes the row unreadable.
public struct WorkshopTaskRow: Encodable, Hashable, Sendable {
    public var id: String
    public var deskHandle: String?
    public var projectSpaceId: String?
    public var title: String
    public var objective: String
    public var status: String
    public var phase: String
    public var priority: String?
    public var autonomyLevel: String?
    public var permissionProfile: String?
    public var summary: String?
    public var createdAt: String
    public var updatedAt: String?
    public var lastMovementAt: String?
    public var completedAt: String?
    public var receiptCount: Int?
    public var currentStepId: String?
    public var requiresApproval: Bool { WorkOverviewRead.requiresApproval(status: status) }

    public init?(row: JSONValue) {
        guard case .object(let obj) = row else { return nil }
        var malformed = false
        func text(_ keys: String...) -> String? {
            for key in keys {
                switch obj[key] {
                case nil, .null?: continue
                case .string(let value)?: return value
                default: malformed = true; return nil
                }
            }
            return nil
        }
        func count(_ keys: String...) -> Int? {
            for key in keys {
                switch obj[key] {
                case nil, .null?: continue
                case .int(let value)?:
                    if let value = Int(exactly: value) { return value }
                    malformed = true; return nil
                case .double(let value)?:
                    if let value = Int(exactly: value) { return value }
                    malformed = true; return nil
                default: malformed = true; return nil
                }
            }
            return nil
        }
        guard case .string(let id)? = obj["id"] else { return nil }
        self.id = id
        deskHandle = text("deskHandle", "desk_handle")
        projectSpaceId = text("projectSpaceId", "project_space_id")
        title = text("title") ?? ""
        objective = text("objective") ?? ""
        status = text("status") ?? "queued"
        phase = text("phase") ?? status
        priority = text("priority")
        autonomyLevel = text("autonomyLevel", "autonomy_level")
        permissionProfile = text("permissionProfile", "permission_profile")
        summary = text("summary")
        createdAt = text("createdAt", "created_at") ?? ""
        updatedAt = text("updatedAt", "updated_at")
        lastMovementAt = text("lastMovementAt", "last_movement_at")
        completedAt = text("completedAt", "completed_at")
        receiptCount = count("receiptCount", "receipt_count")
        currentStepId = text("currentStepId", "current_step_id")
        guard !malformed else { return nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id, deskHandle, projectSpaceId, title, objective, status, phase, priority
        case autonomyLevel, permissionProfile, summary
        case createdAt, updatedAt, lastMovementAt, completedAt, receiptCount, currentStepId, requiresApproval
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(deskHandle, forKey: .deskHandle)
        try c.encodeIfPresent(projectSpaceId, forKey: .projectSpaceId)
        try c.encode(title, forKey: .title)
        try c.encode(objective, forKey: .objective)
        try c.encode(status, forKey: .status)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(autonomyLevel, forKey: .autonomyLevel)
        try c.encodeIfPresent(permissionProfile, forKey: .permissionProfile)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastMovementAt, forKey: .lastMovementAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(receiptCount, forKey: .receiptCount)
        try c.encodeIfPresent(currentStepId, forKey: .currentStepId)
        try c.encode(requiresApproval, forKey: .requiresApproval)
    }
}

public struct DeskToolDispatchRouter: Sendable {
    /// Surface tag carried into the dispatch. Distinct from "chat" so a receipt
    /// reader can tell User's click from Agent's tool call.
    public static let surface = "desk"

    public let dataRoot: URL
    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        let surface = canonicalRoutingSurface(Self.surface)
        guard MODEL_SURFACES.contains(surface) else { throw ProviderRoutingError.invalidRequest }
        // A Desk click does not make an LLM call, but it is still a product
        // surface with independently persisted provider/policy selection. Read
        // the same checked snapshot before the autonomy gate so corrupt or
        // incomplete routing cannot turn the click into a hidden chat-default
        // bypass, and so its provider selection is observed at the canonical
        // boundary rather than merely listed in a catalog.
        let routingSnapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot)
            .checkedRoutingSnapshot()
        guard routingSnapshot.preferences[surface] != nil else {
            throw ProviderRoutingError.unavailable
        }
        // Same impl AND same gate: chat-lane desk_* calls pass through the
        // FileAccessGated + AutonomyGated membrane, and a bare dispatcher here
        // let a desk click write where the same mutation from chat would have
        // required approval (gpt-5.5 review 2026-08-06, blocking #1). The
        // gated chain resolves Trust Center policy identically. Only this local
        // action boundary supplies the click approval filer.
        return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(
            envelope: .native("mac_ui:desk:" + tool, surface: surface),
            approvalFiler: DeskClickApprovalFiler(dataRoot: dataRoot)) {
            guard let dispatch = AppDoorReentry.perform else {
                throw PartCallError(code: "door_unavailable", message: "The local Desk click has no originating app door.")
            }
            return try await dispatch(tool, input)
        }
    }
}

public struct DeskActionOutcome: Equatable, Sendable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
}

public enum DeskActionResultReader {
    /// The desk tools answer in three shapes and ALL THREE must be surfaced:
    ///   status "ok"      → `confirmation`
    ///   status "refused" → `reason`, ok == false (the store's honest refusal:
    ///                      a cycle, a bad date, a cap — these are results, not
    ///                      exceptions, and rendering one as success is a lie)
    ///   status "failed"  → `reason`/`detail`, ok == false
    /// Anything else is reported as unknown rather than assumed fine.
    public static func read(_ value: JSONValue, fallback: String) -> DeskActionOutcome {
        guard case .object(let obj) = value else {
            return DeskActionOutcome(ok: false, message: "\(fallback): unreadable tool result")
        }
        let status: String
        if case .string(let s)? = obj["status"] { status = s } else { status = "" }
        func text(_ keys: [String]) -> String? {
            for key in keys {
                if case .string(let s)? = obj[key], !s.isEmpty { return s }
            }
            return nil
        }
        switch status {
        case "ok":
            return DeskActionOutcome(ok: true, message: text(["confirmation", "summary"]) ?? fallback)
        case "refused":
            return DeskActionOutcome(ok: false, message: text(["reason"]) ?? "\(fallback) refused")
        case "failed":
            return DeskActionOutcome(
                ok: false,
                message: text(["reason", "detail", "fix"]) ?? "\(fallback) failed")
        default:
            return DeskActionOutcome(
                ok: false,
                message: "\(fallback): unexpected tool status '\(status)'")
        }
    }
}

extension DeskFacade {
    public nonisolated static func residentHour(dataRoot: URL) async throws -> StudioWanderLane.TraceEntry? {
        guard await NativeCognitionRuntime.studioWanderIsInstalled(dataRoot: dataRoot) else { return nil }
        return try await StudioWanderLane.loadState(dataRoot: dataRoot).trace.last
    }
}

extension DeskToolDispatchRouter {
    /// Fire one action and read its answer. Never throws: a transport failure
    /// is an outcome with `ok == false`, because the caller has to render
    /// something either way.
    public func perform(_ action: DeskQuickAction) async -> DeskActionOutcome {
        do {
            let value = try await run(tool: action.tool, input: action.input)
            return DeskActionResultReader.read(value, fallback: action.pendingLabel)
        } catch {
            return DeskActionOutcome(
                ok: false,
                message: "\(action.pendingLabel) failed: " + UserFacingError.cause(error, action: "run a Desk action"))
        }
    }
}

public extension DeskQuickAction {
    var pendingLabel: String {
        switch self {
        case .close, .closeIfCurrent: return "Closing"
        case .setStatus: return "Updating status"
        case let .defer_(_, until): return until == nil ? "Clearing the park" : "Deferring"
        case .note: return "Adding note"
        case let .nagGlobal(on): return on ? "Turning nagging on" : "Turning nagging off"
        case .nagProject, .nagItem: return "Updating nag scope"
        case .nagMute: return "Muting nags"
        case .nagUnmute: return "Turning nagging back on"
        }
    }
}

/// The owner-facing mutation behind the Observatory's Veto button. A repeated
/// button event is held while the first durable operation is in flight; once
/// settled, the store's idempotent veto makes retries safe across relaunches.
public actor WorkshopObservatoryVetoHandler {
    public enum Outcome: Equatable, Sendable {
        case completed
        case alreadyVetoed
        case inFlight
        case failed(String)

        public var shouldRefresh: Bool {
            switch self {
            case .completed, .alreadyVetoed: return true
            case .inFlight, .failed: return false
            }
        }
    }

    public static let rationale = "Vetoed by the user from the Desk observatory."
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "workshop-veto")

    private let store: SwiftNativeDeskStore
    private var inFlightHandles: Set<String> = []

    public init(dataRoot: URL) {
        self.store = SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    public init(store: SwiftNativeDeskStore) {
        self.store = store
    }

    public func veto(_ handle: String) async -> Outcome {
        guard inFlightHandles.insert(handle).inserted else { return .inFlight }
        defer { inFlightHandles.remove(handle) }
        do {
            return try await store.vetoPursuit(handle, note: Self.rationale) == nil
                ? .alreadyVetoed
                : .completed
        } catch {
            Self.logger.error("Veto failed: \(String(describing: error), privacy: .public)")
            switch error {
            case DeskError.unknownHandle:
                return .failed("This item could not be found on the Desk.")
            case DeskError.notAPursuit:
                return .failed("This item is not a pursuit.")
            case DeskError.vetoRefusedTerminal:
                return .failed("This pursuit is already closed.")
            case DeskError.terminalStatusRefusedNonTerminalChild:
                return .failed("This pursuit has unfinished child items. Close them before vetoing it.")
            case DeskError.pursuitFieldMissing:
                return .failed("The veto reason is missing.")
            case DeskError.compactionBaseCorrupt, DeskError.compactionBaseUnreadable:
                return .failed("Saved Desk data could not be read. The pursuit was not changed.")
            default:
                return .failed("The veto could not be saved. Try again.")
            }
        }
    }
}


extension NativeAgentEngine {
    public static func submitDeskTask(
        title: String, objective: String, projectSpaceId: String? = nil
    ) async throws -> WorkshopDirectedTaskResult {
        try await WorkshopDirectedTaskSubmitter(
            dataRoot: PersistenceCore.defaultDataRoot(),
            runner: makeWorkshopExecutionRunner()
        ).submit(spec: WorkshopExecutionSpec(
            title: title, objective: objective, triggerSource: "manual",
            trustRequired: "none", projectSpaceId: projectSpaceId))
    }
}
