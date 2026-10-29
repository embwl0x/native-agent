import AuthoredCapabilities
import ChatToolParsing
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Surface identity is security-relevant and `ConversationSurfaceProfile` owns
// the remote/iOS sets. A second copy of them here would be a second answer to
// "is this surface the person" — the thing that type exists to prevent.
import TrustCenter
// Blueprint: | `ApprovalStorage.swift` | Checked approval storage and legacy import |
extension SwiftNativeApprovalInbox {
    /// The most rows `requests.json` keeps. Terminal rows above it are the
    /// store's settled history and are evictable; pending work is not.
    public static let storedApprovalCap = 300
    /// The statuses a row can be in once it is no longer waiting on anyone.
    static let terminalApprovalStatuses: Set<String> = [
        "resolved", "denied", "canceled", "orphaned",
    ]
    /// How long an unanswered card holds its place in a full queue.
    static let pendingApprovalTimeout: TimeInterval = 24 * 3600
    /// Rewrite pending rows nobody has answered within `pendingApprovalTimeout`
    /// to `orphaned`. Newest-first order and every other field are preserved.
    nonisolated static func agingStalePendingRows(
        _ items: [JSONValue],
        now: Date
    ) -> [JSONValue] {
        // ISO-8601 lexicographic compare: every writer here
        // emits the same fractional `+00:00` shape.
        let cutoff = isoTimestamp(now.addingTimeInterval(-pendingApprovalTimeout))
        return items.map { item in
            guard case .object(var object) = item,
                  case .string("pending")? = object["status"] else { return item }
            // A re-asked card is stamped `lastRequestedAt`; the clock runs from
            // the last time the agent actually wanted the answer.
            let stamp: String = {
                if case .string(let value)? = object["lastRequestedAt"] { return value }
                if case .string(let value)? = object["createdAt"] { return value }
                return ""
            }()
            guard !stamp.isEmpty, stamp < cutoff else { return item }
            object["status"] = .string("orphaned")
            return .object(object)
        }
    }
    /// Over cap, ages stale pending rows and evicts oldest settled terminal rows or throws `.queueFull`.
    nonisolated static func cappedEvictingTerminalRows(
        _ items: [JSONValue],
        cap: Int,
        now: Date,
        lifeID: String
    ) throws -> [JSONValue] {
        var overflow = items.count - cap
        guard overflow > 0 else { return items }
        let items = agingStalePendingRows(items, now: now)
        var dropped = Set<Int>()
        // The array is newest-first, so the oldest candidates are at the end.
        for index in stride(from: items.count - 1, through: 0, by: -1) {
            guard overflow > 0 else { break }
            guard case .object(let object) = items[index],
                  case .string(let status)? = object["status"],
                  terminalApprovalStatuses.contains(status) else { continue }
            // Approval precedes execution. Denied and canceled decisions have
            // no executor outcome to await, but may still owe a reporting turn.
            guard let saved = ApprovalRecord(json: items[index]) else { continue }
            let record = Self.readRecord(saved, lifeID: lifeID)
            if status == "resolved", record.decision == "approved", record.executedAction == nil {
                continue
            }
            // A resolved decision is not settled while its reporting turn is
            // unclaimed, queued or in flight. Durable state does not age out.
            if Self.hasChatReportingObligation(record), let saved = record.chatContinuation {
                guard case .object(let state) = saved,
                      state["done"] == .bool(true) else { continue }
            }
            if continuationIsPending(record, now: now) {
                continue
            }
            dropped.insert(index)
            overflow -= 1
        }
        guard overflow == 0 else {
            throw ApprovalInboxError.queueFull(pending: items.count - dropped.count, cap: cap)
        }
        return items.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
    }
    /// Strict authoritative-store read used by every approval read/mutation.
    /// A missing file is the one legitimate empty queue. Once the file exists,
    /// unreadable bytes, malformed JSON, the wrong top-level shape, or even one
    /// malformed row make the whole queue unavailable. In particular, mutation
    /// callers must never turn damaged state into `[]` and overwrite pending
    /// approvals with a newly created record.
    public nonisolated static func loadApprovalRowsChecked(at path: URL) throws -> [JSONValue] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ApprovalInboxError.unavailable(
                underlying: "approval store unreadable: \(error.localizedDescription)"
            )
        }
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw ApprovalInboxError.malformedResponse(
                "approval store contains malformed JSON: \(error.localizedDescription)"
            )
        }
        guard case .array(let items) = raw else {
            throw ApprovalInboxError.malformedResponse(
                "approval store is not a JSON array"
            )
        }
        try validateApprovalRows(items)
        return items
    }
    /// Rejects invalid or duplicate rows before an authoritative queue read or merged write.
    public nonisolated static func validateApprovalRows(_ items: [JSONValue]) throws {
        var ids = Set<String>()
        for (index, item) in items.enumerated() {
            guard case .object(let object) = item,
                  let record = ApprovalRecord(json: item) else {
                throw ApprovalInboxError.malformedResponse(
                    "approval store row \(index) is not a valid approval record"
                )
            }
            guard ids.insert(record.id).inserted else {
                throw ApprovalInboxError.malformedResponse(
                    "approval store contains duplicate id \(record.id)"
                )
            }
            guard record.status == "pending" || terminalApprovalStatuses.contains(record.status) else {
                throw ApprovalInboxError.malformedResponse(
                    "approval store row \(index) has invalid status"
                )
            }
            // Retired writers emitted explicit null authority fields on
            // terminal history. Those rows can no longer grant authority and
            // remain safe to read; pending rows below still require two exact
            // booleans. Wrong-typed non-null values remain store corruption.
            for key in ["remoteResolvable", "localOnly"] {
                guard let value = object[key], value != .null else { continue }
                guard case .bool = value else {
                    throw ApprovalInboxError.malformedResponse(
                        "approval store row \(index) has non-boolean \(key)"
                    )
                }
            }
            if record.status == "pending" {
                guard case .string(let title)? = object["title"], !title.isEmpty,
                      case .string(let action)? = object["action"], !action.isEmpty,
                      case .string? = object["risk"],
                      case .string? = object["reason"],
                      case .object? = object["payload"],
                      case .string? = object["payloadPreview"],
                      case .string(let createdAt)? = object["createdAt"], !createdAt.isEmpty else {
                    throw ApprovalInboxError.malformedResponse(
                        "pending approval row \(index) lacks required typed fields"
                    )
                }
                guard case .bool? = object["remoteResolvable"],
                      case .bool? = object["localOnly"] else {
                    throw ApprovalInboxError.malformedResponse(
                        "pending approval row \(index) lacks authority fields"
                    )
                }
                guard object["decision"] == .null, object["resolvedAt"] == .null else {
                    throw ApprovalInboxError.malformedResponse(
                        "pending approval row \(index) carries terminal decision state"
                    )
                }
                if Self.hardLocalOnlyActions.contains(record.action),
                   (record.remoteResolvable || !record.localOnly) {
                    throw ApprovalInboxError.malformedResponse(
                        "pending approval row \(index) widens a local-only action"
                    )
                }
            }
            if record.status == "pending", record.localOnly != !record.remoteResolvable {
                throw ApprovalInboxError.malformedResponse(
                    "approval store row \(index) has conflicting authority fields"
                )
            }
            let decidedByPresent = object["decidedBy"] != nil
            let provenancePresent = object["resolutionProvenance"] != nil
            guard decidedByPresent == provenancePresent else {
                throw ApprovalInboxError.malformedResponse(
                    "approval store row \(index) has incomplete resolution provenance"
                )
            }
            if provenancePresent {
                guard let provenance = record.resolutionProvenance,
                      record.decidedBy == provenance.decidedBy else {
                    throw ApprovalInboxError.malformedResponse(
                        "approval store row \(index) has malformed resolution provenance"
                    )
                }
            }
        }
    }
    nonisolated static func validateResolutionAuthority(
        _ provenance: ApprovalResolutionProvenance,
        row: [String: JSONValue],
        id: String
    ) throws {
        guard let record = ApprovalRecord(json: .object(row)) else {
            throw ApprovalInboxError.malformedResponse("approval row is malformed")
        }
        guard !provenance.decidedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "decision provenance has no actor"
            )
        }
        if case .telegram = provenance, record.requiresExecutableReview {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "Review and approve the exact code on the Mac or paired phone; Telegram cannot show the whole review."
            )
        }
        if case .signedIOS(let clientID, _) = provenance {
            guard !clientID.isEmpty else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "signed iOS provenance has no client identity"
                )
            }
            // MacSyncActionRouter verifies the per-device signature and pairing.
            // User may answer any request from that phone, whoever raised it;
            // Agent alone decides her studio canon.
            guard !record.isAgentsOwnDecision else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "The agent decides her own studio canon."
                )
            }
            return
        }
        // The card posted into User's own Telegram DM (`ApprovalChatCards`):
        // a private chat's id IS its one user's id, so the binding is the
        // chat and that person both. User, 10-07: that DM is User, with the
        // signed phone's authority, local-only included.
        if case .telegram(let chatID, let userID) = provenance, !chatID.isEmpty, chatID == userID,
           case .object(let card)? = row["chatCard"], card["telegramChatId"] == .string(chatID) {
            guard !record.isAgentsOwnDecision else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "The agent decides her own studio canon."
                )
            }
            return
        }
        if provenance.isRemote {
            guard record.remoteResolvable, !record.localOnly else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "approval is local-only"
                )
            }
        }
        guard case .telegram(let chatID, let userID) = provenance else { return }
        guard !chatID.isEmpty, !userID.isEmpty else {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "Telegram transport identity is incomplete"
            )
        }
        guard case .object(let payload) = record.payload,
              case .object(let telegram)? = payload["telegram"],
              telegram["chatId"] == .string(chatID),
              case .object(let origin)? = payload["origin"],
              origin["userId"] == .string(userID) else {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "Telegram transport identity does not match approval origin"
            )
        }
    }
    nonisolated static func strip(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated static func codepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }
    nonisolated static func pyStr(_ value: JSONValue?, fallback: String) -> String {
        guard let value else { return fallback }
        switch value {
        case .null: return fallback
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .array, .object: return ""
        }
    }
    /// STRICT JSON bool parse for authority fields. This returns nil for
    /// ANYTHING that is not a literal JSON `true`/`false` — no string coercion,
    /// no numeric coercion. Callers of authority fields treat nil as
    /// "undeclared" and fall back to the fail-CLOSED default.
    nonisolated static func strictBool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let b)? = value else { return nil }
        return b
    }
    /// Actions declared REMOTE-SAFE: an approval for one of these may be
    /// resolved from a remote surface (iCloud/Telegram/chat) even when the
    /// creating caller did not pass an explicit `remoteResolvable` boolean.
    /// Everything NOT listed here (and not carrying an explicit `true`) fails
    /// closed to local-only. Keep this list minimal and justified — adding an
    /// entry widens who can approve that action.
    ///
    /// Workflow step gates live here because "the run is parked waiting on
    /// you" is exactly the case a phone approval exists for, and the action
    /// was remotely resolvable before the fail-closed flip (behavior preserved
    /// deliberately, not by accident).
    nonisolated static let remoteSafeActions: Set<String> = [
        "workflow_step",
    ]
    /// Matches Python's `now_iso()` shape: an ISO-8601 string with
    /// fractional seconds and a `+00:00` offset.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }
    /// One-time legacy merge under the canonical owner's mutation lock.
    /// Canonical wins on conflicts. Renaming the source completes the import;
    /// its absence prevents retention-evicted rows from being re-imported.
    /// The .migrated archive preserves the completed import's source bytes.
    public func mergeLegacyApprovalRows() async throws {
        let legacyPath = root
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        guard FileManager.default.fileExists(atPath: legacyPath.path) else { return }
        try await SwiftNativePersistenceCore.withFileLock(approvalsPath) { [approvalsPath] in
            try Self.mergeLegacyRowsLocked(
                legacyPath: legacyPath,
                canonicalPath: approvalsPath
            )
        }
    }
    /// The merge itself. Caller holds the approvals lock.
    private nonisolated static func mergeLegacyRowsLocked(
        legacyPath: URL,
        canonicalPath: URL
    ) throws {
        let legacyRows: [JSONValue] = {
            guard let data = try? Data(contentsOf: legacyPath),
                  let parsed = try? JSONValue.parse(data),
                  case .array(let rows) = parsed else { return [] }
            return rows
        }()
        if !legacyRows.isEmpty {
            var merged = try Self.loadApprovalRowsChecked(at: canonicalPath)
            func rowKey(_ value: JSONValue) -> String? {
                guard case .object(let object) = value else { return nil }
                let execution: String? = {
                    if case .string(let s) = object["executionId"] ?? object["execution_id"]
                        ?? object["missionId"] ?? object["mission_id"] ?? .null { return s }
                    return nil
                }()
                let step: String? = {
                    if case .string(let s) = object["stepId"] ?? object["step_id"]
                        ?? object["id"] ?? .null { return s }
                    return nil
                }()
                guard let execution, let step else { return nil }
                return "\(execution)#\(step)"
            }
            let existing = Set(merged.compactMap(rowKey))
            var appended = false
            for row in legacyRows where rowKey(row).map({ !existing.contains($0) }) == true {
                merged.append(row)
                appended = true
            }
            if appended {
                try Self.validateApprovalRows(merged)
                let data = try JSONValue.array(merged).serialize(pretty: false)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(data.utf8), to: canonicalPath)
            }
        }
        let migratedPath = legacyPath
            .deletingLastPathComponent()
            .appendingPathComponent("requests.json.migrated")
        try? FileManager.default.removeItem(at: migratedPath)
        try? FileManager.default.moveItem(at: legacyPath, to: migratedPath)
    }
}
