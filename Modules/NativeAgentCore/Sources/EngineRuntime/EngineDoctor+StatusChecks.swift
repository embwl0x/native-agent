import Foundation
import NativeAgentCore
import Desk
import DoctorChecks
import NativeAgentShared
import PersistenceCore
import DeviceSync

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
            var items = try await store.liveState().items
            let initialContradictions = contradictoryParents(in: items)
            var repaired = false
            if repair && !initialContradictions.isEmpty {
                let ops = try await store.reconcileTerminalParentsWithNonTerminalDescendants()
                repaired = !ops.isEmpty
                items = try await store.liveState().items
            }
            let contradictions = contradictoryParents(in: items)
            let waiting = items.filter { $0.requiresOwnerInput }
            let blocked = items.filter { $0.status == .blocked && !$0.requiresOwnerInput }
            let pendingApprovals: Int
            do {
                pendingApprovals = try await approvals.list()
                    .filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }.count
            } catch {
                return (CheckResult(source: "workflows/approvals/requests.json",
                                    nextCall: ToolFailureError.fileRepairCall(root.appendingPathComponent("workflows/approvals/requests.json"), dataRoot: root,
                                        shape: "A JSON array of saved approval requests with their original identities, payloads and decisions. Preserve all authority and decision fields exactly; never approve, deny or invent a request."),
                                    id: "status.desk_attention", title: "Desk work and decisions", status: "fail",
                                    detail: "Approvals could not be read: \(safeDetail(error.localizedDescription)).",
                                    harm: "Pending decisions cannot be read or safely settled.",
                                    human_action: "Open Approvals and refresh its pending list; inspect the approval store before changing any saved request."), repaired)
            }
            let id = "status.desk_attention"
            let title = "Desk work and decisions"
            guard pendingApprovals > 0 || !waiting.isEmpty || !blocked.isEmpty || !contradictions.isEmpty else {
                return (CheckResult(source: "desk/desk_ops_base.json and desk/desk_ops.jsonl", id: id, title: title, status: "ok",
                                    detail: "No blocked Desk work, owner decision, or terminal-parent contradiction."), repaired)
            }
            var parts: [String] = []
            if !waiting.isEmpty { parts.append("\(waiting.count) item(s) wait on your decision: " + labels(waiting)) }
            if pendingApprovals > 0 { parts.append("\(pendingApprovals) pending approval(s) wait for your decision.") }
            if !blocked.isEmpty { parts.append("\(blocked.count) blocked item(s): " + blockedDetails(blocked, in: items, stuckReason: stuckReason, safeDetail: safeDetail)) }
            if !contradictions.isEmpty { parts.append("\(contradictions.count) terminal parent(s) contain open descendants: " + labels(contradictions)) }
            var actions: [String] = []
            if !waiting.isEmpty { actions.append("Open Desk and decide items \(labels(waiting)) marked waiting on you.") }
            if pendingApprovals > 0 { actions.append("Open Approvals and decide the \(pendingApprovals) pending request(s).") }
            if !blocked.isEmpty { actions.append("Open Desk and resolve \(labels(blocked)) using each recorded blocked reason or waiting party; if neither is recorded, clarify the block in Desk.") }
            if !contradictions.isEmpty { actions.append("Open Desk and inspect terminal parents \(labels(contradictions)) if Repair Safe Issues cannot reconcile them.") }
            let severity = contradictions.isEmpty ? "ok" : "warn"
            return (CheckResult(source: "desk/desk_ops_base.json and desk/desk_ops.jsonl", id: id, title: title, status: severity, detail: parts.joined(separator: " "),
                                harm: severity == "warn" ? "The named Desk work cannot move forward or is marked finished while work remains." : nil,
                                repair: contradictions.isEmpty ? nil : "Run Repair Safe Issues to reconcile terminal Desk parents with open descendants.",
                                human_action: actions.joined(separator: " "), repair_available: !contradictions.isEmpty), repaired)
        } catch {
            let file: URL?
            switch error {
            case DeskError.compactionBaseCorrupt(let path), DeskError.compactionBaseUnreadable(let path): file = URL(fileURLWithPath: path)
            default:
                let path = (error as NSError).userInfo[NSFilePathErrorKey] as? String
                file = path.flatMap { $0 == store.opsPath.path || $0 == store.basePath.path ? URL(fileURLWithPath: $0) : nil }
            }
            return (CheckResult(source: file?.path ?? "desk/desk_ops_base.json and desk/desk_ops.jsonl",
                                nextCall: file.map { ToolFailureError.fileRepairCall($0, dataRoot: root,
                                    shape: "The Desk compaction base holds the saved items and lastCompactedOpId; its JSONL tail holds DeskOp events. Preserve identities, parent links, continuations and recorded outcomes.") },
                                id: "status.desk_attention", title: "Desk work and decisions", status: "fail",
                                detail: "Desk's canonical state could not be read: \(safeDetail(error.localizedDescription)).",
                                harm: "Saved work cannot be read or safely advanced.",
                                human_action: "Open Desk and inspect its unavailable-state detail; restore its canonical feed from a verified backup if the owner reports corruption."), false)
        }
    }

    private static func contradictoryParents(in items: [DeskItem]) -> [DeskItem] {
        let parents = Dictionary(items.map { ($0.handle, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var ancestorsOfOpenItems = Set<String>()
        for item in items where !item.status.isTerminal {
            var parent = item.parent
            var seen = Set<String>()
            while let handle = parent, seen.insert(handle).inserted {
                ancestorsOfOpenItems.insert(handle)
                parent = parents[handle] ?? nil
                if seen.count >= items.count { break }
            }
        }
        return items.filter { $0.status.isTerminal && ancestorsOfOpenItems.contains($0.handle) }
    }

    private static func labels(_ items: [DeskItem]) -> String {
        items.prefix(5).map { "#\($0.alias)" }.joined(separator: ", ")
            + (items.count > 5 ? " and \(items.count - 5) more" : "")
    }

    private static func blockedDetails(_ items: [DeskItem], in all: [DeskItem], stuckReason: (DeskItem, [DeskItem]) -> String, safeDetail: (String) -> String) -> String {
        items.prefix(5).map { "#\($0.alias): " + safeDetail(stuckReason($0, all)) }
            .joined(separator: "; ") + (items.count > 5 ? "; and \(items.count - 5) more" : "")
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
            let partial = malformed > 0
                ? "Activity log \(readout.records.isEmpty ? "unreadable" : "partially readable"): \(malformed) malformed row(s) in its bounded tail. "
                : ""
            let latestTitles = (reconciliation + current).sorted { $0.event.createdAt > $1.event.createdAt }.prefix(3)
                .map { safeDetail($0.event.title) }.joined(separator: "; ")
            return CheckResult(source: "activity/events.jsonl",
                               nextCall: malformed > 0 ? ToolFailureError.fileRepairCall(root.appendingPathComponent("activity/events.jsonl"), dataRoot: root,
                                   shape: "Each JSONL line must hold an activity event with its original identity, timestamp, status and outcome payload. Preserve unknown outcomes and reconciliation evidence.") : nil,
                               id: id, title: title, status: malformed > 0 ? "fail" : reconciliation.isEmpty && current.isEmpty ? "ok" : "unmeasured",
                               detail: partial + "\(reconciliation.count) outcome(s) need reconciliation; \(current.count) failure receipt(s) in the last 15 minutes of the retained activity tail."
                                   + (latestTitles.isEmpty ? "" : " Latest: \(latestTitles)."),
                               harm: malformed > 0 ? "Parts of the activity history cannot be reviewed." : nil)
        } catch {
            return CheckResult(source: "activity/events.jsonl",
                               nextCall: ToolFailureError.fileRepairCall(root.appendingPathComponent("activity/events.jsonl"), dataRoot: root,
                                   shape: "Each JSONL line must hold an activity event with its original identity, timestamp, status and outcome payload. Preserve unknown outcomes and reconciliation evidence."),
                               id: id, title: title, status: "fail",
                               detail: "The activity log could not be read: \(safeDetail(error.localizedDescription)).",
                               harm: "Recent work and its outcomes cannot be reviewed.",
                               human_action: "Open Status and refresh Recent activity once; if the log is still unavailable, inspect activity/events.jsonl without replacing its bytes.")
        }
    }

}
