import Foundation
import ApprovalInbox

// Blueprint: | `ShelfApprovalReconciliation.swift` | `ShelfStore`: all readers project canonical approval decisions after shelf evidence |

/// All shelf readers share approval reconciliation so a decision from any surface settles the same entry.
extension ShelfStore {
    /// Read canonical approvals after shelf rows; missing evidence is not a decision and unreadable evidence throws.
    public nonisolated static func approvalStates(dataRoot: URL) throws -> [String: String] {
        let rows = try SwiftNativeApprovalInbox(root: dataRoot).recordsUnlocked()
        return Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    /// A decided approval ends waiting without completing the run; missing approval identity remains unavailable.
    public nonisolated static func reconciled(_ entry: ShelfEntry, approvals: [String: String]) throws -> ShelfEntry {
        guard entry.runtimeStatus == .waitingForApproval else { return entry }
        guard let approvalID = entry.approvalID else {
            throw StandingBotsError.corruptStore("""
                Helper result \(entry.id) is waiting for an approval whose identity is missing. Restore its approval evidence before \
                settling the result.
                """)
        }
        guard let status = approvals[approvalID] else {
            throw StandingBotsError.corruptStore("""
                Approval \(approvalID) for helper result \(entry.id) is unavailable. Restore its decision evidence before settling the \
                result.
                """)
        }
        if status == "pending" { return entry }
        guard ["resolved", "denied", "canceled", "orphaned"].contains(status) else {
            throw StandingBotsError.corruptStore("""
                Approval \(approvalID) has unsupported state \(status); repair the approval record before settling the helper result.
                """)
        }
        var entry = entry
        entry.status = .interrupted
        entry.statusDetail = "That approval has been decided."
        return entry
    }

    /// Read approval state after entries: a newly appended wait must not be judged against an older inbox snapshot.
    /// Persist positive decisions so they outlive inbox retention; failed persistence remains a failed read.
    func reconciling(_ entries: [ShelfEntry], persist: Bool = true) throws -> [ShelfEntry] {
        guard entries.contains(where: { $0.runtimeStatus == .waitingForApproval }) else { return entries }
        return try reconciling(entries, approvals: Self.approvalStates(dataRoot: dataRoot), persist: persist)
    }

    private func reconciling(_ entries: [ShelfEntry], approvals: [String: String], persist: Bool) throws -> [ShelfEntry] {
        return try entries.map { stored in
            let entry = try Self.reconciled(stored, approvals: approvals)
            if persist, entry != stored { try settleApproval(stored.id, detail: entry.statusDetail ?? "") }
            return entry
        }
    }
}
