import Cognition
import StandingBots
import BackgroundWork
import BackgroundLoops
import TrustCenter
import ChatOrchestration
import ProviderRouting
import ApprovalTransactions
import AppToolRuntime
import Desk
import GitHubConnector
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

/// `NativeAgentEngine.desk` (S10): the Desk for one data root, in core types —
/// the board (desk items, executions, GitHub), the schedule, and research lab
/// runs. The Desk pages, the Schedule and Capabilities render `jobs` and
/// `researchRuns`; the reads are nonisolated so the phone snapshot and the
/// phone's desk actions use the same owner. Writes (new tasks, job pause and
/// cancel, research runs) run through the Workshop submitter, the scheduler
/// job writer and the research client.
@MainActor
@Observable
public final class DeskFacade {
    public nonisolated let dataRoot: URL

    /// Every scheduled job, as of the last read that returned rows.
    public var jobs: [ScheduledJob] = []
    /// Research lab runs, newest first, as of the last read.
    public var researchRuns: [ResearchLabRun] = []

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// The desk-item store for this root.
    public nonisolated var store: SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    // MARK: board

    /// One read of every Desk store (see `DeskBoardRead`), taken off the main
    /// actor by the caller.
    ///
    /// - Parameter includeSequencing: build the classic page's sequencing plan
    ///   and alias map as well. Off by default: a page that does not render
    ///   them should not pay for them.
    public nonisolated func loadBoard(includeSequencing: Bool = false, includeOverview: Bool = false) async -> DeskBoardRead {
        var read = DeskBoardRead()
        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
        async let deskState = store.liveState()
        async let records = runner.listAll()
        async let githubState = GitHubCommandStore(dataRoot: dataRoot).liveState()
        do {
            read.deskState = try await deskState
        } catch {
            read.deskError = Self.loadFailure(error)
        }
        // Execution and GitHub reads stay independent: one broken lane never
        // blanks the other live Workshop projections. But "lenient" used to
        // mean "silent" — a corrupt store returned [] and the surface said
        // "Quiet right now". Each lane now reports rows OR a reason.
        read.executions = DeskLaneState.classify(rows: await records, root: runner.executionRecordsRoot)
        do {
            read.github = .rows(try await githubState.items)
        } catch {
            read.github = .failed(error)
        }
        if includeSequencing {
            read.plan = read.deskState.map { DeskSequencing.compute($0, now: Date()) }
                ?? DeskSequencing.Plan()
            var aliases: [String: String] = [:]
            for item in read.items { aliases[item.handle] = item.alias }
            read.aliasByHandle = aliases
        }
        if includeOverview {
            read.overview = await loadOverview(read).overview
        }
        return read
    }

    /// The overview and its checked authority lanes share one read with phone snapshots.
    public nonisolated func loadOverview(_ board: DeskBoardRead) async -> (
        overview: WorkOverview,
        approvals: Result<[ApprovalRecord], Error>,
        inbox: Result<[NotificationInbox.InboxItemRecord], Error>
    ) {
        async let approvalsRead = SwiftNativeApprovalInbox(root: dataRoot).list(filter: .init())
        async let inboxRead = InboxFacade(dataRoot: dataRoot).list()
        var unavailable: [String] = []
        if let reason = board.deskError { unavailable.append("Desk: \(reason)") }
        if let reason = board.executions.unavailableReason { unavailable.append("Executions: \(reason)") }
        var approvalRows: [ApprovalRecord] = []
        var inboxRows: [NotificationInbox.InboxItemRecord] = []
        let approvals: Result<[ApprovalRecord], Error>
        let inbox: Result<[NotificationInbox.InboxItemRecord], Error>
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
            inbox: inboxRows, unavailable: unavailable, now: Date()), approvals, inbox)
    }

    /// Every Desk execution, queue then legacy, as the phone's
    /// workshop_tasks.json and the graph's execution count read them. A row
    /// that is not an execution is skipped, but a feed where no row reads is
    /// corruption, never an empty bench, and throws.
    public nonisolated func taskRows() async throws -> [WorkshopTaskRow] {
        let rows = try await SwiftNativeWorkshopRunner(root: dataRoot).listWorkshopExecutionsMerged()
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
    public nonisolated func jobsFeed() async -> SchedulerJobsFeedState {
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
    public nonisolated func listJobs() async throws -> [ScheduledJob] {
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

    public func refreshJobs() async -> SchedulerJobsFeedState {
        let feed = await jobsFeed()
        switch feed {
        case .current(let rows), .partial(let rows, _): jobs = rows
        case .sourceAbsent, .unavailable: break
        }
        return feed
    }

    public func setJobEnabled(id: String, enabled: Bool) async throws -> ScheduledJob {
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Set(connectorActionDescriptors().map(\.id)), dataRoot: dataRoot)
        let result = try await writer.setJobEnabled(jobId: id, enabled: enabled)
        guard case .object(let object) = result, let row = object["job"] else {
            throw SchedulerJobsFeedError.unavailable("scheduler pause/resume returned no job")
        }
        return try ScheduledJob(row: row)
    }

    public func ensureNightlyReflection(scheduler: SchedulerDueJobRunner) async throws -> NightlyReflectionJobOutcome {
        let before: ScheduledJob?
        do {
            before = try await listJobs().first { $0.id == "nativeagent-nightly-dream" }
        } catch SchedulerJobsFeedError.sourceAbsent {
            // Only explicit creation may repair an absent feed; damage stays unavailable.
            before = nil
        }
        // Explicit re-enable clears cancellation, unlike passive bootstrap.
        _ = try await scheduler.ensureDefaultCycleJobs(now: Date(), reactivateCancelled: true)
        let refreshed = try await listJobs()
        jobs = refreshed
        guard let after = refreshed.first(where: { $0.id == "nativeagent-nightly-dream" }) else {
            return .failed("the canonical scheduler job was not persisted")
        }
        if let before { return before == after ? .alreadyPresent : .repaired }
        return .added
    }

    // MARK: research

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
            await SwiftNativeApprovalInbox(root: dataRoot).approvalsPath,
            LiveNotificationInbox.livePath(dataRoot: dataRoot),
            GitHubCommandStore(dataRoot: dataRoot).opsPath,
            GitHubCommandStore(dataRoot: dataRoot).basePath,
            executions,
            DeskFacade(dataRoot: dataRoot).jobsPath,
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
            paths.append(ExecutionRecordFile.legacyPath(in: directory))
        }
        return paths
    }

    public func loadPage() async -> (DeskPageSnapshot, [DeskMissedBot], [DeskTimedBot], Date,
                                      DeskNagConfig, StudioWanderLane.TraceEntry?, Bool) {
        let dataRoot = self.dataRoot
        let loaded = await Task.detached(priority: .userInitiated) {
            await DeskPageSnapshot.load(desk: self)
        }.value
        let missed = await Task.detached(priority: .userInitiated) {
            DeskMissedBot.load(root: dataRoot)
        }.value
        var timed: [DeskTimedBot] = []
        if await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) {
            timed = await Task.detached(priority: .userInitiated) {
                DeskTimedBot.load(root: dataRoot)
            }.value
        }
        let now = Date()
        let nags = await DeskNagConfigStore(dataRoot: dataRoot).load()
        let hour: StudioWanderLane.TraceEntry?
        let hourUnavailable: Bool
        do {
            hour = try await Self.residentHour(dataRoot: dataRoot)
            hourUnavailable = false
        } catch {
            hour = nil
            hourUnavailable = true
        }
        return (loaded, missed, timed, now, nags, hour, hourUnavailable)
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

/// Bounded health projection for the canonical scheduler feed. It does not
/// mutate schedules or infer a zero count from missing state; callers can use
/// it for a live read to distinguish dormant disabled rows from enabled jobs
/// whose advancement has stalled.
public struct SchedulerJobsFeedHealth: Equatable, Sendable {
    public let rowCountByKind: [String: Int]
    public let enabledMissingNextRunIDs: [String]
    public let enabledOverdueNextRunIDs: [String]
    public let enabledStaleLastRunIDs: [String]

    public static func assess(_ jobs: [ScheduledJob], now: Date = Date()) -> SchedulerJobsFeedHealth {
        var rowCountByKind: [String: Int] = [:]
        var missingNextRun: [String] = []
        var overdueNextRun: [String] = []
        var staleLastRun: [String] = []
        let nowEpoch = now.timeIntervalSince1970

        for job in jobs {
            rowCountByKind[job.kind, default: 0] += 1
            guard job.enabled else { continue }
            let cadence = Double(min(max(job.intervalSeconds ?? 3_600, 60), 365 * 24 * 60 * 60))
            if let next = epoch(job.nextRunAt) {
                if nowEpoch - next > cadence {
                    overdueNextRun.append(job.id)
                }
            } else {
                missingNextRun.append(job.id)
            }
            if let last = epoch(job.lastRunAt), nowEpoch - last > cadence * 2 {
                staleLastRun.append(job.id)
            }
        }
        return SchedulerJobsFeedHealth(
            rowCountByKind: rowCountByKind,
            enabledMissingNextRunIDs: missingNextRun,
            enabledOverdueNextRunIDs: overdueNextRun,
            enabledStaleLastRunIDs: staleLastRun
        )
    }

    private static func epoch(_ raw: String?) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let numeric = TimeInterval(raw), numeric.isFinite { return numeric }
        return ISO8601DateFormatter().date(from: raw)?.timeIntervalSince1970
    }
    public init(
        rowCountByKind: [String: Int],
        enabledMissingNextRunIDs: [String],
        enabledOverdueNextRunIDs: [String],
        enabledStaleLastRunIDs: [String]
    ) {
        self.rowCountByKind = rowCountByKind
        self.enabledMissingNextRunIDs = enabledMissingNextRunIDs
        self.enabledOverdueNextRunIDs = enabledOverdueNextRunIDs
        self.enabledStaleLastRunIDs = enabledStaleLastRunIDs
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
        guard !malformed else { return nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id, deskHandle, projectSpaceId, title, objective, status, phase, priority
        case autonomyLevel, permissionProfile, summary
        case createdAt, updatedAt, lastMovementAt, completedAt, receiptCount
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
        let gated = makeGatedToolDispatchClient(
            tools: SwiftToolDispatcher(
                dataRoot: dataRoot,
                agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
            ),
            fileAccess: "auto",
            approvalFiler: DeskClickApprovalFiler(dataRoot: dataRoot),
            dataRoot: dataRoot
        )
        return try await gated.dispatch(
            tool: tool, input: input, surface: surface)
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
