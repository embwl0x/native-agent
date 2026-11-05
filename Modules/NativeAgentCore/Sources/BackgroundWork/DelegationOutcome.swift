import Foundation
import NativeAgentShared
import AgentWorkspace
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DelegationOutcome.swift` | Owner-proven terminal outcomes remain distinct from stalls |
// Terminal outcomes and stalls stay distinct; durable cursor progress requires card settlement.


public struct DelegationJobsRead: Sendable, Equatable {
    public var jobs: [DelegationReadout]
    /// Unconfigured stores are absent, not unreadable; parse and access failures keep availability false.
    public var allStoresReadable: Bool
    public var availabilityError: String?

    public init(jobs: [DelegationReadout], allStoresReadable: Bool, availabilityError: String? = nil) {
        self.jobs = jobs
        self.allStoresReadable = allStoresReadable
        self.availabilityError = availabilityError
    }
}
extension DelegationReadout {
    public var displayName: String { contactName ?? DelegationOutcomeCard.displayName(source: source, agent: agent) }

    /// Recorded speech may be interim narration; it does not turn an aborted run into success.
    var abortedAfterReply: Bool {
        statusWord == "aborted" && !(agentReplyTextHead ?? "").isEmpty
    }
    /// Runner completion or failure is terminal; delivery in flight and bare
    /// `settled` without a status or completedAt provide no terminal evidence.
    static let terminalStatusWords = failureStatusWords.union(["completed", "complete", "succeeded", "success", "ok"])

    static let failureStatusWords: Set<String> = [
        "failed", "failure", "error", "errored",
        "timeout", "timed_out", "cancelled", "canceled", "aborted",
        "spawn_failed", "refused",
    ]

    /// The runner's verdict `runStatus` takes precedence over the job-file `status`.
    var statusWord: String? {
        let raw = runStatus ?? status
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
    /// A run awaiting its bridge POST has no delivery settlement yet.
    var isDelivering: Bool {
        guard completedAt == nil, deliveryOutcome == nil, deliveryLost != true else {
            return false
        }
        return state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "delivering"
    }
    /// Delivery-owner terminal evidence need not carry an execution timestamp.
    public var isTerminal: Bool {
        if statusWord == "observation_unavailable" { return false }
        if completedAt != nil { return true }
        // POST settlement, rather than execution completion alone, makes delivery terminal.
        if isDelivering { return false }
        if stallBasis == .terminal { return true }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return true }
        return false
    }
    /// The real delegation outcome this record proves, if any.
    public var terminalOutcome: DelegationOutcome? {
        guard isTerminal else { return nil }
        // A dry run made no POST, so a completed run proves no delegation outcome.
        if deliveryOutcome == "let_go" || deliveryOutcome == "dry_run" { return nil }
        // Proven loss outranks execution success because the delegated answer did not arrive.
        if deliveryLost == true || deliveryOutcome == "lost" { return .deliveryLost }
        // Blocked handoff proves neither successful delivery nor permission to rerun the work.
        if deliveryOutcome == "blocked" { return .unknown }
        if deliveryOutcome == "delivered" { return .succeeded }
        if deliveryOutcome == "failed_before_answer" { return .failed }
        // Inbox-only delivery without a confirmed reader remains unknown.
        if statusWord == "delivered_inbox" { return .unknown }
        if let statusWord, Self.failureStatusWords.contains(statusWord) { return .failed }
        // A completed run with an unconfirmed handoff remains unknown.
        if ["unknown", "owed", "sent_unconfirmed"].contains(deliveryOutcome ?? "") { return .unknown }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return .succeeded }
        // completedAt with no status word at all: it ended, we cannot say how.
        return .unknown
    }
    /// Runner completion proves only that the delegate returned; satisfying the request remains unverified.
    public func motorActionReadModel() -> MotorActionReadModel {
        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let next: String?
        if statusWord == "observation_unavailable" {
            phase = .unknown
            verification = .unknown
            next = """
                Completion observation is unavailable. Repair the named evidence source and inspect the existing turn; do not interrupt or replay it from \
                silence.
                """
        } else if isTerminal && deliveryOutcome == "blocked" && deliveryLost != true {
            phase = .blocked
            verification = .unknown
            next = "Inspect the retained result and resolve the original completion route before explicitly delivering it. Do not rerun the worker."
        } else if stalled && !isTerminal {
            phase = .blocked
            verification = .pending
            next = "Fresh bridge liveness or a terminal runner outcome."
        } else {
            switch terminalOutcome {
            case .succeeded:
                phase = .succeeded
                verification = .unverified
                next = "The agent must assess the returned result against the originating request."
            case .failed, .deliveryLost:
                phase = .failed
                verification = .failed
                next = deliveryLost == true || deliveryOutcome == "lost"
                    ? "Recover or replay the undelivered reply before relying on the delegation."
                    : "Inspect the canonical bridge failure before retrying or replacing the work."
            case .unknown:
                phase = .unknown
                verification = .unknown
                next = "Resolve the bridge's unconfirmed delivery before relying on the delegation."
            case nil:
                let normalized = (state ?? "").lowercased()
                phase = ["running", "claimed", "bound", "watching", "executing"].contains(normalized)
                    ? .running : .waitingExternal
                verification = .pending
                next = "A terminal runner outcome tied to this bridge message id."
            }
        }
        let stateParts = [source, state, status, runStatus, deliveryOutcome]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return MotorActionReadModel(
            domain: "agent_bridge",
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(motorOwnerID ?? id),
            phase: phase,
            domainState: stateParts.joined(separator: ":"),
            verification: verification,
            expectedNextEvidence: next,
            updatedAt: completedAt ?? lastLiveness,
            cancellationIdentity: nil,
            deadline: nil
        )
    }
    /// Without a completion stamp, dedupe by identity alone rather than inventing cursor order.
    var completionStamp: Date? { DelegationOutcomeCursor.parseISO(completedAt) }
}
public enum DelegationOutcome: String, Sendable, Equatable, CaseIterable {
    case succeeded
    case failed
    case deliveryLost = "delivery_lost"
    case unknown

    /// Unconfirmed delivery needs attention; a resident-delivered notice avoids a duplicate push to the person.
    public var severity: String { self == .succeeded ? "info" : "actionable" }

    /// Re-card only when the alarm rank increases; cards never quietly downgrade.
    public var alarmRank: Int {
        switch self {
        case .succeeded: return 0
        case .unknown: return 1
        case .failed: return 2
        case .deliveryLost: return 3
        }
    }
}
