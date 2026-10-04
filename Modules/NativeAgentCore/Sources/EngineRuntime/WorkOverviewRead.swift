import Foundation
import ApprovalInbox
import Desk
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import WorkshopExecution

/// One surface-neutral projection over the canonical owners. Only explicit
/// approval/execution links collapse rows; a shared Desk parent is not proof
/// that two questions are the same question.
public enum WorkOverviewRead {
    /// Needs-you rows open their canonical record, so their copies stay short
    /// and few: the overview rides in a phone snapshot group.
    static let needsYouLimit = 12

    /// Needs you is `OwnerAttentionPolicy`, applied once here.
    static func project(board: DeskBoardRead, approvals: [ApprovalRecord], inbox: [InboxItemRecord],
                        unavailable: [String], now: Date) -> WorkOverview {
        let executions = board.executions.items.sorted { $0.updatedAt > $1.updatedAt }
        let pending = approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status) }
        func approvalIDs(_ item: DeskItem) -> Set<String> {
            Set(item.refs.compactMap { ref in
                if case .approval(let id, _) = ref.kind { return id }
                return nil
            })
        }
        func executionApprovalIDs(_ execution: WorkshopExecutionRecord) -> Set<String> {
            guard !execution.currentStepId.isEmpty else { return [] }
            return Set(pending.filter { approval in
                guard ExecutionEventVocabulary.matches(approval.action, WorkshopStepApprovalAction.canonical),
                      case .object(let payload) = approval.payload,
                      payload["step_id"] == .string(execution.currentStepId) else { return false }
                return WorkshopStepApprovalPayload.executionId { key in
                    if case .string(let value)? = payload[key] { return value }
                    return nil
                } == execution.id
            }.map(\.id))
        }
        func bounded(_ text: String, _ limit: Int = 4_000) -> String {
            MobileDeskProjectionBounds.clipped(text, to: limit)
        }
        func row(_ kind: WorkOverviewReference.Kind, _ id: String, _ title: String,
                 _ text: String, _ state: String, _ updated: String,
                 location: String? = nil, movement: String? = nil, detail: Int = 4_000) -> WorkOverviewRow {
            .init(reference: .init(kind: kind, id: id), title: bounded(title, 240),
                  summary: bounded(text, 360), detail: bounded(text, detail), state: state,
                  updatedAt: updated, location: location, movementAt: movement)
        }
        var needs = pending.map {
            row(.approval, $0.id, $0.title, $0.reason, "Decision needed",
                $0.lastRequestedAt ?? $0.createdAt, detail: 1_000)
        }
        let approvalExecutions = executions.filter { $0.status == "blocked_on_approval" }
        let linkedExecutionIDs = Set(approvalExecutions.filter { !executionApprovalIDs($0).isEmpty }.map(\.id))
        for execution in approvalExecutions where !linkedExecutionIDs.contains(execution.id) {
            needs.append(row(.execution, execution.id, execution.title, execution.objective,
                             "Decision needed", execution.updatedAt, detail: 1_000))
        }
        var mirroredDeskIDs: Set<String> = []
        for item in board.items where item.requiresOwnerInput {
            // A reference can also be background context for another ask.
            // Collapse a wrapper only when its exact link AND request agree.
            let request = (item.blockedReason ?? item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let mirrorsApproval = pending.contains {
                approvalIDs(item).contains($0.id) && !request.isEmpty
                    && request == $0.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if mirrorsApproval { mirroredDeskIDs.insert(item.handle); continue }
            needs.append(row(.desk, item.handle, item.title, item.blockedReason ?? item.summary ?? "",
                             "Needs you", item.updatedAt, location: item.project, detail: 1_000))
        }
        for item in inbox where OwnerAttentionPolicy.inboxAsks(pending: item.isActivityPending, systemLane: item.isSystemLane,
                severity: item.severity, linkedApproval: !(item.related_approval_id ?? "").isEmpty, actionIDs: item.actions.map(\.id)) {
            let actions = Set(item.actions.map(\.id))
            let mirrorsApproval = pending.contains {
                item.related_approval_id == $0.id && item.id == $0.id
                    && actions.contains("approve") && !actions.isDisjoint(with: ["reject", "deny"])
                    && actions.isSubset(of: ["approve", "reject", "deny", "view", "read", "dismiss"])
            }
            if mirrorsApproval { continue }
            // Contextual links do not establish that a note is the same ask.
            needs.append(row(.inbox, item.id, item.title, item.detail ?? item.summary,
                             "Needs you", item.created_at, detail: 1_000))
        }

        var current: [WorkOverviewRow] = []
        var recent: [WorkOverviewRow] = []
        let needsDeskIDs = Set(needs.filter { $0.reference.kind == .desk }.map { $0.reference.id })
        let terminalDeskIDs = Set(board.items.filter { $0.status.isTerminal }.map(\.handle))
        let executionDeskIDs = Set(executions.filter {
            !["completed", "failed", "cancelled"].contains($0.status)
                || ($0.result != .null && $0.deskHandle.map(terminalDeskIDs.contains) == true)
        }.compactMap(\.deskHandle))
        for execution in executions {
            if execution.status == "blocked_on_approval" { continue }
            let terminal = ["completed", "failed", "cancelled"].contains(execution.status)
            let text = Self.text(for: execution)
            var state = execution.status == "running" ? "running"
                : DeskActivityState.execution(.init(deskHandle: execution.deskHandle,
                    status: execution.status, updatedAt: execution.updatedAt,
                    lastMovementAt: execution.lastMovementAt), now: now).label
            if ["corrupt", "unavailable"].contains(execution.status) {
                state = execution.status.capitalized
            } else if terminal {
                state = execution.status.capitalized
                state += execution.verification.map { " · verification: \($0.status.rawValue)" }
                    ?? " · no verification record"
            }
            let result = row(.execution, execution.id, execution.title, text, state,
                             execution.updatedAt, location: execution.receiptsDir.isEmpty ? nil : "Receipts: \(execution.receiptsDir)",
                             movement: execution.lastMovementAt)
            if terminal { recent.append(result) } else { current.append(result) }
        }
        for item in board.items {
            guard !executionDeskIDs.contains(item.handle), !needsDeskIDs.contains(item.handle),
                  !mirroredDeskIDs.contains(item.handle) else { continue }
            let state = DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
                deferred: item.deferUntil != nil, updatedAt: item.updatedAt, evidence: nil, now: now)
            let result = row(.desk, item.handle, item.title,
                item.summary ?? item.notes.last?.text ?? "No summary was recorded.",
                state.label, item.closedAt ?? item.updatedAt, location: item.project)
            if item.status.isTerminal { recent.append(result) } else { current.append(result) }
        }
        func sorted(_ rows: [WorkOverviewRow]) -> [WorkOverviewRow] {
            rows.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        }
        let captureFormatter = ISO8601DateFormatter()
        captureFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .init(capturedAt: captureFormatter.string(from: now),
                     now: Array(sorted(current).prefix(24)), needsYou: Array(sorted(needs).prefix(needsYouLimit)),
                     recentlyDone: Array(sorted(recent).prefix(12)), unavailable: unavailable,
                     omittedNow: max(0, current.count - 24), omittedNeedsYou: max(0, needs.count - needsYouLimit),
                     omittedRecentlyDone: max(0, recent.count - 12))
    }

    /// Progress and the next step while an execution runs, its full result and
    /// verification once it ends, or a bounded storage error when unreadable.
    public static func text(for execution: WorkshopExecutionRecord) -> String {
        if ["corrupt", "unavailable"].contains(execution.status),
           case .object(let result) = execution.result,
           case .string(let error)? = result["error"] {
            return MobileDeskProjectionBounds.clipped(error, to: 4_000)
        }
        guard ["completed", "failed", "cancelled"].contains(execution.status) else {
            var text = execution.objective
            if !execution.plan.isEmpty {
                let completed = min(execution.stepsCompleted.count, execution.plan.count)
                text = "\(completed) of \(execution.plan.count) steps done.\n\n" + text
                if completed < execution.plan.count {
                    text += "\n\nNext: \(execution.plan[completed].description)"
                }
            }
            return text
        }
        var text: String
        switch execution.result {
        case .null: text = "No result was recorded."
        case .string(let value): text = value.isEmpty ? "No result was recorded." : value
        default:
            do { text = try execution.result.serialize(pretty: true) }
            catch { text = "Result unavailable: \(error.localizedDescription)" }
        }
        if let verification = execution.verification, !verification.detail.isEmpty {
            text += "\n\nVerification: \(verification.detail)"
        }
        return text
    }
}
