import Foundation
import NativeAgentShared
import AgentWorkspace
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DelegationOutcome.swift` | Store-read availability and delegated outcome/liveness interpretation; terminal outcomes remain distinct from stalls |
// Terminal outcomes remain distinct from the projector's stall classification.
// A durable cursor advances only after the corresponding card is written.


/// One store read: the readable jobs AND whether every configured store
/// actually answered.
public struct DelegationJobsRead: Sendable, Equatable {
    public var jobs: [DelegationReadout]
    /// False when a store directory, job file, or ledger line could not be read
    /// or parsed. An ABSENT store is readable — a bridge that is not configured
    /// on this machine is not a failed read.
    public var allStoresReadable: Bool

    public init(jobs: [DelegationReadout], allStoresReadable: Bool) {
        self.jobs = jobs
        self.allStoresReadable = allStoresReadable
    }
}
extension DelegationReadout {
    public var displayName: String { contactName ?? DelegationOutcomeCard.displayName(source: source, agent: agent) }

    /// An aborted run with reply words on record said something
    /// before it stopped. The words may be interim narration, so the outcome
    /// stays non-success; only the card stops calling it a failure.
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
    /// True when this record proves the run ENDED with an outcome.
    public var isTerminal: Bool {
        if completedAt != nil { return true }
        // Delivery evidence — the settlement written AFTER the POST — is what
        // makes a finished run terminal.
        if isDelivering { return false }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return true }
        return false
    }
    /// The real delegation outcome this record proves, if any.
    public var terminalOutcome: DelegationOutcome? {
        guard isTerminal else { return nil }
        // A dry run made no POST, so a completed run proves no delegation outcome.
        if deliveryOutcome == "let_go" || deliveryOutcome == "dry_run" { return nil }
        // Proven-lost outranks everything: a job whose answer never reached
        // Agent is a failure of the delegation regardless of how the run went.
        if deliveryLost == true || deliveryOutcome == "lost" { return .deliveryLost }
        // Execution may have completed or failed, but an explicitly blocked
        // handoff is never a successful delegation or permission to rerun it.
        // Reuse the existing actionable uncertainty outcome/cursor class.
        if deliveryOutcome == "blocked" { return .unknown }
        if deliveryOutcome == "delivered" { return .succeeded }
        if deliveryOutcome == "failed_before_answer" { return .failed }
        // A live Claude session receives the inbox handoff without spawning another session.
        if statusWord == "delivered_live" { return .succeeded }
        // Inbox-only delivery without a confirmed reader remains unknown.
        if statusWord == "delivered_inbox" { return .unknown }
        if let statusWord, Self.failureStatusWords.contains(statusWord) { return .failed }
        // A completed run with an unconfirmed handoff remains unknown.
        if ["unknown", "owed", "sent_unconfirmed"].contains(deliveryOutcome ?? "") { return .unknown }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return .succeeded }
        // completedAt with no status word at all: it ended, we cannot say how.
        return .unknown
    }
    /// Shared resident-action projection for an asynchronous builder handoff.
    /// A clean runner completion is deliberately still `unverified`: it proves
    /// the delegated agent returned, not that its answer satisfied Agent's
    /// original request.
    public func motorActionReadModel() -> MotorActionReadModel {
        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let next: String?
        if isTerminal && deliveryOutcome == "blocked" && deliveryLost != true {
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
    /// The instant used to order this job against the cursor. `nil` when the
    /// record carries no completion stamp — such a job is deduped by id alone.
    var completionStamp: Date? { DelegationOutcomeCursor.parseISO(completedAt) }
}
/// What a terminal delegated job amounted to.
public enum DelegationOutcome: String, Sendable, Equatable, CaseIterable {
    case succeeded
    case failed
    case deliveryLost = "delivery_lost"
    case unknown

    /// Only a clean success is `info`. Everything else is `actionable` —
    /// including `unknown`, because an unconfirmed delivery is a thing User may
    /// need to act on, and grading it `info` would bury it. A card whose
    /// notice reaches her is `info` instead (`DelegationOutcomeCard.reachesHer`).
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
