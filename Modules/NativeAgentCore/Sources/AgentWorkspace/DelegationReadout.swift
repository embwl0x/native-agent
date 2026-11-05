import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import Darwin
import AppKit
import MacControl
import Desk
import StandingBots
import Transcripts
import ChatToolParsing
// Blueprint: | `DelegationReadout.swift` | retain source availability and distinct delivery/execution times |

// MARK: - Delegation status projection
// The lifecycle owners write the delivery records this projection reads. Cross-life work is stopped; terminal delivery evidence remains retained.

/// Keep raw timestamp strings so malformed values remain visible instead of silently becoming null.
public struct DelegationReadout: Sendable, Equatable {
    public var replyOwed: Bool { ["owed", "sent_unconfirmed"].contains(deliveryOutcome ?? "") }

    public enum StallBasis: String, Sendable {
        case deadline
        case stallSeconds = "stall_seconds"
        /// Settled jobs cannot be stalled.
        case terminal
        /// Missing deadline and stall threshold means unknown timing, even though `stalled` is false.
        case none
        case deliveryStall = "delivery_stall"
        case rolloutIdle = "rollout_idle"
        case recordedStall = "recorded_stall"
    }

    public var id: String
    /// Use the accepted dispatch identity for motor settlement; an internal reply-job ID must not close another action.
    public var motorOwnerID: String? = nil
    package var completionDeliveryID: String? = nil
    /// Retain every accepted action in a batch for settlement.
    public internal(set) var acceptedMessageIDs: Set<String> = []
    /// The inbox row owns the topic handle.
    var conversationID: String? = nil
    var requestTextHead: String? = nil
    /// Executor text remains separate from the agent's delivery assessment.
    public var agentReplyTextHead: String? = nil
    /// Bounded original executor words, separate from delivery diagnostics.
    var agentReplyText: String? = nil
    var agentReplyTruncated: Bool = false
    public var source: String
    /// Keep runner identity distinct from storage source.
    public var agent: String
    public var contactName: String? = nil
    /// An open conversation the agent started will receive this job's notice.
    public var reachesAgent = false
    public var topicSlug: String?
    /// Exact stable Desk item bound at dispatch, never inferred from prose.
    public var deskHandle: String?
    public var state: String?
    public var status: String?
    public var runStatus: String?
    public var createdAt: String?
    public var claimedAt: String?
    public var startedAt: String?
    /// Use the source's attested heartbeat/progress or measured rollout-write time.
    public var lastLiveness: String?
    public var completedAt: String?
    /// Elapsed time requires a recorded start; nil retains unknown timing.
    public var elapsedSeconds: Int?
    public var stalled: Bool
    public var stallBasis: StallBasis
    /// Only the record's explicit deliveryLost field can prove loss.
    public var deliveryLost: Bool?
    /// Receipt or reconciled settlement; retained files alone never prove loss.
    public var deliveryOutcome: String?
    /// Raw delivery-owner update time; never an execution completion timestamp.
    public var deliveryUpdatedAt: String? = nil
    /// First 200 characters of recorded completion text; absence carries no delivery evidence.
    public var completionTextHead: String?
    /// Read-only recovery evidence. A later receipt is not an automatic replay authorization or proof that a different completion was consumed.
    public var recoveryNote: String? = nil
    /// Bounded, redacted terminal execution evidence, independent of delivery.
    public var executionError: String? = nil
    /// Identifies the evidence being projected, not another execution.
    public var recordKind: String? = nil
    public var deliveryReceiptVersion: String? = nil

    var recencyKey: Date?
    /// Schedule the exact future stall crossing without creating another workflow field.
    var stallDeadline: Date?

    func stalled(at now: Date) -> Bool {
        stallBasis == .recordedStall || (stallDeadline.map { now >= $0 } ?? stalled)
    }

    public func toJSON(includeReplyText: Bool = false) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "source": .string(source),
            "agent": .string(agent),
            "stalled": .bool(stalled),
            "stall_basis": .string(stallBasis.rawValue),
        ]
        // Omit absent fields: missing evidence must not be presented as a finding through explicit null.
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        put("topic_slug", topicSlug)
        put("motor_owner_id", motorOwnerID)
        put("desk_handle", deskHandle)
        put("state", state)
        put("status", status)
        put("run_status", runStatus)
        put("created_at", createdAt)
        put("claimed_at", claimedAt)
        put("started_at", startedAt)
        put("last_liveness", lastLiveness)
        put("completed_at", completedAt)
        put("completion_text_head", completionTextHead)
        put("request_text_head", requestTextHead)
        put("agent_reply_text_head", agentReplyTextHead)
        if includeReplyText {
            put("agent_reply_text", agentReplyText)
            if agentReplyText != nil { obj["agent_reply_truncated"] = .bool(agentReplyTruncated) }
        }
        put("execution_error", executionError)
        put("record_kind", recordKind)
        put("recovery_note", recoveryNote)
        put("conversation_id", conversationID)
        obj["accepted_message_ids"] = .array(acceptedMessageIDs.sorted().map(JSONValue.string))
        put("delivery_outcome", deliveryOutcome)
        put("delivery_updated_at", deliveryUpdatedAt)
        if let elapsedSeconds { obj["elapsed_seconds"] = .int(Int64(elapsedSeconds)) }
        if let deliveryLost { obj["delivery_lost"] = .bool(deliveryLost) }
        return .object(obj)
    }

    /// Keep lifecycle truth in progress rows; reserve duplicate provenance and timestamps for `detail=full`.
    public func toCompactJSON() -> JSONValue {
        let fields: Set<String> = [
            "id", "agent", "stalled", "stall_basis", "topic_slug", "motor_owner_id", "desk_handle",
            "state", "status", "run_status", "last_liveness", "completed_at", "completion_text_head", "execution_error", "record_kind",
            "conversation_id", "delivery_outcome", "elapsed_seconds",
        ]
        guard case .object(let full) = toJSON(includeReplyText: false) else { preconditionFailure("Delegation projection must be an object") }
        return .object(full.filter { fields.contains($0.key) })
    }
}

package struct DelegationSourceAvailability: Sendable {
    package let source: String
    package let agent: String
    package var status = "available"
    package var readableRecords = 0
    package var malformedRecords = 0
    package var unreadableFiles = 0
    package var detail: String? = nil

    package var json: JSONValue {
        .object(["source": .string(source), "agent": .string(agent), "status": .string(status),
                 "readable_records": .int(Int64(readableRecords)), "malformed_records": .int(Int64(malformedRecords)),
                 "unreadable_files": .int(Int64(unreadableFiles)), "detail": detail.map(JSONValue.string) ?? .null])
    }
}

package struct DelegationStatusReadSnapshot: Sendable {
    package let jobs: [DelegationReadout]
    package let sources: [DelegationSourceAvailability]
    package let matchedCount: Int
}
