import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ExecutionRecordFile.swift` | Canonical execution record/timeline I/O; active records from another DataRootLife or unstamped records read stopped with terminal_reason restored before every claim/recovery/update; no filesystem migration on read |

/// The owner of per-execution record and timeline I/O inside
/// `<dataRoot>/workshop/executions/<id>/`.
///
/// Only `execution.json` is live. Retired `mission.json`, its lock/conflict
/// files and workshop/migrations evidence stay untouched for the owner to decide.
/// No reader prepares, renames or repairs files on disk.
/// Coverage: local backup and production export include workshop/; phone sync
/// carries task projections only; PrivacyMap lists the Workshop tree.
/// Mission-named JSON keys (`missionId` / `mission_id` / `missionPolicy` /
/// `related_mission_id`), event kinds, surface strings and tool names keep
/// their persisted wire IDs.
public enum ExecutionRecordFile {
    /// Name every new record is written under.
    public static let canonicalName = "execution.json"

    /// Canonical (write-target) path inside an execution directory.
    public static func canonicalPath(in directory: URL) -> URL {
        directory.appendingPathComponent(canonicalName)
    }

    static func receiptsPath(in directory: URL) -> URL {
        directory.appendingPathComponent("receipts", isDirectory: true)
    }

    static func timelinePath(in directory: URL) -> URL {
        directory.appendingPathComponent("timeline.jsonl")
    }

    /// True when `directory` holds the live execution record.
    public static func exists(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: canonicalPath(in: directory).path)
    }

    /// Receipt location comes from the execution folder, never a stale saved pointer.
    static func readJSON(at path: URL, using persistence: any PersistenceCoreProtocol) async throws -> JSONValue {
        let raw = try await persistence.readJSON(path, ifMissing: .null)
        switch raw {
        case .object(var record):
            if case .string(let status)? = record["status"],
               ["queued", "running", "blocked_on_approval", "blocked_on_reconciliation"].contains(status) {
                let root = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let lifeID: String? = if case .string(let id)? = record["lifeID"] { id } else { nil }
                if try !DataRootLife.isCurrent(lifeID, in: root) {
                    record["status"] = .string("stopped")
                    record["terminal_reason"] = .string(DataRootLife.stoppedReason)
                }
            }
            record["receipts_dir"] = .string(receiptsPath(in: path.deletingLastPathComponent()).path)
            return .object(record)
        default:
            return raw
        }
    }

    static func write(_ record: WorkshopExecutionRecord, to path: URL, using persistence: any PersistenceCoreProtocol) async throws {
        try await persistence.withFileLock(path) {
            try await persistence.writeJSON(record.toJSON(), to: path)
        }
    }

    /// One locked read/check/mutate/write. The caller supplies its domain transition.
    static func update(
        at path: URL, id: String, using persistence: any PersistenceCoreProtocol,
        _ change: @escaping @Sendable (inout WorkshopExecutionRecord) async throws -> Bool
    ) async throws -> (record: WorkshopExecutionRecord?, applied: Bool) {
        try await persistence.withFileLock(path) {
            guard case .object(let object) = try await readJSON(at: path, using: persistence),
                  case .string(let storedID)? = object["id"], storedID == id else { return (nil, false) }
            var record = SwiftNativeWorkshopRunner.recordFromJSON(object)
            guard try await change(&record) else { return (record, false) }
            try await persistence.writeJSON(record.toJSON(), to: path)
            return (record, true)
        }
    }

    static func readLocked(at path: URL, id: String, using persistence: any PersistenceCoreProtocol) async throws -> WorkshopExecutionRecord? {
        try await persistence.withFileLock(path) {
            guard case .object(let object) = try await readJSON(at: path, using: persistence),
                  case .string(let storedID)? = object["id"], storedID == id else { return nil }
            return SwiftNativeWorkshopRunner.recordFromJSON(object)
        }
    }

    /// Timeline schema: JSON event objects, with event/ts and event-specific evidence.
    static func appendTimeline(_ event: JSONValue, to path: URL, using persistence: any PersistenceCoreProtocol) async throws {
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(event, to: path)
        }
    }

    static func readTimeline(at path: URL, using persistence: any PersistenceCoreProtocol) async throws -> [JSONValue] {
        try await persistence.readJSONL(path)
    }

    /// Approval reconciliation clears only its stamp, preserving all other raw fields.
    public static func clearStepApprovalClaim(
        executionId: String, stepId: String, dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async throws {
        let path = canonicalPath(in: dataRoot.appendingPathComponent("workshop/executions", isDirectory: true)
            .appendingPathComponent(executionId, isDirectory: true))
        try await persistence.withFileLock(path) {
            let raw = try await persistence.readJSON(path, ifMissing: .null)
            guard case .object(var obj) = raw,
                  case .array(var steps)? = obj["steps_completed"] else { return }
            var changed = false
            for idx in steps.indices {
                guard case .object(var sr) = steps[idx],
                      case .string(let sid)? = sr["step_id"], sid == stepId,
                      case .string(let st)? = sr["status"], st == "blocked_on_approval" else { continue }
                sr["approval_id"] = .string("")
                steps[idx] = .object(sr)
                changed = true
            }
            guard changed else { return }
            obj["steps_completed"] = .array(steps)
            try await persistence.writeJSON(.object(obj), to: path)
        }
    }
}
