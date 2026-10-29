import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ApprovalReplayAuthorizer.swift` | `ApprovalInboxApprovedReplayVerifier`: verifies replay authority against canonical inbox state and effect identity before approved dispatch |

/// Approved replay requires a matching grant, a fresh executor spend and single-use dispatch.
public enum ApprovedReplayVerification: String, Sendable, Equatable {
    case verified
    case recordNotFound = "approval_record_not_found"
    case recordUnavailable = "approval_requests_store_unavailable"
    case spendUnavailable = "approval_effect_spend_store_unavailable"
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
}

public struct ApprovalInboxApprovedReplayVerifier: Sendable {
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
        let record: ApprovalRecord
        do { record = try await inbox.get(id) }
        catch ApprovalInboxError.notFound { return .recordNotFound }
        catch { return .recordUnavailable }
        guard record.status.lowercased() == "resolved",
              record.decision?.lowercased() == "approved" else {
            return .notApproved
        }
        if record.executedAction != nil { return .alreadyConsumed }
        guard case .object(let payload) = record.payload else { return .malformedRecord }

        let recordTool = Self.string(payload["toolName"])
            ?? Self.string(payload["tool"])
            ?? record.action
        guard sameTool(recordTool, tool) else { return .toolMismatch }
        if let recordSurface = Self.string(payload["surface"]),
           Self.normalized(recordSurface) != Self.normalized(surface) {
            return .surfaceMismatch
        }
        let workshopStep = ExecutionEventVocabulary.matches(record.action, WorkshopStepApprovalAction.canonical)
        if workshopStep, surface != "mission" { return .surfaceMismatch }
        guard case .object(let recordInput)? = payload[workshopStep ? "args" : "input"] else { return .malformedRecord }
        guard recordInput == input else { return .bodyMismatch }

        // The executor's durable spend, which it writes immediately before it
        // re-dispatches. An id nobody spent is an id nobody executed.
        do {
            return try await inbox.consumeApprovedReplayDispatch(id: id) { marker in
                guard let spentAction = Self.string(marker["action"]),
                      sameTool(spentAction, tool),
                      let spentSurface = Self.string(marker["surface"]),
                      Self.normalized(spentSurface) == Self.normalized(surface),
                      let spentAt = Self.string(marker["spentAt"]),
                      let spentDate = NativeTimestampFormat.parseISO8601(spentAt) else { return false }
                // The executor's spend digest must match the approval payload.
                guard let spentDigest = Self.string(marker["digest"]),
                      Self.normalized(spentDigest) == Self.effectDigest(record.payload) else { return false }
                let age = now().timeIntervalSince(spentDate)
                return age >= -60 && age <= Self.spendFreshnessSeconds
            }
        } catch { return .spendUnavailable }
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
