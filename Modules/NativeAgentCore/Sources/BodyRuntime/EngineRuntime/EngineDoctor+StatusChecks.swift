import Foundation
import NativeAgentCore
import DeskCore
import NativeAgentShared
import PersistenceCore
import SenseCore
// Blueprint: | `EngineDoctor+StatusChecks.swift` | `DoctorFacade`; Native Desk and Activity evidence with authored narration |

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
        await DoctorReadout.recordReadings(rows, dataRoot: root, settledWarning: desk.settledWarning)
        return (rows, desk.repaired)
    }

    private static func deskCheck(approvals: ApprovalsFacade, root: URL, repair: Bool, stuckReason: (DeskItem, [DeskItem]) -> String, safeDetail: (
        String) -> String) async -> (row: CheckResult, repaired: Bool, settledWarning: String?) {
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
            let items = state.board.items
            let contradictions = SwiftNativeDeskStore.terminalParentsWithNonTerminalDescendants(in: state)
            let waiting = state.items.filter { $0.requiresOwnerInput }
            // An item deferred to a later time waits on the clock, not on the person: it is not blocked work for them.
            let now = Date()
            let blocked = items.filter { DeskSequencing.isActionableBlocked($0, now: now) }
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
                                        shape: """
                                            A JSON array of saved approval requests with their original identities, payloads and decisions. Preserve all \
                                            authority and decision fields exactly; never approve, deny or invent a request.
                                            """)
                                                + """
                                                     Open Approvals and refresh its pending list; inspect the approval store before changing any saved \
                                                    request.
                                                    """), repaired, nil)
            }
            let id = "status.desk_attention"
            let title = "Desk work and decisions"
            func group(_ items: [DeskItem]) -> [String: JSONValue] {
                ["count": .int(Int64(items.count)), "aliases": .array(items.map { .string(String($0.alias)) })]
            }
            var blockedFacts = group(blocked)
            blockedFacts["items"] = .array(blocked.map {
                .object(["alias": .string(String($0.alias)), "reason": .string(safeDetail(stuckReason($0, state.items)))])
            })
            let narration = await diagnosticNarration(root: root, input: .object([
                "kind": .string("desk"), "pendingApprovals": .int(Int64(pendingApprovals)),
                "waiting": .object(group(waiting)), "blocked": .object(blockedFacts), "contradictions": .object(group(contradictions))
            ]), safeDetail: safeDetail)
            let severity = contradictions.isEmpty && blocked.isEmpty ? "ok" : "warn"
            let needsPerson = !waiting.isEmpty || pendingApprovals > 0 || !contradictions.isEmpty
            return (CheckResult(source: "desk/desk_ops_base.json and desk/desk_ops.jsonl", id: id, title: title, status: severity, detail: narration.detail,
                                harm: severity == "warn" ? "The named Desk work cannot move forward or is marked finished while work remains." : nil,
                                repair: contradictions.isEmpty ? nil
                                    : "Press Repair in Diagnostics → Health checks to reconcile terminal Desk parents with open descendants.",
                                human_action: needsPerson ? narration.humanAction : nil,
                                repair_available: pendingApprovals > 0 || !waiting.isEmpty || !blocked.isEmpty || !contradictions.isEmpty
                                    ? !contradictions.isEmpty : nil), repaired, severity == "warn" && !needsPerson ? id : nil)
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
                                    shape: """
                                        The Desk compaction base holds the saved items and lastCompactedOpId; its JSONL tail holds DeskOp events. Preserve \
                                        identities, parent links, continuations and recorded outcomes.
                                        """) }, file == nil
                                    ? """
                                        Open Trust → Advanced → Backups, select a verified backup containing desk/desk_ops_base.json and \
                                        desk/desk_ops.jsonl, then choose Restore → Restore backup.
                                        """
                                    : "Open Desk and inspect its unavailable-state detail before recovering the named canonical feed."].compactMap { $0 }
                                        .joined(separator: " "),
                                ask: file == nil ? .permission : nil), false, nil)
        }
    }

    private static func diagnosticNarration(root: URL, input: JSONValue, safeDetail: (String) -> String) async -> DiagnosticNarration {
        do {
            return try await NativeAgentEngine.forRoot(root).withPartDoor(envelope: .native("doctor:status-narration")) { door in
                switch await Parts(root: root).call(id: "native-diagnostics", input: input, invocation: door.invocation, as: DiagnosticNarration.self) {
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
        var source = "activity/events.jsonl"
        do {
            let readout = try await RuntimeReadouts.getActivityReadout(root: root)
            source = "experiences/experiences.sqlite"
            let now = Date()
            let failedTurns = try await TurnTracePersistLane(dataRootOverride: root).events(
                .init(kinds: ["turn.failed"], from: now.addingTimeInterval(-ExperienceStore.detailHorizon), through: now))
            // A failed turn is a fault while its experience still owes something; once settled it is history, stated as a fact.
            let failedIDs = Set(failedTurns.events.map(\.turnId))
            var owing: [Experience] = []
            if !failedIDs.isEmpty {
                owing = try await ExperienceStore.at(root).projection().filter { $0.isOpen && failedIDs.contains($0.id) }
            }
            let newestFailure = failedTurns.events.map(\.ts).max()
            let cutoff = Date().addingTimeInterval(-15 * 60)
            // A later receipt or an age cutoff cannot reconcile an unknown effect.
            let reconciliation = readout.records.filter(\.needsReconciliation)
            let current = readout.records.filter { record in
                guard !record.needsReconciliation,
                      ["fail", "failed", "error"].contains(record.event.status.lowercased()),
                      let date = NativeTimestampFormat.parseISO8601FractionalFirst(record.event.createdAt) else { return false }
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
            let turnDetail = " \(failedIDs.count) failed turn(s) in the retained detail horizon"
                + (newestFailure.map { ", newest at \(NativeTimestampFormat.plainZulu($0))" } ?? "") + "; \(owing.count) still owe(s) something; "
                + "\(failedTurns.unreadable) unreadable trace row(s)."
            let failed = malformed > 0 || failedTurns.unreadable > 0 || !owing.isEmpty
            return CheckResult(source: "activity/events.jsonl and experiences/experiences.sqlite",
                               id: id, title: title, status: failed ? "fail" : reconciliation.isEmpty ? "ok" : "unmeasured",
                               detail: narration.detail + turnDetail,
                               harm: malformed > 0 ? "Parts of the activity history cannot be reviewed."
                                   : owing.isEmpty ? nil : "A failed turn still owes what it was asked for.",
                               human_action: !owing.isEmpty && malformed == 0
                                   ? "Open each failed turn's conversation and ask again or stop it; the row clears when nothing it owes is open."
                                   : malformed > 0 ? ToolFailureError.fileRepairInstruction(SwiftNativePersistenceCore.activityEventsPath(
                                   dataRoot: root),
                                   shape: """
                                       Each JSONL line must hold an activity event with its original identity, timestamp, status and outcome payload. \
                                       Preserve unknown outcomes and reconciliation evidence.
                                       """) : nil)
        } catch {
            return CheckResult(source: source,
                               id: id, title: title, status: "fail",
                               detail: "\(source) could not be read: \(safeDetail(error.localizedDescription)).",
                               harm: "Recent work and its outcomes cannot be reviewed.",
                               human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent(source),
                                   shape: source == "experiences/experiences.sqlite"
                                   ? "Preserve original experiences, trace details, evidence and obligation phases in the SQLite experience store."
                                   : """
                                       Each JSONL line must hold an activity event with its original identity, timestamp, status and outcome payload. \
                                       Preserve unknown outcomes and reconciliation evidence.
                                       """) + """
                                        Open Status and refresh Recent activity once; if the record is still unavailable, inspect \(source) without \
                                       replacing its bytes.
                                       """)
        }
    }

}
