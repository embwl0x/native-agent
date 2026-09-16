import Foundation
import ApprovalInbox

/// THE shelf-reading boundary for approval state. Every reader of a shelf entry
/// — the Mac page, `shelf_read`, `shelf_entry` — goes through this, so an
/// approval resolved from Telegram or the iPhone settles the entry for all of
/// them instead of only for whoever loaded the Bots page last.
extension ShelfStore {
    /// The approvals that are STILL PENDING, by id. The approval record is the
    /// canonical word on its own resolution; the shelf entry was written when
    /// the run stopped and is never revisited by the resolution path. Pending
    /// is the set to carry, not settled: the inbox evicts terminal rows at its
    /// 300-row cap and on archive, so an id that is simply gone is decided too.
    /// nil means the inbox could not be read — then nothing is reconciled.
    public nonisolated static func pendingApprovalIDs(dataRoot: URL) -> Set<String>? {
        let path = dataRoot.appendingPathComponent("workflows/approvals/requests.json")
        guard let rows = try? SwiftNativeApprovalInbox.loadApprovalRowsChecked(at: path) else { return nil }
        return Set(rows.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"],
                  case .string(let status)? = object["status"],
                  status.lowercased() == "pending" else { return nil }
            return id
        })
    }

    /// A run that stopped on an approval which has since been decided is not
    /// waiting on anyone any more: the shelf said "Waiting for approval" and
    /// "Continue in Chat" kept reopening Approvals until some later run replaced
    /// the entry. The run itself still never finished, so it settles as
    /// interrupted. Entries with no recorded approval are untouched.
    public nonisolated static func reconciled(_ entry: ShelfEntry, pending: Set<String>?) -> ShelfEntry {
        guard let pending, entry.runtimeStatus == .waitingForApproval,
              let approvalID = entry.approvalID, !pending.contains(approvalID) else { return entry }
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
    /// pending last. Settling it on the entry means the next read needs no inbox
    /// row at all; a write failure only costs this reconciliation.
    public func reconciling(_ entries: [ShelfEntry]) -> [ShelfEntry] {
        let pending = Self.pendingApprovalIDs(dataRoot: dataRoot)
        return entries.map { stored in
            let entry = Self.reconciled(stored, pending: pending)
            if entry != stored { try? settleApproval(stored.id, detail: entry.statusDetail ?? "") }
            return entry
        }
    }
}
