import AgentConversations
import Foundation
import ApprovalInbox
import Desk
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import Privacy
// Blueprint: | `WorkOverviewRead.swift` | `WorkOverviewRead`, `project`, `row`, `text`; owner attention and the agent's jobs at work |

/// Collapse rows only with explicit approval links; a shared Desk parent cannot prove two asks are the same. A job is a row of the work it does.
public enum WorkOverviewRead {
    /// Bound overview copies because phone snapshot groups carry them; open details through canonical records.
    static let needsYouLimit = 12

    /// Apply OwnerAttentionPolicy once here for every overview.
    static func project(board: DeskBoardRead, approvals: [ApprovalRecord], inbox: [InboxItemRecord],
                        experiences: [Experience] = [], unavailable: [String], now: Date) -> WorkOverview {
        let pending = approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
        let pendingByID = Dictionary(grouping: pending, by: \.id)
        typealias Candidate = (reference: WorkOverviewReference, updatedAt: String, render: () -> WorkOverviewRow)
        var needs: [Candidate] = pending.map { approval in
            (.init(kind: .approval, id: approval.id), approval.lastRequestedAt ?? approval.createdAt, {
                // Redact retained asks before phone publication.
                row(.approval, approval.id, approval.title,
                    TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(approval.readableAsk)), "Decision needed",
                    approval.lastRequestedAt ?? approval.createdAt, detail: 1_000)
            })
        }
        for job in board.agentJobs.items where job.state == .needsYou {
            needs.append((.init(kind: .execution, id: job.id), NativeTimestampFormat.fractionalZulu(job.updatedAt), { Self.row(for: job, now: now) }))
        }
        var needsDeskIDs: Set<String> = []
        for item in board.items where item.requiresOwnerInput {
            needsDeskIDs.insert(item.handle)
            // Context links do not prove ask identity; collapse only when exact link and request agree.
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
            // Approval owns settlement; a nonpending approval’s inbox face must not become a new ask.
            if item.id == item.related_approval_id { continue }
            // Contextual links do not establish that a note is the same ask.
            needs.append((.init(kind: .inbox, id: item.id), item.created_at, {
                row(.inbox, item.id, item.title, item.detail ?? item.summary, "Needs you", item.created_at, detail: 1_000)
            }))
        }

        var current: [Candidate] = [], recent: [Candidate] = []
        // A Desk item a working job carries reads as that job.
        let carriedDeskIDs = Set(board.agentJobs.items.filter { !$0.state.isTerminal }.compactMap(\.desk))
        for job in board.agentJobs.items where job.state != .needsYou {
            let result: Candidate = (.init(kind: .execution, id: job.id), NativeTimestampFormat.fractionalZulu(job.updatedAt), {
                Self.row(for: job, now: now)
            })
            if job.state.isTerminal { recent.append(result) } else { current.append(result) }
        }
        for item in board.items {
            guard !carriedDeskIDs.contains(item.handle), !needsDeskIDs.contains(item.handle) else { continue }
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

    /// Overview and id-based detail read the same job record.
    public static func row(for job: AgentJob, now: Date) -> WorkOverviewRow {
        let updated = NativeTimestampFormat.fractionalZulu(job.updatedAt)
        let state = switch job.state {
        case .working: "running"
        case .needsYou: "Decision needed"
        default: job.state.rawValue.capitalized + (job.check.map { " · check: \($0.verdict.rawValue)" } ?? " · no check set")
        }
        let first = job.brief.split(whereSeparator: \.isNewline).first.map(String.init) ?? job.brief
        return row(.execution, job.id, (job.isOwn ? "Your line: " : job.name + ": ") + first, text(for: job), state, updated,
            location: job.desk.map { "Desk: " + $0 }, movement: job.state == .working ? updated : nil)
    }

    public static func row(for item: DeskItem, now: Date) -> WorkOverviewRow {
        if item.requiresOwnerInput {
            return row(.desk, item.handle, item.title, item.blockedReason ?? item.summary ?? "",
                       "Needs you", item.updatedAt, location: item.project, detail: 1_000)
        }
        let state = DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
            deferred: DeskSequencing.isDeferred(item, now: now), updatedAt: item.updatedAt, evidence: nil, now: now)
        return row(.desk, item.handle, item.title,
            item.summary ?? item.notes.last?.text ?? "No summary was recorded.",
            state.label, item.closedAt ?? item.updatedAt, location: item.project)
    }

    /// The brief and its latest working line until the job ends, then its answer, its check and how it ended.
    public static func text(for job: AgentJob) -> String {
        guard job.state.isTerminal else { return job.note.map { job.brief + "\n\nNow: " + $0 } ?? job.brief }
        var text = job.report?.text ?? "No answer was recorded."
        if let check = job.check { text += "\n\nCheck: " + check.output }
        if let detail = job.detail { text += "\n\n" + detail }
        return text
    }
}
