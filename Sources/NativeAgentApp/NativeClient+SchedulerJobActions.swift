import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

enum SchedulerJobsFeedState: Equatable {
    case current([SchedulerJob])
    case partial([SchedulerJob], rejectedRows: Int)
    case sourceAbsent
    case unavailable(String)

    var failureDetail: String? {
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

enum SchedulerJobsFeedError: LocalizedError {
    case sourceAbsent
    case partial(rejectedRows: Int)
    case unavailable(String)

    var errorDescription: String? {
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
struct SchedulerJobsFeedHealth: Equatable {
    let rowCountByKind: [String: Int]
    let enabledMissingNextRunIDs: [String]
    let enabledOverdueNextRunIDs: [String]
    let enabledStaleLastRunIDs: [String]

    static func assess(_ jobs: [SchedulerJob], now: Date = Date()) -> SchedulerJobsFeedHealth {
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
}

extension NativeClient {
    static let schedulerJobsFeedMaximumBytes = 4 * 1_024 * 1_024
    static let schedulerJobsFeedMaximumRows = 1_024

    var schedulerJobsPath: URL {
        (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    /// Read the canonical jobs feed without treating absent, damaged, or
    /// partially decodable durable state as an empty schedule. The final row
    /// projection comes from `SchedulerJobWriter.listJobs()` so callers retain
    /// the same next-run decoration as the production list route.
    func schedulerJobsFeed() async -> SchedulerJobsFeedState {
        let path = schedulerJobsPath
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
            guard data.count <= Self.schedulerJobsFeedMaximumBytes else {
                return .unavailable("scheduler/jobs.json exceeds \(Self.schedulerJobsFeedMaximumBytes) bytes")
            }
            let raw = try JSONValue.parse(data)
            guard case .array(let sourceRows) = raw else {
                return .unavailable("scheduler/jobs.json must contain a JSON array")
            }
            guard sourceRows.count <= Self.schedulerJobsFeedMaximumRows else {
                return .unavailable("scheduler/jobs.json exceeds \(Self.schedulerJobsFeedMaximumRows) rows")
            }

            let writer = makeSchedulerJobWriter(
                connectorActionIDs: Self.connectorActionIDSet(),
                dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
            )
            let rows = try await writer.listJobs()
            guard rows.count <= Self.schedulerJobsFeedMaximumRows else {
                return .unavailable("scheduler list returned more than \(Self.schedulerJobsFeedMaximumRows) rows")
            }
            guard !rows.isEmpty || sourceRows.isEmpty else {
                return .unavailable("scheduler/jobs.json changed while it was being read; retry")
            }

            var jobs: [SchedulerJob] = []
            var rejectedRows = 0
            jobs.reserveCapacity(rows.count)
            for row in rows {
                do {
                    let rowData = try row.serializedData(pretty: false)
                    jobs.append(try JSONDecoder().decode(SchedulerJob.self, from: rowData))
                } catch {
                    rejectedRows += 1
                }
            }
            return rejectedRows == 0 ? .current(jobs) : .partial(jobs, rejectedRows: rejectedRows)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func createJob(name: String, kind: String, intervalSeconds: Int) async throws -> SchedulerJob {
        // WAVE 33 W18 (2026-06-01): the POST /v1/scheduler/jobs WRITE is ported
        // into SwiftNative TriggerScheduler (create_job → normalize +
        // flock'd jobs.json append + activity event).
        // Connector-action jobs validate against the Swift action registry when
        // callers provide that kind; ordinary notify/dream/improve jobs remain
        // fully native.
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Self.connectorActionIDSet(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let body: JSONValue = .object([
            "name": .string(name),
            "kind": .string(kind),
            "interval_seconds": .int(Int64(intervalSeconds)),
        ])
        let jobJSON = try await writer.createJob(body: body)
        let data = try jobJSON.serializedData(pretty: false)
        return try JSONDecoder().decode(SchedulerJob.self, from: data)
    }

    func cancelSchedulerJob(id: String) async throws -> SchedulerJob {
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Self.connectorActionIDSet(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let result = try await writer.cancelJob(jobId: id)
        guard case .object(let object) = result,
              let job = object["job"] else {
            throw SchedulerJobsFeedError.unavailable("scheduler cancellation returned no job")
        }
        return try JSONDecoder().decode(SchedulerJob.self, from: job.serializedData(pretty: false))
    }

    // PATCH-2026-05-06: skill-ui NativeClient — skill lifecycle endpoints (v1: filesystem fallback; v2: route through HTTP)
    // v1: reads manifest_registry.json and individual manifest.json files directly from disk.
    // v2 will replace readSkillRegistry/readSkillManifest with GET /v1/skills/list and GET /v1/skills/{name}.

    // PATCH-2026-05-07: cli-registry-clash — read manifest_registry.json (CLI dict format) not registry.json (daemon list format)
}
