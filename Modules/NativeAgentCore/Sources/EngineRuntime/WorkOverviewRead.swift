import Foundation
import ApprovalInbox
import Desk
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import Privacy
import WorkshopExecution
// Blueprint: | `WorkOverviewRead.swift` | `WorkOverviewRead` enum; `project`, execution/Desk-item `row`, `text`, `requiresApproval`; overview and phone task rows share the execution approval predicate; ID-based details use the same status projection; complete owner-attention counts by reference kind before mobile list bounds |

/// One surface-neutral projection over the canonical owners. Only explicit
/// approval/execution links collapse rows; a shared Desk parent is not proof
/// that two questions are the same question.
public enum WorkOverviewRead {
    public static func requiresApproval(status: String) -> Bool { status == "blocked_on_approval" }
    /// Needs-you rows open their canonical record, so their copies stay short
    /// and few: the overview rides in a phone snapshot group.
    static let needsYouLimit = 12

    /// Needs you is `OwnerAttentionPolicy`, applied once here.
    static func project(board: DeskBoardRead, approvals: [ApprovalRecord], inbox: [InboxItemRecord],
                        experiences: [Experience] = [], unavailable: [String], now: Date) -> WorkOverview {
        let pending = approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
        let pendingByID = Dictionary(grouping: pending, by: \.id)
        var executionSteps: [String: Set<String>] = [:]
        for approval in pending {
            guard ExecutionEventVocabulary.matches(approval.action, WorkshopStepApprovalAction.canonical),
                  case .object(let payload) = approval.payload,
                  case .string(let stepID)? = payload["step_id"], !stepID.isEmpty,
                  let executionID = WorkshopStepApprovalPayload.executionId({ key in
                      if case .string(let value)? = payload[key] { return value }
                      return nil
                  }) else { continue }
            executionSteps[executionID, default: []].insert(stepID)
        }
        typealias Candidate = (reference: WorkOverviewReference, updatedAt: String, render: () -> WorkOverviewRow)
        var needs: [Candidate] = pending.map { approval in
            (.init(kind: .approval, id: approval.id), approval.lastRequestedAt ?? approval.createdAt, {
                // Redact retained asks before phone publication.
                row(.approval, approval.id, approval.title,
                    TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(approval.readableAsk)), "Decision needed",
                    approval.lastRequestedAt ?? approval.createdAt, detail: 1_000)
            })
        }
        let linkedExecutionIDs = Set(board.executions.items.filter {
            requiresApproval(status: $0.status) && executionSteps[$0.id]?.contains($0.currentStepId) == true
        }.map(\.id))
        for execution in board.executions.items where requiresApproval(status: execution.status) && !linkedExecutionIDs.contains(execution.id) {
            needs.append((.init(kind: .execution, id: execution.id), execution.updatedAt, {
                row(.execution, execution.id, execution.title, execution.objective, "Decision needed", execution.updatedAt, detail: 1_000)
            }))
        }
        var needsDeskIDs: Set<String> = []
        for item in board.items where item.requiresOwnerInput {
            needsDeskIDs.insert(item.handle)
            // A reference can also be background context for another ask.
            // Collapse a wrapper only when its exact link AND request agree.
            let request = (item.blockedReason ?? item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let approvalIDs = Set(item.refs.compactMap { ref -> String? in
                if case .approval(let id, _) = ref.kind { return id }; return nil
            })
            let mirrorsApproval = !request.isEmpty && approvalIDs.contains { id in
                (pendingByID[id] ?? []).contains { request == $0.reason.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if mirrorsApproval { continue }
            needs.append((.init(kind: .desk, id: item.handle), item.updatedAt, { Self.row(for: item, now: now) }))
        }
        for item in inbox where item.requiresOwnerInput {
            // The approval owns both its wait and its settlement. Its old
            // inbox face must not become a new ask once it leaves pending.
            if item.id == item.related_approval_id { continue }
            // Contextual links do not establish that a note is the same ask.
            needs.append((.init(kind: .inbox, id: item.id), item.created_at, {
                row(.inbox, item.id, item.title, item.detail ?? item.summary, "Needs you", item.created_at, detail: 1_000)
            }))
        }

        var current: [Candidate] = [], recent: [Candidate] = []
        let terminalDeskIDs = Set(board.items.filter { $0.status.isTerminal }.map(\.handle))
        let executionDeskIDs = Set(board.executions.items.filter {
            !$0.isTerminal
                || ($0.result != .null && $0.deskHandle.map(terminalDeskIDs.contains) == true)
        }.compactMap(\.deskHandle))
        for execution in board.executions.items {
            if requiresApproval(status: execution.status) { continue }
            let result: Candidate = (.init(kind: .execution, id: execution.id), execution.updatedAt, { Self.row(for: execution, now: now) })
            if execution.isTerminal { recent.append(result) } else { current.append(result) }
        }
        for item in board.items {
            guard !executionDeskIDs.contains(item.handle), !needsDeskIDs.contains(item.handle) else { continue }
            let result: Candidate = (.init(kind: .desk, id: item.handle), item.closedAt ?? item.updatedAt, { Self.row(for: item, now: now) })
            if item.status.isTerminal { recent.append(result) } else { current.append(result) }
        }
        func selected(_ rows: [Candidate], limit: Int) -> [WorkOverviewRow] {
            rows.sorted { $0.updatedAt == $1.updatedAt
                ? "\($0.reference.kind.rawValue):\($0.reference.id)" < "\($1.reference.kind.rawValue):\($1.reference.id)"
                : $0.updatedAt > $1.updatedAt }.prefix(limit).map { $0.render() }
        }
        var overview = WorkOverview(capturedAt: NativeTimestampFormat.fractionalZulu(now),
                     now: selected(current, limit: 24), needsYou: selected(needs, limit: needsYouLimit),
                     recentlyDone: selected(recent, limit: 12), unavailable: unavailable,
                     omittedNow: max(0, current.count - 24), omittedNeedsYou: max(0, needs.count - needsYouLimit),
                     omittedRecentlyDone: max(0, recent.count - 12))
        overview.experiences = experiences.map(\.mobile)
        overview.needsYouCounts = Dictionary(grouping: needs, by: \.reference.kind).mapValues(\.count)
        return overview
    }

    private static func row(_ kind: WorkOverviewReference.Kind, _ id: String, _ title: String,
             _ text: String, _ state: String, _ updated: String,
             location: String? = nil, movement: String? = nil, detail: Int = 4_000) -> WorkOverviewRow {
        .init(reference: .init(kind: kind, id: id), title: MobileDeskProjectionBounds.clipped(title, to: 240),
              summary: MobileDeskProjectionBounds.clipped(text, to: 360), detail: MobileDeskProjectionBounds.clipped(text, to: detail), state: state,
              updatedAt: updated, location: location, movementAt: movement)
    }

    /// The overview and ID-based details describe the same execution revision.
    public static func row(for execution: WorkshopExecutionRecord, now: Date) -> WorkOverviewRow {
        let terminal = execution.isTerminal
        let text = Self.text(for: execution)
        var state = execution.status == "running" ? "running"
            : DeskActivityState.execution(.init(deskHandle: execution.deskHandle,
                status: execution.status, updatedAt: execution.updatedAt,
                lastMovementAt: execution.lastMovementAt), now: now).label
        if execution.status == "blocked_on_approval" { state = "Decision needed" }
        else if ["corrupt", "unavailable"].contains(execution.status) {
            state = execution.status.capitalized
        } else if terminal {
            state = execution.status.capitalized
            state += execution.verification.map { " · verification: \($0.status.rawValue)" }
                ?? " · no verification record"
        }
        return row(.execution, execution.id, execution.title, text, state, execution.updatedAt,
            location: execution.receiptsDir.isEmpty ? nil : "Receipts: \(execution.receiptsDir)",
            movement: execution.lastMovementAt)
    }

    public static func row(for item: DeskItem, now: Date) -> WorkOverviewRow {
        if item.requiresOwnerInput {
            return row(.desk, item.handle, item.title, item.blockedReason ?? item.summary ?? "",
                       "Needs you", item.updatedAt, location: item.project, detail: 1_000)
        }
        let state = DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
            deferred: item.deferUntil != nil, updatedAt: item.updatedAt, evidence: nil, now: now)
        return row(.desk, item.handle, item.title,
            item.summary ?? item.notes.last?.text ?? "No summary was recorded.",
            state.label, item.closedAt ?? item.updatedAt, location: item.project)
    }

    /// Progress and the next step while an execution runs, its full result and
    /// verification once it ends, or a bounded storage error when unreadable.
    public static func text(for execution: WorkshopExecutionRecord) -> String {
        if ["corrupt", "unavailable"].contains(execution.status),
           case .object(let result) = execution.result,
           case .string(let error)? = result["error"] {
            return MobileDeskProjectionBounds.clipped(error, to: 4_000)
        }
        guard execution.isTerminal else {
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
