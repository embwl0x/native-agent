import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// MARK: - 2026-09-06 — the NON-injection replay exemption is checked too

/// Why this exists.
///
/// `ApprovedChatToolReplay` is a public value type with a public init, and its
/// `matches` only asks whether the caller's fields equal the caller's call plus
/// a NONEMPTY id. Injection tools were already fenced by
/// `InjectionApprovalVerifying`; every OTHER tool was not, so any in-process
/// caller could hand `makeGatedToolDispatchClient` a fabricated replay and skip
/// the SecurityCenter `.ask` (external_send — mail_send / messages_send /
/// mail_reply) for a call nobody ever approved, as many times as it liked.
///
/// The approval record is the authority here as well: the id must resolve to a
/// real record that is resolved-approved, names THIS tool (compared
/// canonically — the record persists the spelling the caller used, which the
/// outer canonicalizer has since rewritten), carries THIS body, and has been
/// spent by the executor moments ago. The executor spends BEFORE it
/// re-dispatches (`applyResolvedChatToolApproval`), so "already spent, just
/// now" is exactly what an honest replay looks like and "no spend marker" is
/// what a forgery looks like. The durable dispatch marker then makes the exemption
/// single-use: a second dispatch presenting the same id is refused.
public enum ApprovedReplayVerification: String, Sendable, Equatable {
    case verified
    case recordNotFound = "approval_record_not_found"
    case notApproved = "approval_not_resolved_approved"
    case toolMismatch = "approval_is_for_a_different_tool"
    case surfaceMismatch = "approval_is_for_a_different_surface"
    case bodyMismatch = "approval_is_for_a_different_body"
    case alreadyConsumed = "approval_already_consumed"
    case malformedRecord = "approval_record_malformed"
    /// No durable effect-spend marker, or one that is too old / for another
    /// call. The dispatcher only ever sees a replay that the executor spent
    /// immediately before dispatching it.
    case notSpentByExecutor = "approval_not_spent_for_this_dispatch"
    /// No verifier wired. Fail-closed: an unverifiable exemption is no
    /// exemption.
    case noVerifier = "approval_verifier_unavailable"
}

public protocol ApprovedReplayVerifying: Sendable {
    /// Consumes the exemption on success: `.verified` is returned at most once
    /// per approval record.
    func verifyApprovedReplay(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async -> ApprovedReplayVerification
}

public struct ApprovalInboxApprovedReplayVerifier: ApprovedReplayVerifying {
    /// How long after the executor's durable spend a replay still counts as
    /// that executor's dispatch. The spend is written immediately before
    /// `dispatch`, so this only has to cover the gate chain in front of it.
    public static let spendFreshnessSeconds: TimeInterval = 300

    private let inbox: SwiftNativeApprovalInbox
    private let canonicalTool: @Sendable (String) -> String
    private let now: @Sendable () -> Date

    public init(
        dataRoot: URL,
        canonicalTool: @escaping @Sendable (String) -> String = { $0 },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
        self.canonicalTool = canonicalTool
        self.now = now
    }

    public func verifyApprovedReplay(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async -> ApprovedReplayVerification {
        let id = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .recordNotFound }
        guard let record = try? await inbox.get(id) else { return .recordNotFound }
        guard record.status.lowercased() == "resolved",
              record.decision?.lowercased() == "approved" else {
            return .notApproved
        }
        // An executed record is a finished record; nothing replays it again.
        //
        // 2026-09-06: a FAILED replay stamp is not an execution. The executor
        // writes `{op: chat_tool_approval_replay, status: failed}` when the
        // dispatch never ran (no filer on a noninteractive surface), and the
        // reconciler's one sanctioned heal re-runs exactly that record — which
        // this check then refused as already consumed, so the approved
        // persona note was never filed. Nothing ran, so nothing was spent.
        if let executed = record.executedAction, executed != .null,
           !Self.isFailedReplayStamp(executed) {
            return .alreadyConsumed
        }
        guard case .object(let payload) = record.payload else { return .malformedRecord }

        let recordTool = Self.string(payload["toolName"])
            ?? Self.string(payload["tool"])
            ?? record.action
        guard sameTool(recordTool, tool) else { return .toolMismatch }
        if let recordSurface = Self.string(payload["surface"]),
           Self.normalized(recordSurface) != Self.normalized(surface) {
            return .surfaceMismatch
        }
        guard case .object(let recordInput)? = payload["input"] else { return .malformedRecord }
        guard recordInput == input else { return .bodyMismatch }

        // The executor's durable spend, which it writes immediately before it
        // re-dispatches. An id nobody spent is an id nobody executed.
        guard case .object(let marker)? = await inbox.approvedEffectSpend(id: id) else {
            return .notSpentByExecutor
        }
        guard let spentAction = Self.string(marker["action"]),
              sameTool(spentAction, tool),
              let spentSurface = Self.string(marker["surface"]),
              Self.normalized(spentSurface) == Self.normalized(surface),
              let spentAt = Self.string(marker["spentAt"]),
              let spentDate = NativeTimestampFormat.parseISO8601(spentAt) else {
            return .notSpentByExecutor
        }
        // 2026-09-06: the marker also carries the executor's digest of the
        // record body it was about to run, and nothing checked it — so a spend
        // written for one body vouched for a dispatch of a record whose payload
        // had since been rewritten. Bind the marker to the body it was minted
        // from, exactly as the executor computes it.
        guard let spentDigest = Self.string(marker["digest"]),
              Self.normalized(spentDigest) == Self.effectDigest(record.payload) else {
            return .notSpentByExecutor
        }
        let age = now().timeIntervalSince(spentDate)
        guard age >= -60, age <= Self.spendFreshnessSeconds else {
            return .notSpentByExecutor
        }

        guard await inbox.consumeApprovedReplayDispatch(id: id) else { return .alreadyConsumed }
        return .verified
    }

    /// The executor's own "nothing ran" annotation: a replay op that failed
    /// before dispatch. Any other executed value is a spent record.
    private static func isFailedReplayStamp(_ executed: JSONValue) -> Bool {
        guard case .object(let stamp) = executed else { return false }
        return stamp["op"] == .string("chat_tool_approval_replay")
            && stamp["status"] == .string("failed")
    }

    private func sameTool(_ lhs: String, _ rhs: String) -> Bool {
        // The record persists the spelling the caller used; the dispatch chain
        // canonicalizes dotted aliases outside every gate, so compare canonical
        // names on both sides.
        Self.normalized(canonicalTool(lhs))
            == Self.normalized(canonicalTool(rhs))
    }

    /// The digest the executor stores in the spend marker: SHA-256 over the
    /// approval record payload's compact (sorted-key, so stable) serialization.
    public static func effectDigest(_ payload: JSONValue) -> String {
        let bytes = (try? payload.serializedData(pretty: false)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
