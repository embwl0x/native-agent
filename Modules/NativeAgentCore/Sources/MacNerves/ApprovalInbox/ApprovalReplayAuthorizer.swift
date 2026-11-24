import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ApprovalReplayAuthorizer.swift` | `ApprovalInboxApprovedReplayVerifier`; Match grant, spend and effect. |

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
    /// Only a fresh spend for this call may reach dispatch.
    case notSpentByExecutor = "approval_not_spent_for_this_dispatch"
}

public struct ApprovalInboxApprovedReplayVerifier: Sendable {
    /// Covers only the gate chain: the executor writes its spend immediately before dispatch.
    public static let spendFreshnessSeconds: TimeInterval = 300

    private let inbox: SwiftNativeApprovalInbox
    private let canonicalTool: @Sendable (String) -> String
    private let now: @Sendable () -> Date

    public init(
        inbox: SwiftNativeApprovalInbox,
        canonicalTool: @escaping @Sendable (String) -> String = { $0 },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = inbox
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

        let recordTool = payload["toolName"]?.trimmedString
            ?? payload["tool"]?.trimmedString
            ?? record.action
        guard sameTool(recordTool, tool) else { return .toolMismatch }
        if let recordSurface = payload["surface"]?.trimmedString,
           TextNormalization.trimmedLowercased(recordSurface) != TextNormalization.trimmedLowercased(surface) {
            return .surfaceMismatch
        }
        guard case .object(let recordInput)? = payload["input"] else { return .malformedRecord }
        guard recordInput == input else { return .bodyMismatch }

        // Replay authority requires the executor's durable spend, not just an approval id.
        do {
            return try await inbox.consumeApprovedReplayDispatch(id: id) { marker in
                guard let spentAction = marker["action"]?.trimmedString,
                      sameTool(spentAction, tool),
                      let spentSurface = marker["surface"]?.trimmedString,
                      TextNormalization.trimmedLowercased(spentSurface) == TextNormalization.trimmedLowercased(surface),
                      let spentAt = marker["spentAt"]?.trimmedString,
                      let spentDate = NativeTimestampFormat.parseISO8601(spentAt) else { return false }
                guard let spentDigest = marker["digest"]?.trimmedString,
                      TextNormalization.trimmedLowercased(spentDigest) == Self.effectDigest(record.payload) else { return false }
                let age = now().timeIntervalSince(spentDate)
                return age >= -60 && age <= Self.spendFreshnessSeconds
            }
        } catch { return .spendUnavailable }
    }

    private func sameTool(_ lhs: String, _ rhs: String) -> Bool {
        // Compare canonical names because storage retains caller spelling while dispatch canonicalizes aliases.
        TextNormalization.trimmedLowercased(canonicalTool(lhs))
            == TextNormalization.trimmedLowercased(canonicalTool(rhs))
    }

    /// The digest the executor stores in the spend marker: SHA-256 over the approval record payload's compact (sorted-key, so stable) serialization.
    public static func effectDigest(_ payload: JSONValue) -> String {
        let bytes = (try? payload.serializedData(pretty: false)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
