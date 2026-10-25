import Foundation
import NativeAgentCore
import Desk
import DoctorChecks
import NativeAgentShared
import PersistenceCore
import DeviceSync
import ToolExecution
// Blueprint: | `EngineDoctor+StatusChecks.swift` | `DoctorFacade`: checked Desk attention and Activity facts go through L0 Parts.call to Resources/abilities/diagnostic-narration.js outside view rendering; native measured status, approval/store failures, corruption detection, unknown-outcome reconciliation and parent repair remain here; an unavailable narrator is explicit without being mistaken for a canonical read failure |

private struct DiagnosticNarration: Codable, Sendable {
    let detail: String
    let humanAction: String?
}

extension DoctorFacade {
    public static func statusChecks(dataRoot root: URL, approvals: ApprovalsFacade, repairDesk: Bool,
                                    stuckReason: (DeskItem, [DeskItem]) -> String,
                                    safeDetail: (String) -> String) async -> (checks: [CheckResult], repaired: Bool) {
        let desk = await deskCheck(approvals: approvals, root: root, repair: repairDesk, stuckReason: stuckReason, safeDetail: safeDetail)
        let activity = await activityCheck(root: root, safeDetail: safeDetail)
        let rows = [desk.row, activity]
        await DoctorStatusProjection.recordReadings(rows, dataRoot: root)
        return (rows, desk.repaired)
    }

    private static func deskCheck(approvals: ApprovalsFacade, root: URL, repair: Bool, stuckReason: (DeskItem, [DeskItem]) -> String, safeDetail: (String) -> String) async -> (row: CheckResult, repaired: Bool) {
        let store = SwiftNativeDeskStore(dataRoot: root)
        do {
            var state = try await store.liveState()
            let initialContradictions = SwiftNativeDeskStore.terminalParentsWithNonTerminalDescendants(in: state)
            var repaired = false
            if repair && !initialContradictions.isEmpty {
                let ops = try await store.reconcileTerminalParentsWithNonTerminalDescendants()
                repaired = !ops.isEmpty
                state = try await store.liveState()
            }
            let items = state.items
            let contradictions = SwiftNativeDeskStore.terminalParentsWithNonTerminalDescendants(in: state)
            let waiting = items.filter { $0.requiresOwnerInput }
            let blocked = items.filter { $0.status == .blocked && !$0.requiresOwnerInput }
            let pendingApprovals: Int
            do {
                pendingApprovals = try await approvals.list()
                    .filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }.count
            } catch {
                return (CheckResult(source: "workflows/approvals/requests.json",
                                    id: "status.desk_attention", title: "Desk work and decisions", status: "fail",
                                    detail: "Approvals could not be read: \(safeDetail(error.localizedDescription)).",
                                    harm: "Pending decisions cannot be read or safely settled.",
                                    human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent("workflows/approvals/requests.json"),
                                        shape: "A JSON array of saved approval requests with their original identities, payloads and decisions. Preserve all authority and decision fields exactly; never approve, deny or invent a request.") + " Open Approvals and refresh its pending list; inspect the approval store before changing any saved request."), repaired)
            }
            let id = "status.desk_attention"
            let title = "Desk work and decisions"
            func group(_ items: [DeskItem]) -> [String: JSONValue] {
                ["count": .int(Int64(items.count)), "aliases": .array(items.map { .string(String($0.alias)) })]
            }
            var blockedFacts = group(blocked)
            blockedFacts["items"] = .array(blocked.map {
                .object(["alias": .string(String($0.alias)), "reason": .string(safeDetail(stuckReason($0, items)))])
            })
            let narration = await diagnosticNarration(root: root, input: .object([
                "kind": .string("desk"), "pendingApprovals": .int(Int64(pendingApprovals)),
                "waiting": .object(group(waiting)), "blocked": .object(blockedFacts), "contradictions": .object(group(contradictions))
            ]), safeDetail: safeDetail)
            let severity = contradictions.isEmpty ? "ok" : "warn"
            return (CheckResult(source: "desk/desk_ops_base.json and desk/desk_ops.jsonl", id: id, title: title, status: severity, detail: narration.detail,
                                harm: severity == "warn" ? "The named Desk work cannot move forward or is marked finished while work remains." : nil,
                                repair: contradictions.isEmpty ? nil : "Press Repair in Diagnostics → Health checks to reconcile terminal Desk parents with open descendants.",
                                human_action: narration.humanAction,
                                repair_available: pendingApprovals > 0 || !waiting.isEmpty || !blocked.isEmpty || !contradictions.isEmpty
                                    ? !contradictions.isEmpty : nil), repaired)
        } catch {
            let file: URL?
            switch error {
            case DeskError.compactionBaseCorrupt(let path), DeskError.compactionBaseUnreadable(let path): file = URL(fileURLWithPath: path)
            default:
                let path = (error as NSError).userInfo[NSFilePathErrorKey] as? String
                file = path.flatMap { $0 == store.opsPath.path || $0 == store.basePath.path ? URL(fileURLWithPath: $0) : nil }
            }
            return (CheckResult(source: file?.path ?? "desk/desk_ops_base.json and desk/desk_ops.jsonl",
                                id: "status.desk_attention", title: "Desk work and decisions", status: "fail",
                                detail: "Desk's canonical state could not be read: \(safeDetail(error.localizedDescription)).",
                                harm: "Saved work cannot be read or safely advanced.",
                                human_action: [file.map { ToolFailureError.fileRepairInstruction($0,
                                    shape: "The Desk compaction base holds the saved items and lastCompactedOpId; its JSONL tail holds DeskOp events. Preserve identities, parent links, continuations and recorded outcomes.") }, file == nil
                                    ? "Open Trust → Advanced → Backups, select a verified backup containing desk/desk_ops_base.json and desk/desk_ops.jsonl, then choose Restore → Restore backup."
                                    : "Open Desk and inspect its unavailable-state detail before recovering the named canonical feed."].compactMap { $0 }.joined(separator: " "),
                                ask: file == nil ? .permission : nil), false)
        }
    }

    private static func diagnosticNarration(root: URL, input: JSONValue, safeDetail: (String) -> String) async -> DiagnosticNarration {
        do {
            return try await NativeAgentEngine.forRoot(root).tools.withPartDoor(envelope: .native("doctor:status-narration")) {
                switch await Parts(root: root).call(id: "diagnostic-narration", input: input, as: DiagnosticNarration.self) {
                case .success(let narration): return narration
                case .failure(let error): throw error
                }
            }
        } catch {
            // An unavailable author is not an unavailable canonical store and
            // never changes the measured status or repair eligibility.
            return DiagnosticNarration(detail: "Diagnostic part unavailable: \(safeDetail(error.localizedDescription)).", humanAction: nil)
        }
    }

    private static func activityCheck(root: URL, safeDetail: (String) -> String) async -> CheckResult {
        let id = "status.activity"
        let title = "Recent activity"
        do {
            let readout = try await RuntimeReadProjection.getActivityReadout(root: root)
            let cutoff = Date().addingTimeInterval(-15 * 60)
            let formatter = ISO8601DateFormatter()
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // A later receipt or an age cutoff cannot reconcile an unknown effect.
            let reconciliation = readout.records.filter(\.needsReconciliation)
            let current = readout.records.filter { record in
                guard !record.needsReconciliation,
                      ["fail", "failed", "error"].contains(record.event.status.lowercased()),
                      let date = fractionalFormatter.date(from: record.event.createdAt)
                        ?? formatter.date(from: record.event.createdAt) else { return false }
                return date >= cutoff && date <= Date().addingTimeInterval(60)
            }
            let malformed = readout.malformedRowCount
            let narration = await diagnosticNarration(root: root, input: .object([
                "kind": .string("activity"), "malformedCount": .int(Int64(malformed)),
                "recordCount": .int(Int64(readout.records.count)), "reconciliationCount": .int(Int64(reconciliation.count)),
                "failureCount": .int(Int64(current.count)), "recent": .array((reconciliation + current).map {
                    .object(["createdAt": .string($0.event.createdAt), "title": .string(safeDetail($0.event.title))])
                })
            ]), safeDetail: safeDetail)
            return CheckResult(source: "activity/events.jsonl",
                               id: id, title: title, status: malformed > 0 ? "fail" : reconciliation.isEmpty ? "ok" : "unmeasured",
                               detail: narration.detail,
                               harm: malformed > 0 ? "Parts of the activity history cannot be reviewed." : nil,
                               human_action: malformed > 0 ? ToolFailureError.fileRepairInstruction(SwiftNativePersistenceCore.activityEventsPath(dataRoot: root),
                                   shape: "Each JSONL line must hold an activity event with its original identity, timestamp, status and outcome payload. Preserve unknown outcomes and reconciliation evidence.") : nil)
        } catch {
            return CheckResult(source: "activity/events.jsonl",
                               id: id, title: title, status: "fail",
                               detail: "The activity log could not be read: \(safeDetail(error.localizedDescription)).",
                               harm: "Recent work and its outcomes cannot be reviewed.",
                               human_action: ToolFailureError.fileRepairInstruction(SwiftNativePersistenceCore.activityEventsPath(dataRoot: root),
                                   shape: "Each JSONL line must hold an activity event with its original identity, timestamp, status and outcome payload. Preserve unknown outcomes and reconciliation evidence.") + " Open Status and refresh Recent activity once; if the log is still unavailable, inspect activity/events.jsonl without replacing its bytes.")
        }
    }

}
