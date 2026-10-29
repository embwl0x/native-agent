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
// Blueprint: | `DelegationReadout.swift` | Delegation read values, source availability and retained status snapshots |

// MARK: - Delegation status projection
// The bridge writers own their distinct record shapes; this reader joins job
// state, accepted-message identities and durable delivery receipts. Runner
// heartbeat proves watcher activity, never child progress. Cross-life work is
// stopped; terminal delivery evidence remains retained.

/// One job's projected lifecycle, normalized across the bridge stores. Every timestamp is the RAW string from the record (already ISO-8601 from both writers) — we never reformat, so a malformed legacy value round-trips visibly instead of
/// silently becoming `null`.
public struct DelegationReadout: Sendable, Equatable {
    public var replyOwed: Bool { ["owed", "sent_unconfirmed"].contains(deliveryOutcome ?? "") }

    public enum StallBasis: String, Sendable {
        /// `now` is past the runner's own recorded `deadlineAt`.
        case deadline
        /// Liveness went quiet for longer than the record's `stallSeconds`.
        case stallSeconds = "stall_seconds"
        /// Terminal record — a settled job cannot be stalled.
        case terminal
        /// The record carries neither a deadline nor a stall threshold. `stalled` is reported false but that is ABSENCE OF EVIDENCE.
        case none
        /// Delivery remains unsettled beyond its grace period.
        case deliveryStall = "delivery_stall"
        case rolloutIdle = "rollout_idle"
        case recordedStall = "recorded_stall"
    }

    public var id: String
    /// Exact identity returned to the dispatching turn and therefore used by the shared motor lifecycle. Codex has a separate internal reply-job id; keeping both prevents its terminal projection from closing a different action than the one
    /// dispatch opened.
    public var motorOwnerID: String? = nil
    package var completionDeliveryID: String? = nil
    /// A batched Codex reply retains every accepted action for settlement.
    public internal(set) var acceptedMessageIDs: Set<String> = []
    package var recordedThreadID: String? = nil
    package var recordedTurnID: String? = nil
    /// Claude's `claude:<topic>` handle, joined from the inbox row.
    var conversationID: String? = nil
    /// Her side of the exchange: the inbox message this reply answered.
    var requestTextHead: String? = nil
    /// Retained executor text, distinct from Agent's delivery assessment.
    public var agentReplyTextHead: String? = nil
    /// Bounded original executor words, separate from delivery diagnostics.
    var agentReplyText: String? = nil
    var agentReplyTruncated: Bool = false
    /// Which bridge store this row came from: "claude" | "codex" | "omp".
    public var source: String
    /// The agent that runs the job. Currently 1:1 with `source`, kept separate because the claude store is also where a future third runner would land.
    public var agent: String
    public var contactName: String? = nil
    /// An open conversation she started will receive this job's notice.
    public var reachesHer = false
    public var topicSlug: String?
    /// Exact stable Desk item bound at dispatch, never inferred from prose.
    public var deskHandle: String?
    public var state: String?
    public var status: String?
    public var runStatus: String?
    public var createdAt: String?
    public var claimedAt: String?
    public var startedAt: String?
    /// max(heartbeatAt, progressAt) for claude; measured rollout write for codex.
    public var lastLiveness: String?
    public var watcherObservedAt: String? = nil
    public var toolActivityCount: Int? = nil
    public var noWorkObserved: Bool? = nil
    public var recoveryStatus: String? = nil
    public var completedAt: String?
    /// Wall-clock seconds from the earliest known start (startedAt ?? claimedAt ?? createdAt) to completedAt, or to `now` while the job is still open. nil when no start timestamp exists at all (legacy record).
    public var elapsedSeconds: Int?
    public var stalled: Bool
    public var stallBasis: StallBasis
    /// Only set when the record ITSELF asserts it (claude's `deliveryLost` field). Never inferred — see `deliveryOutcome`.
    public var deliveryLost: Bool?
    /// Receipt or reconciled settlement; retained files alone never prove loss.
    public var deliveryOutcome: String?
    /// Allowlisted machine reason only; never raw helper errors or prose.
    public var deliveryReason: String? = nil
    public var onwardDelivery: JSONValue? = nil
    /// First 200 characters of recorded completion text; absence carries no delivery evidence.
    public var completionTextHead: String?
    /// Read-only recovery evidence. A later receipt is not an automatic replay authorization or proof that a different completion was consumed.
    public var recoveryNote: String? = nil
    /// Bounded, redacted terminal execution evidence, independent of delivery.
    public var executionError: String? = nil
    /// Identifies the evidence being projected, not another execution.
    public var recordKind: String? = nil
    public var deliveryReceiptVersion: String? = nil
    /// Contract/build identity stamped by the NativeAgent runtime that originated this wake. Absence means a legacy/unversioned producer.
    public var producerSchemaVersion: Int? = nil
    public var producerSourceRevision: String? = nil

    /// Newest-first ordering key: the most recent timestamp the record proves.
    var recencyKey: Date?
    /// Exact future crossing at which this open record's existing liveness rule becomes stalled. Drawing and scheduling evidence only; the public JSON continues to expose the verdict and basis, not another workflow field.
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
        // Absent fields are OMITTED, not emitted as null: an older record that predates a field should read as "this record doesn't say", and an explicit null in the envelope invites the model to narrate it as a finding.
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
        put("watcher_observed_at", watcherObservedAt)
        put("recovery_status", recoveryStatus)
        if let toolActivityCount { obj["tool_activity_count"] = .int(Int64(toolActivityCount)) }
        if let noWorkObserved { obj["no_work_observed"] = .bool(noWorkObserved) }
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
        put("thread_id", recordedThreadID)
        put("turn_id", recordedTurnID)
        put("conversation_id", conversationID)
        obj["accepted_message_ids"] = .array(acceptedMessageIDs.sorted().map(JSONValue.string))
        put("delivery_outcome", deliveryOutcome)
        put("delivery_reason", deliveryReason)
        if let onwardDelivery { obj["onward_delivery"] = onwardDelivery }
        put("producer_source_revision", producerSourceRevision)
        if let producerSchemaVersion {
            obj["producer_schema_version"] = .int(Int64(producerSchemaVersion))
        }
        if let elapsedSeconds { obj["elapsed_seconds"] = .int(Int64(elapsedSeconds)) }
        if let deliveryLost { obj["delivery_lost"] = .bool(deliveryLost) }
        return .object(obj)
    }

    /// Provider-facing status row for ordinary progress checks. Lifecycle truth stays intact while low-value duplicate provenance/timestamps are reserved for `detail=full`.
    public func toCompactJSON() -> JSONValue {
        let fields: Set<String> = [
            "id", "agent", "stalled", "stall_basis", "topic_slug", "motor_owner_id", "desk_handle",
            "state", "status", "run_status", "last_liveness", "recovery_status", "tool_activity_count",
            "no_work_observed", "completed_at", "completion_text_head", "execution_error", "record_kind",
            "conversation_id", "delivery_outcome", "delivery_reason", "elapsed_seconds",
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

    package var json: JSONValue {
        .object(["source": .string(source), "agent": .string(agent), "status": .string(status),
                 "readable_records": .int(Int64(readableRecords)), "malformed_records": .int(Int64(malformedRecords)),
                 "unreadable_files": .int(Int64(unreadableFiles))])
    }
}

package struct DelegationStatusReadSnapshot: Sendable {
    package let jobs: [DelegationReadout]
    package let sources: [DelegationSourceAvailability]
    package let matchedCount: Int
}

/// Pure, injectable reader over the three wake-job stores.
