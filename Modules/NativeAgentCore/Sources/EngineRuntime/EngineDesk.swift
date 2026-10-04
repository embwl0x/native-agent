import TrustCenter
import Desk
import GitHubConnector
import Foundation
import Observation
import PersistenceCore
import Research
import TriggerScheduler
import WorkshopExecution
import ApprovalInbox
import NativeAgentShared
import NotificationInbox

/// `NativeAgentEngine.desk` (S10): the Desk for one data root, in core types —
/// the board (desk items, executions, GitHub), the schedule, and research lab
/// runs. The Desk pages, the Schedule and Capabilities render `jobs` and
/// `researchRuns`; the reads are nonisolated so the phone snapshot and the
/// phone's desk actions use the same owner. Writes (new tasks, job pause and
/// cancel, research runs) still run through the executors on `NativeClient`.
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
        do {
            read.deskState = try await store.liveState()
        } catch {
            read.deskError = Self.loadFailure(error)
        }
        // Execution and GitHub reads stay independent: one broken lane never
        // blanks the other live Workshop projections. But "lenient" used to
        // mean "silent" — a corrupt store returned [] and the surface said
        // "Quiet right now". Each lane now reports rows OR a reason.
        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
        let records = await runner.listAll()
        read.executions = DeskLaneState.classify(
            rows: records,
            probe: Self.probeExecutionRecords(runner.executionRecordsRoot),
            noun: "execution record(s)")
        do {
            read.github = .rows(try await GitHubCommandStore(dataRoot: dataRoot).liveState().items)
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
            var unavailable: [String] = []
            if let reason = read.deskError { unavailable.append("Desk: \(reason)") }
            if let reason = read.executions.unavailableReason { unavailable.append("Executions: \(reason)") }
            var approvals: [ApprovalRecord] = []
            var inbox: [NotificationInbox.InboxItemRecord] = []
            do { approvals = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .init()) }
            catch { unavailable.append("Approvals: \(Self.loadFailure(error))") }
            do { inbox = try await InboxFacade(dataRoot: dataRoot).list() }
            catch { unavailable.append("Inbox: \(Self.loadFailure(error))") }
            read.overview = WorkOverviewRead.project(board: read, approvals: approvals,
                inbox: inbox, unavailable: unavailable, now: Date())
        }
        return read
    }

    /// Every Desk execution, queue then legacy, as the phone's
    /// workshop_tasks.json and the graph's execution count read them. A row
    /// that is not an execution is skipped, but a feed where no row reads is
    /// corruption, never an empty bench, and throws.
    public nonisolated func taskRows() async throws -> [WorkshopTaskRow] {
        let rows = try await SwiftNativeWorkshopRunner(root: dataRoot).listWorkshopExecutionsMerged()
        let tasks = rows.compactMap(WorkshopTaskRow.init(row:))
        if tasks.count < rows.count {
            NSLog("[DeskFacade] taskRows dropped \(rows.count - tasks.count) of \(rows.count) malformed execution row(s)")
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

    public nonisolated static let jobsFeedMaximumBytes = 4 * 1_024 * 1_024
    public nonisolated static let jobsFeedMaximumRows = 1_024

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
            let data = try Data(contentsOf: path)
            guard data.count <= Self.jobsFeedMaximumBytes else {
                return .unavailable("scheduler/jobs.json exceeds \(Self.jobsFeedMaximumBytes) bytes")
            }
            let raw = try JSONValue.parse(data)
            guard case .array(let sourceRows) = raw else {
                return .unavailable("scheduler/jobs.json must contain a JSON array")
            }
            guard sourceRows.count <= Self.jobsFeedMaximumRows else {
                return .unavailable("scheduler/jobs.json exceeds \(Self.jobsFeedMaximumRows) rows")
            }

            let writer = makeSchedulerJobWriter(
                connectorActionIDs: Set(connectorActionDescriptors().map(\.id)),
                dataRoot: dataRoot
            )
            let rows = try await writer.listJobs()
            guard rows.count <= Self.jobsFeedMaximumRows else {
                return .unavailable("scheduler list returned more than \(Self.jobsFeedMaximumRows) rows")
            }
            guard !rows.isEmpty || sourceRows.isEmpty else {
                return .unavailable("scheduler/jobs.json changed while it was being read; retry")
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

    // MARK: research

    /// Research lab runs from `research/lab/runs.json`, newest first. A run
    /// that does not read is skipped.
    public nonisolated func listResearchRuns() async throws -> [ResearchLabRun] {
        try await makeResearchClient(dataRoot: dataRoot).researchLabRuns()
            .compactMap(ResearchLabRun.init(row:))
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
