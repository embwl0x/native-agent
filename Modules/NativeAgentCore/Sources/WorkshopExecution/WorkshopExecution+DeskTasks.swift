import Foundation
import NativeAgentCore
import PersistenceCore

/// Result of shadow-submitting a user-directed task through the Workshop. The
/// Desk handle is the durable user-facing identity; `executionId` is only the
/// compatibility executor key while the old queue storage is being absorbed.
public struct WorkshopDirectedTaskResult: Sendable, Equatable {
    public var deskItem: DeskItem
    public var executionId: String
    public var execution: WorkshopExecutionRecord

    public init(deskItem: DeskItem, executionId: String, execution: WorkshopExecutionRecord) {
        self.deskItem = deskItem
        self.executionId = executionId
        self.execution = execution
    }
}

/// Desk-first submission boundary for user-directed multi-step work. It leaves
/// the existing runner intact underneath so consumers can migrate one at a
/// time without breaking the proven executor.
public struct WorkshopDirectedTaskSubmitter: Sendable {
    public let dataRoot: URL
    public let runner: any WorkshopRunnerClient

    public init(dataRoot: URL, runner: any WorkshopRunnerClient) {
        self.dataRoot = dataRoot
        self.runner = runner
    }

    public func submit(
        spec: WorkshopExecutionSpec,
        project: String = "Workshop"
    ) async throws -> WorkshopDirectedTaskResult {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let item = try await store.createItem(
            kind: .project,
            project: project,
            title: String(spec.title.prefix(160)),
            summary: String(spec.objective.prefix(600))
        )
        _ = try await store.setStatus(item.handle, status: .now)

        var linkedSpec = spec
        linkedSpec.deskHandle = item.handle
        do {
            let enqueued = try await runner.submit(spec: linkedSpec)
            _ = try? await store.addRef(
                item.handle,
                ref: DeskRef(kind: .trace(id: enqueued.executionId, kind: "workshop_execution"))
            )
            _ = try? await store.appendNote(
                item.handle,
                text: "Workshop execution queued: \(enqueued.executionId)"
            )
            let state = try await store.liveState()
            let current = state.items.first(where: { $0.handle == item.handle }) ?? item
            return WorkshopDirectedTaskResult(
                deskItem: current,
                executionId: enqueued.executionId,
                execution: enqueued.record
            )
        } catch {
            _ = try? await store.setStatus(
                item.handle,
                status: .blocked,
                blockedReason: String(error.localizedDescription.prefix(600))
            )
            _ = try? await store.appendNote(
                item.handle,
                text: "Workshop submission refused: \(String(error.localizedDescription.prefix(600)))"
            )
            throw error
        }
    }
}

/// One multi-step terminal receipt in the Phase-1 Workshop receipt feed. Both
/// single-session pursuits and directed tasks therefore measure from one
/// handle-keyed source instead of maintaining a second global scoreboard log.
public struct WorkshopDirectedTaskReceipt: Sendable, Equatable {
    public var handle: String
    public var executionId: String
    public var status: String
    public var summary: String
    public var createdAt: String
    public var completedAt: String
    public var totalSteps: Int
    public var completedSteps: Int
    public var rerunCount: Int
    public var triggerSource: String
    public var wasStub: Bool

    public func toJSON() -> JSONValue {
        .object([
            "kind": .string("directed_task"),
            "handle": .string(handle),
            "reservationId": .string(executionId),
            "executionId": .string(executionId),
            "status": .string(status),
            "model": .null,
            "artifactCount": .int(0),
            "summary": .string(String(summary.prefix(600))),
            "ts": .string(completedAt),
            "createdAt": .string(createdAt),
            "totalSteps": .int(Int64(totalSteps)),
            "completedSteps": .int(Int64(completedSteps)),
            "rerunCount": .int(Int64(rerunCount)),
            "triggerSource": .string(triggerSource),
            "wasStub": .bool(wasStub),
        ])
    }

    public static func fromJSON(_ value: JSONValue) -> WorkshopDirectedTaskReceipt? {
        guard case .object(let object) = value,
              case .string("directed_task")? = object["kind"] else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let value)? = object[key] { return value }
            return nil
        }
        func int(_ key: String) -> Int {
            switch object[key] ?? .null {
            case .int(let value): return Int(value)
            case .double(let value): return Int(value)
            default: return 0
            }
        }
        guard let handle = string("handle"), !handle.isEmpty,
              let executionId = string("executionId") ?? string("reservationId"), !executionId.isEmpty,
              let status = string("status"),
              let completedAt = string("ts") else { return nil }
        return WorkshopDirectedTaskReceipt(
            handle: handle,
            executionId: executionId,
            status: status,
            summary: string("summary") ?? "",
            createdAt: string("createdAt") ?? completedAt,
            completedAt: completedAt,
            totalSteps: int("totalSteps"),
            completedSteps: int("completedSteps"),
            rerunCount: int("rerunCount"),
            triggerSource: string("triggerSource") ?? "manual",
            wasStub: object["wasStub"] == .bool(true)
        )
    }
}

public enum WorkshopDeskReceiptBridge {
    public static func recordTerminal(
        _ record: WorkshopExecutionRecord,
        reason: String?,
        dataRoot: URL
    ) async {
        guard ["completed", "done", "succeeded", "failed", "cancelled", "canceled"]
            .contains(record.status.lowercased()) else { return }
        guard let handle = record.deskHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else { return }

        let persistence = SwiftNativePersistenceCore()
        let receiptPath = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        let timelinePath = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent("timeline.jsonl")
        let timeline = (try? await persistence.readJSONL(timelinePath)) ?? []
        let wasStub = timeline.contains { row in
            if case .object(let object) = row,
               case .string("planner_fallback")? = object["event"] { return true }
            return false
        }
        let summary = terminalSummary(record, reason: reason)
        let receipt = WorkshopDirectedTaskReceipt(
            handle: handle,
            executionId: record.id,
            status: record.status,
            summary: summary,
            createdAt: record.createdAt,
            completedAt: record.updatedAt,
            totalSteps: record.plan.count,
            completedSteps: record.stepsCompleted.count,
            rerunCount: record.rerunCount,
            triggerSource: record.triggerSource,
            wasStub: wasStub
        )

        do {
            try await persistence.withFileLock(receiptPath) {
                let existing = try await persistence.readJSONL(receiptPath)
                    .compactMap(WorkshopDirectedTaskReceipt.fromJSON)
                guard !existing.contains(where: {
                    $0.executionId == receipt.executionId && $0.status == receipt.status
                }) else { return }
                try await persistence.appendJSONLDurable(receipt.toJSON(), to: receiptPath)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "Workshop Desk receipt write failed for \(record.id): \(error)\n".utf8))
        }

        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        guard let state = try? await store.liveState(),
              let item = state.items.first(where: { $0.handle == handle }) else { return }
        let note = "[\(record.status)] \(summary)"
        if !item.notes.contains(where: { $0.text == note }) {
            do {
                _ = try await store.appendNote(handle, text: note)
            } catch {
                FileHandle.standardError.write(Data(
                    "Workshop Desk note settlement failed for \(record.id): \(error)\n".utf8))
            }
        }
        switch record.status {
        case "completed", "done", "succeeded":
            if record.verification?.status == .satisfied, !item.status.isTerminal {
                do { _ = try await store.closeItem(handle, outcomeSummary: summary) }
                catch {
                    FileHandle.standardError.write(Data(
                        "Workshop Desk completion settlement failed for \(record.id): \(error)\n".utf8))
                }
            } else if !item.status.isTerminal {
                // A model/tool sequence finishing is not evidence that its
                // claimed effect happened. Keep the durable commitment open
                // until a canonical domain verifier (or the operator) resolves
                // it; no follow-up LLM is recruited for this classification.
                let detail = record.verification?.detail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reason: String
                if let detail, !detail.isEmpty {
                    reason = "Workshop finished but remains unverified: \(String(detail.prefix(480)))"
                } else {
                    reason = "Workshop finished without an exact verification record."
                }
                guard item.status != .blocked
                        || item.blockedReason != reason
                        || item.waitingOn != "domain verification" else { break }
                do {
                    _ = try await store.setStatus(handle, status: .blocked,
                                                  blockedReason: reason,
                                                  waitingOn: "domain verification")
                } catch {
                    FileHandle.standardError.write(Data(
                        "Workshop Desk verification settlement failed for \(record.id): \(error)\n".utf8))
                }
            }
        case "cancelled", "canceled":
            if !item.status.isTerminal {
                do { _ = try await store.closeItem(handle, outcomeSummary: summary, canceled: true) }
                catch {
                    FileHandle.standardError.write(Data(
                        "Workshop Desk cancellation settlement failed for \(record.id): \(error)\n".utf8))
                }
            }
        case "failed":
            if !item.status.isTerminal,
               item.status != .blocked || item.blockedReason != summary {
                do { _ = try await store.setStatus(handle, status: .blocked, blockedReason: summary) }
                catch {
                    FileHandle.standardError.write(Data(
                        "Workshop Desk failure settlement failed for \(record.id): \(error)\n".utf8))
                }
            }
        default:
            break
        }
    }

    private static func terminalSummary(_ record: WorkshopExecutionRecord, reason: String?) -> String {
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return String(reason.prefix(600))
        }
        switch record.result {
        case .string(let value) where !value.isEmpty:
            return String(value.prefix(600))
        default:
            return "Workshop task \(record.status) after \(record.stepsCompleted.count)/\(record.plan.count) steps."
        }
    }
}
