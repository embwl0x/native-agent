import Cognition
import NativeAgentCore
import StandingBots
import BackgroundWork
import BackgroundLoops
import TrustCenter
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatToolParsing
import ApprovalTransactions
import AppToolRuntime
import AgentConversations
import Desk
import Foundation
import OSLog
import Observation
import PersistenceCore
import Research
import TriggerScheduler
import SchedulerExecution
import ApprovalInbox
import NativeAgentShared
import NotificationInbox
import Experiences
// Blueprint: | `EngineDesk.swift` | One retained board revision, ForPerson inbox changes, checked reads and gated local mutations |

/// All surfaces share one retained Desk revision per root.
@MainActor
@Observable
public final class DeskFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let vetoHandler: PursuitVeto
    private nonisolated let inbox: InboxFacade
    private nonisolated let approvals: ApprovalsFacade
    private nonisolated let bots: BotRunnerScheduler

    public private(set) var workflows: [WorkflowRecord] = []
    public private(set) var workflowsReadError: String?
    public private(set) var hasLoadedWorkflows = false
    @ObservationIgnored var capabilitiesDidChange: (@MainActor @Sendable () async -> Void)?

    public private(set) var jobs: [ScheduledJob] = []
    public private(set) var jobsFeedState: SchedulerJobsFeedState?
    @ObservationIgnored private lazy var jobsRead = LatestRead()
    private var jobsRefresh = LivingStatusRefreshCoalescer()
    @ObservationIgnored private var jobsRefreshTask: Task<SchedulerJobsFeedState, Never>?
    public var isRefreshingJobs: Bool { jobsRefresh.isRefreshing }

    public func watchJobs() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [jobsPath], debounceDelay: .milliseconds(100)) {
            _ = await self.refreshJobs()
        }
    }
    public private(set) var researchRuns: [ResearchLabRun] = []
    @ObservationIgnored private lazy var researchRead = LatestRead()
    public private(set) var researchRunsLoaded = false
    public private(set) var researchRunsError: String?
    @ObservationIgnored private let workflowsRead = LatestRead()

    public func refreshWorkflows() async throws {
        let result: Result<[WorkflowRecord], Error> = await workflowsRead.read({
            do { return .success(try await SavedWorkflows(root: dataRoot).listWorkflowRecords()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let rows): workflows = rows; workflowsReadError = nil; hasLoadedWorkflows = true
            case .failure(let error): workflowsReadError = error.localizedDescription
            }
        })
        await capabilitiesDidChange?()
        _ = try result.get()
    }

    public nonisolated init(dataRoot: URL, inbox: InboxFacade, approvals: ApprovalsFacade, bots: BotRunnerScheduler) {
        self.dataRoot = dataRoot
        self.vetoHandler = PursuitVeto(dataRoot: dataRoot)
        self.inbox = inbox
        self.approvals = approvals
        self.bots = bots
    }

    public nonisolated var store: SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    // MARK: board

    public var board: DeskBoardRead { page.board ?? DeskBoardRead() }
    public private(set) var page = DeskPageSnapshot.empty
    /// Navigation holds only an identity; the face resolves its details from the retained board.
    public var faceItem: String? {
        didSet { if faceItem != oldValue { faceDidChange?() } }
    }
    @ObservationIgnored var faceDidChange: (@MainActor () -> Void)?
    @ObservationIgnored var faceActionInFlight = false
    @ObservationIgnored public var faceRequest: (@MainActor (DeskFaceRequest) throws -> String)?
    private var availableOverview: WorkOverview? {
        guard let overview = page.overview, overview.unavailable.isEmpty else { return nil }
        return overview
    }
    /// Needs you remains unavailable if any overview source cannot be read.
    public var ownerWaitingCount: Int? { availableOverview?.needsYouCount }
    public var ownerWaitingKinds: [WorkOverviewReference.Kind: Int]? { availableOverview?.needsYouCounts }
    public private(set) var readCount = 0
    public private(set) var liveUpdateError: String?
    @ObservationIgnored private lazy var boardRead = LatestRead()
    @ObservationIgnored private var refreshTask: Task<DeskPageSnapshot, Never>?
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var busTask: Task<Void, Never>?
    @ObservationIgnored private var experienceTask: Task<Void, Never>?
    @ObservationIgnored private var inboxTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var watchedPaths: Set<URL> = []
    @ObservationIgnored private lazy var debouncer = StoreReloadDebouncer { [weak self] in
        _ = await self?.refresh()
    }

    /// Source changes replace one retained revision for every surface, including offscreen pages.
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
        read.revision = SwiftNativeDeskStore.currentRevision
        async let deskState = store.liveState()
        do {
            read.deskState = try await deskState
            read.debugProjection = read.deskState.map { DeskPage.render($0) } ?? ""
        } catch {
            read.deskError = Self.loadFailure(error)
        }
        do { read.agentJobs = .rows(try AgentJobStore(dataRoot: dataRoot).jobs()) }
        catch { read.agentJobs = .failed(error) }
        let overview = await loadOverview(read)
        read.overview = overview.overview
        read.approvals = overview.approvals
        read.inbox = overview.inbox
        return read
    }

    /// Share the checked overview read with phone snapshots.
    private nonisolated func loadOverview(_ board: DeskBoardRead) async -> (
        overview: WorkOverview,
        approvals: Result<[ApprovalRecord], Error>,
        inbox: Result<[NativeAgentShared.InboxItemRecord], Error>
    ) {
        async let approvalsRead = self.approvals.list()
        async let inboxRead = self.inbox.list()
        var unavailable: [String] = []
        if let reason = board.deskError { unavailable.append("Desk: \(reason)") }
        if let reason = board.agentJobs.unavailableReason { unavailable.append("Jobs: \(reason)") }
        var approvalRows: [ApprovalRecord] = []
        var inboxRows: [NativeAgentShared.InboxItemRecord] = []
        let approvals: Result<[ApprovalRecord], Error>
        let inbox: Result<[NativeAgentShared.InboxItemRecord], Error>
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

    deinit {
        watcher?.cancel()
        busTask?.cancel()
        experienceTask?.cancel()
        inboxTask?.cancel()
        clockTask?.cancel()
        deadlineTask?.cancel()
        refreshTask?.cancel()
        jobsRefreshTask?.cancel()
    }

    // MARK: schedule

    public nonisolated var jobsPath: URL {
        dataRoot
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    /// Missing or damaged state cannot claim an empty schedule; use the canonical scheduler’s next-run decoration.
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
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

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
            jobsRefreshTask = Task {
                var feed = await jobsFeed()
                while !Task.isCancelled, jobsRefresh.completePass() {
                    feed = await jobsFeed()
                }
                jobsRefresh.cancel()
                jobsRefreshTask = nil
                return feed
            }
        }
        // Joining requests wait for their trailing read, never the previously retained feed.
        return await jobsRefreshTask?.value
    }

    public func setJobEnabled(id: String, enabled: Bool) async throws -> ScheduledJob {
        let writer = makeSchedulerJobWriter(dataRoot: dataRoot)
        let result = try await writer.setJobEnabled(jobId: id, enabled: enabled)
        // Commit before readback; pre-commit reads must not publish afterward.
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
            // Only explicit creation may repair absence; damage remains unavailable.
            prior = []
        }
        // Explicit re-enable clears cancellation, unlike passive bootstrap.
        let resolved = try await scheduler.ensureDefaultCycleJobs(now: Date(), reactivateCancelled: true).nightlyDream
        // Retain the feed until readback without admitting pre-commit reads.
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

    /// Share receipt history and read outcome across research surfaces.
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

    /// Damaged research history fails its read without replacing retained rows or original bytes.
    public nonisolated func listResearchRuns() async throws -> [ResearchLabRun] {
        try await SwiftNativeResearchClient(dataRoot: dataRoot).researchLabRuns()
    }
}

public enum NightlyReflectionJobOutcome: Equatable, Sendable {
    case added
    case alreadyPresent
    case repaired
    case failed(String)
}


extension DeskFacade {
    /// The stores whose writes refresh the Desk page.
    nonisolated var pageUpdatePaths: [URL] {
        [
            SwiftNativeDeskStore(dataRoot: dataRoot).opsPath,
            SwiftNativeDeskStore(dataRoot: dataRoot).basePath,
            SwiftNativeApprovalInbox(root: dataRoot).approvalsPath,
            jobsPath,
            AgentJobStore(dataRoot: dataRoot).fileURL,
            dataRoot.appendingPathComponent("bots/definitions", isDirectory: true),
            dataRoot.appendingPathComponent("bots/runner-jobs.json"),
            DeskNagConfigStore(dataRoot: dataRoot).configPath,
            StudioWanderLane.statePath(dataRoot: dataRoot),
            dataRoot.appendingPathComponent("trust/policy.json"),
        ]
    }

    public nonisolated func liveUpdatePaths() async throws -> [URL] {
        let paths = pageUpdatePaths
        for parent in Set(paths.map { $0.deletingLastPathComponent() }) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
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
        // Read source changes after the current read; joining it would consume an edge against older captured bytes.
        let task = Task {
            _ = await preceding?.value
            return await readRevision()
        }
        refreshTask = task
        let read = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if readCount == 1 { refreshTask = nil }
        return read
    }

    /// Publish one complete retained revision; never store a parallel presentation snapshot.
    private func readRevision() async -> DeskPageSnapshot {
        await boardRead.read {
            await bindLiveUpdates()
            var snapshot = await Task.detached(priority: .userInitiated) {
                DeskPageSnapshot(read: await self.readBoard())
            }.value
            // Rescan after arming the parent to cover directories created during watch setup.
            await bindLiveUpdates()
            _ = await refreshJobs()
            let dataRoot = self.dataRoot
            do {
                let timing = try await bots.effectiveSchedule()
                snapshot.missedBots = try await Task.detached(priority: .userInitiated) {
                    try DeskMissedBot.load(root: dataRoot, timing: timing)
                }.value
                if timing.unattended {
                    snapshot.timedBots = try await Task.detached(priority: .userInitiated) {
                        try DeskTimedBot.load(root: dataRoot, timing: timing)
                    }.value
                }
            } catch {
                snapshot
                    .botScheduleError = "Helper schedules could not be read: \(error.localizedDescription). Repair the saved helper definitions and schedules."
            }
            snapshot.now = Date()
            do { snapshot.nagConfig = try await DeskNagConfigStore(dataRoot: dataRoot).loadChecked() }
            catch { snapshot
                .nagConfigError = "Reminder settings are unavailable: \(error.localizedDescription). Repair the saved reminder settings before changing them." }
            let hour: StudioWanderLane.TraceEntry?
            do {
                hour = try await Self.residentHour(dataRoot: dataRoot)
                snapshot.wanderHour = DeskWanderHourPresentation.state(installed: true, entry: hour, now: snapshot.now)
            } catch {
                hour = nil
                snapshot.wanderHour = .line(text: "The wander hour’s saved state is unavailable.", symbol: "exclamationmark.triangle")
            }
            let hourExpiry = hour.flatMap { UserDisplayFormatters.parseISOTimestamp($0.at) }
                .map { DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: snapshot.now) }
            snapshot.jobs = jobs
            snapshot = await Task.detached(priority: .userInitiated) { [snapshot] in
                var snapshot = snapshot
                snapshot.plan = DeskSequencing.compute(DeskState(items: snapshot.boardItems, generatedTs: ""), now: snapshot.now)
                snapshot.rows = DeskPageContent.project(snapshot: snapshot, now: snapshot.now, nags: snapshot.nagConfig,
                    timedBots: snapshot.timedBots, jobStamps: snapshot.jobs.compactMap(\.nextRunAt), hourExpiry: hourExpiry)
                return snapshot
            }.value
            return snapshot
        } publish: { snapshot in
            page = snapshot
            faceDidChange?()
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
        if inboxTask == nil {
            let changes = await ForPerson.at(dataRoot).changes()
            inboxTask = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.signalRefresh()
                }
            }
        }
        if clockTask == nil {
            let changes = EventDeadlinePhysiology.storeAndFileEvents(paths: [], notifications: [
                .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
            ])
            clockTask = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.signalRefresh()
                }
            }
        }
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
            """
                Schedule is partially unavailable: \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows") were withheld; \(rows.count) valid \
                \(rows.count == 1 ? "row remains" : "rows remain").
                """
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

public struct DeskToolDispatchRouter: Sendable {
    /// Use a distinct dispatch surface so receipts distinguish the user’s click from the agent’s tool call.
    public static let surface = "desk"

    public let dataRoot: URL
    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        // Desk clicks share chat’s Trust gates; only this boundary supplies their approval filer.
        return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(
            envelope: .personOnMac("mac_ui:desk:" + tool, surface: Self.surface),
            approvalFiler: DeskClickApprovalFiler(dataRoot: dataRoot)) { door in
            try await door.perform(tool, input)
        }
    }
}

public struct DeskActionOutcome: Equatable, Sendable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
}

public enum DeskActionResultReader {
    /// Derive success from shared receipt evidence before choosing Desk wording.
    public static func read(_ value: JSONValue, fallback: String) -> DeskActionOutcome {
        let reply = ToolResult(value)
        guard case .object(let obj) = reply.payload else {
            return DeskActionOutcome(ok: false, message: "\(fallback): unreadable tool result")
        }
        func text(_ keys: [String]) -> String? {
            for key in keys {
                if case .string(let s)? = obj[key], !s.isEmpty { return s }
            }
            return nil
        }
        let result = reply.outcome
        switch result {
        case .succeeded:
            return DeskActionOutcome(ok: true, message: text(["confirmation", "summary"]) ?? fallback)
        case .refused:
            return DeskActionOutcome(ok: false, message: text(["reason"]) ?? "\(fallback) refused")
        case .failed, .cancelled, .timeout:
            return DeskActionOutcome(
                ok: false,
                message: text(["reason", "detail", "fix"]) ?? "\(fallback) \(result.receipt.label.lowercased())")
        case .unknown:
            return DeskActionOutcome(
                ok: false,
                message: "\(fallback): result unconfirmed")
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
    /// Return transport failures as `ok == false` outcomes so callers always have something to render.
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

/// Hold repeated Veto events during the durable operation; the store’s idempotence covers retries after relaunch.
public actor PursuitVeto {
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

    public static let rationale = "Vetoed by the person on the Desk."
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "pursuit-veto")

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


/// A Desk task the person starts: the item, and the agent's line that carries it.
public struct DeskTaskStart: Sendable {
    public let deskItem: DeskItem
    public let job: String
}

extension NativeAgentEngine {
    /// A Desk task starts a line of the agent's carrying that item; its ending wakes the agent's own work conversation, where the agent settles the item.
    public static func submitDeskTask(title: String, objective: String, project: String = "Tasks") async throws -> DeskTaskStart {
        let root = PersistenceCore.defaultDataRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .project, project: project, title: String(title.prefix(160)),
            summary: String(objective.prefix(600)))
        let receipt = await AgentJobs.commission(["agent": .string(AgentJob.own), "brief": .string(objective), "desk": .string(item.handle)],
            session: nil, surface: "desk", ceiling: .denied(reason: "a Desk task starts a line of the agent's own, never another agent"),
            limits: (peers: [], elevated: [], fileAccess: nil), dataRoot: root, register: AppToolExecutor.jobRegistrar(dataRoot: root))
        guard receipt.objectValue?["status"] == .string("accepted"), let job = receipt.objectValue?["job"]?.stringValue else {
            let why = receipt.objectValue?["detail"]?.stringValue ?? "its line did not start"
            throw ToolFailureError("Desk item \(item.alias) was kept, but no line took it: \(why)", effects: .occurred,
                owner: "Desk item \(item.handle)", recovery: .reconcile)
        }
        return DeskTaskStart(deskItem: item, job: job)
    }
}
