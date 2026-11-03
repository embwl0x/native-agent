import Foundation
import ApprovalInbox

// Blueprint: | `ShelfApprovalReconciliation.swift` | `ShelfStore` approval reconciliation: all shelf readers project canonical approval resolution without making shelf copies authoritative |

/// THE shelf-reading boundary for approval state. Every reader of a shelf entry
/// — the Mac page, `shelf_read`, `shelf_entry` — goes through this, so an
/// approval resolved from Telegram or the iPhone settles the entry for all of
/// them instead of only for whoever loaded the Bots page last.
extension ShelfStore {
    /// The canonical approval states, acquired after the shelf rows.
    /// A missing approval is unavailable evidence, never a decision.
    /// An unreadable inbox propagates its cause to the checked shelf reader.
    public nonisolated static func approvalStates(dataRoot: URL) throws -> [String: String] {
        let rows = try SwiftNativeApprovalInbox(root: dataRoot).recordsUnlocked()
        return Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    /// A run that stopped on an approval which has since been decided is not
    /// waiting on anyone any more: the shelf said "Waiting for approval" and
    /// "Continue in Chat" kept reopening Approvals until some later run replaced
    /// the entry. The run itself still never finished, so it settles as
    /// interrupted. A waiting entry without approval identity is unavailable.
    public nonisolated static func reconciled(_ entry: ShelfEntry, approvals: [String: String]) throws -> ShelfEntry {
        guard entry.runtimeStatus == .waitingForApproval else { return entry }
        guard let approvalID = entry.approvalID else {
            throw StandingBotsError.corruptStore("Helper result \(entry.id) is waiting for an approval whose identity is missing. Restore its approval evidence before settling the result.")
        }
        guard let status = approvals[approvalID] else {
            throw StandingBotsError.corruptStore("Approval \(approvalID) for helper result \(entry.id) is unavailable. Restore its decision evidence before settling the result.")
        }
        if status == "pending" { return entry }
        guard ["resolved", "denied", "canceled", "orphaned"].contains(status) else {
            throw StandingBotsError.corruptStore("Approval \(approvalID) has unsupported state \(status); repair the approval record before settling the helper result.")
        }
        var entry = entry
        entry.status = .interrupted
        entry.statusDetail = "That approval has been decided."
        return entry
    }

    /// ORDER IS THE CORRECTNESS RULE: the pending set is read AFTER the entries,
    /// never before. A bot that creates an approval and appends its Waiting entry
    /// between the two reads would otherwise have its brand-new entry classified
    /// decided — and durably rewritten to interrupted — because the approval did
    /// not exist in a snapshot taken first. Pass entries already read; this reads
    /// approval states last. Settling it on the entry means the next read needs no inbox
    /// row at all. Failed persistence remains a failed read, with its cause.
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
