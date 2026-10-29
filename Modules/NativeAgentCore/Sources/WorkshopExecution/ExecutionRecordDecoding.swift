import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy
import SwarmRuns
import os
import NativeAgentCore
import ProviderRouting
import TrustCenter
import Desk
import MacIntegration
import ToolRegistry
import ChatToolParsing
// Blueprint: | `ExecutionRecordDecoding.swift` | SwiftNativeWorkshopRunner execution-record decoding, faithful validation and persisted plan parsing |

extension SwiftNativeWorkshopRunner {
    /// Executable records must round-trip without losing a field or plan row.
    /// Optional fields absent in older records remain absent; no file is repaired.
    static func checkedRecordFromJSON(_ object: [String: JSONValue]) throws -> WorkshopExecutionRecord {
        let record = recordFromJSON(object)
        guard !record.id.isEmpty, record.rerunCount >= 0,
              record.planningProviderCallCount.map({ $0 >= 0 }) ?? true,
              record.planningRemovableOrchestrationProviderCallCount.map({ $0 >= 0 }) ?? true,
              record.toJSON() == .object(object) else {
            throw WorkshopExecutionError.persistenceFailure("Execution record cannot be decoded faithfully; saved bytes were preserved")
        }
        try validateStepIDs(record.plan)
        for step in record.plan {
            guard !step.toolOrAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["auto", "needs_approval"].contains(step.autonomy), case .object = step.args else {
                throw WorkshopExecutionError.persistenceFailure("Execution plan contains an unsupported step; saved bytes were preserved")
            }
        }
        if ["queued", "pending", "running", "blocked_on_approval", "blocked_on_reconciliation"].contains(record.status), record.plan.isEmpty {
            throw WorkshopExecutionError.persistenceFailure("Executable record has no plan; saved bytes were preserved")
        }
        return record
    }

    /// Decode partial saved records with the persisted field defaults.
    static func recordFromJSON(_ obj: [String: JSONValue]) -> WorkshopExecutionRecord {
        func i(_ key: String) -> Int {
            obj[key]?.integerValue.flatMap { Int(exactly: $0) }
                ?? obj[key]?.stringValue.flatMap(Int.init) ?? 0
        }
        func optionalInt(_ key: String) -> Int? {
            guard obj[key] != nil else { return nil }
            return i(key)
        }
        return WorkshopExecutionRecord(
            id: obj["id"]?.stringValue ?? "",
            lifeID: obj["lifeID"]?.stringValue,
            deskHandle: {
                let value = (obj["desk_handle"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }(),
            projectSpaceId: {
                let value = (obj["project_space_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }(),
            title: obj["title"]?.stringValue ?? "",
            objective: obj["objective"]?.stringValue ?? "",
            createdAt: obj["created_at"]?.stringValue ?? "",
            status: obj["status"]?.stringValue ?? "queued",
            plan: parsePlanSteps(obj["plan"]),
            stepsCompleted: obj["steps_completed"]?.arrayValue ?? [],
            receiptsDir: obj["receipts_dir"]?.stringValue ?? "",
            triggerSource: obj["trigger_source"]?.stringValue ?? "manual",
            trustRequired: obj["trust_required"]?.stringValue ?? "none",
            expectedOutputs: obj["expected_outputs"]?.arrayValue ?? [],
            currentStepId: obj["current_step_id"]?.stringValue ?? "",
            updatedAt: obj["updated_at"]?.stringValue ?? "",
            result: obj["result"] ?? .null,
            rerunCount: i("rerun_count"),
            planningProviderCallCount: optionalInt("planning_provider_call_count"),
            planningRemovableOrchestrationProviderCallCount:
                optionalInt("planning_removable_orchestration_provider_call_count"),
            verification: WorkshopVerificationRecord.fromJSON(obj["verification"]),
            lastMovementAt: obj["last_movement_at"]?.stringValue,
            compiledOperationBinding: obj["compiled_operation_binding"],
            terminalReason: obj["terminal_reason"]?.stringValue
        )
    }

    static func parsePlanSteps(_ v: JSONValue?) -> [WorkshopExecutionStep] {
        guard let arr = v?.arrayValue else { return [] }
        var out: [WorkshopExecutionStep] = []
        for item in arr {
            guard case .object(let o) = item else { continue }
            let id = o["id"]?.stringValue ?? ""
            let desc = o["description"]?.stringValue ?? ""
            let tool = o["tool_or_action"]?.stringValue ?? ""
            let auto = o["autonomy"]?.stringValue ?? "auto"
            let args = JSONValue.object(o["args"]?.objectValue ?? [:])
            let optional = o["optional"]?.boolValue
            out.append(WorkshopExecutionStep(id: id, description: desc, toolOrAction: tool, args: args, autonomy: auto, argumentSchema: o["argument_schema"], optional: optional))
        }
        return out
    }

    static func validateStepIDs(_ steps: [WorkshopExecutionStep]) throws {
        var seen: Set<String> = []
        for step in steps {
            guard seen.insert(step.id).inserted else {
                throw WorkshopExecutionError.invalidRequest("Duplicate Workshop step ID: \(step.id)")
            }
        }
    }

}
