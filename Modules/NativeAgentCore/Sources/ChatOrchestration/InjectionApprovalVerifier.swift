import Foundation
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import MacControl

// MARK: - W2/W3-FIX-R2 1 — replay evidence must be CHECKED, never asserted

/// Why this type exists.
///
/// The first cut let ONE thing exempt an injection tool from the approval
/// floor: an `ApprovedChatToolReplay` whose fields matched the call. But that
/// struct is a public value type with a public init, and its `matches` only
/// asked whether the caller-supplied fields equalled the caller-supplied call
/// plus a NONEMPTY approval id. So any in-process caller could write
/// `ApprovedChatToolReplay(approvalID: "x", tool: "mac_keystroke", ...)`,
/// hand it to `makeGatedToolDispatchClient`, and take the one exemption — then
/// the same unverified string was minted into a `MacInjectionCapability`. The
/// capability's non-forgeability bought nothing, because its ROOT was a string
/// nobody checked.
///
/// The fix is to make the approval record itself the authority. Before the
/// floor exemption and before the mint, the dispatcher asks a verifier whether
/// a record with that id really exists, is really resolved-approved, is for
/// THIS tool and THIS surface, is bound to THIS body, and has not already been
/// spent. A nonempty string is never sufficient; a matching struct is never
/// sufficient; only a record on disk that a human resolved is.
public enum InjectionApprovalVerification: String, Sendable, Equatable {
    case verified
    case recordNotFound = "approval_record_not_found"
    case notApproved = "approval_not_resolved_approved"
    case toolMismatch = "approval_is_for_a_different_tool"
    case surfaceMismatch = "approval_is_for_a_different_surface"
    case bodyMismatch = "approval_is_for_a_different_body"
    case alreadyConsumed = "approval_already_consumed"
    case malformedRecord = "approval_record_malformed"
    /// The DURABLE spend marker could not be recorded (unreadable or corrupt
    /// marker store, failed write). Fail-closed: an injection whose spend
    /// cannot be persisted is an injection nothing would stop replaying after
    /// a restart, so it does not run.
    case spendUnavailable = "approval_spend_unrecordable"
    /// No verifier wired at all. Fail-closed: an injection tool with no way to
    /// check its approval does not run.
    case noVerifier = "approval_verifier_unavailable"
}

/// The seam the dispatcher checks injection approvals through. Production wires
/// `ApprovalInboxInjectionApprovalVerifier`; tests wire the same type against a
/// temp data root (there is no "always yes" implementation in the source tree —
/// see `macInjection_noAlwaysApproveVerifierExistsInSource`).
public protocol InjectionApprovalVerifying: Sendable {
    /// Consumes the approval on success: verification is the single-use gate,
    /// so a verdict of `.verified` is returned at most once per record.
    func verifyInjectionApproval(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async -> InjectionApprovalVerification
}

/// Process-global single-use ledger for injection APPROVAL RECORDS.
///
/// `MacInjectionCapabilityLedger` makes one minted capability usable once. This
/// makes one approval RECORD mintable once, which is the stronger property: a
/// caller that re-presents the same resolved record cannot mint a second
/// capability from it, even from a different dispatcher instance.
public actor MacInjectionApprovalConsumptionLedger {
    public static let shared = MacInjectionApprovalConsumptionLedger()

    private var consumed: Set<String> = []
    private var consumedAt: [String: Date] = [:]

    /// Returns false if this approval id was already spent.
    public func consume(approvalID: String, now: Date = Date()) -> Bool {
        prune(now: now)
        guard !consumed.contains(approvalID) else { return false }
        consumed.insert(approvalID)
        consumedAt[approvalID] = now
        return true
    }

    /// Test seam — hermetic tests must not inherit each other's approvals.
    public func reset() {
        consumed.removeAll()
        consumedAt.removeAll()
    }

    private func prune(now: Date) {
        guard consumedAt.count > 512 else { return }
        for (id, stamp) in consumedAt where now.timeIntervalSince(stamp) > 86_400 {
            consumed.remove(id)
            consumedAt.removeValue(forKey: id)
        }
    }
}

/// The real verifier: the canonical `ApprovalInbox` on disk is the authority.
///
/// Single use is now THREE layers, checked in this order:
///   1. the record's persisted `executedAction` — a completed injection,
///   2. the durable spend marker — an injection that STARTED (survives a
///      crash between the effect landing and the outcome being written),
///   3. the process-global ledger — a second mint inside one process.
/// (2) is the addition; it is the first line of the spend, not a replacement
/// for (1) or (3).
public struct ApprovalInboxInjectionApprovalVerifier: InjectionApprovalVerifying {
    /// Typed as the SPENDING inbox, not the plain one: the durable spend is
    /// part of what makes verification single-use, so an inbox that cannot
    /// record a spend cannot be wired here at all. Fail-closed by type,
    /// with no runtime cast to get wrong.
    private let inbox: any InjectionApprovalSpendingInbox
    private let ledger: MacInjectionApprovalConsumptionLedger

    public init(
        dataRoot: URL,
        ledger: MacInjectionApprovalConsumptionLedger = .shared
    ) {
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
        self.ledger = ledger
    }

    public init(
        inbox: any InjectionApprovalSpendingInbox,
        ledger: MacInjectionApprovalConsumptionLedger = .shared
    ) {
        self.inbox = inbox
        self.ledger = ledger
    }

    public func verifyInjectionApproval(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async -> InjectionApprovalVerification {
        let id = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .recordNotFound }
        guard let record = try? await inbox.get(id) else { return .recordNotFound }

        guard record.status.lowercased() == "resolved",
              record.decision?.lowercased() == "approved" else {
            return .notApproved
        }
        // An executed record is a SPENT record. The persistent half of single
        // use: the process ledger below is lost on restart, this is not.
        if let executed = record.executedAction, executed != .null {
            return .alreadyConsumed
        }
        guard case .object(let payload) = record.payload else { return .malformedRecord }

        let recordTool = Self.string(payload["toolName"])
            ?? Self.string(payload["tool"])
            ?? record.action
        guard Self.normalized(recordTool) == Self.normalized(tool) else { return .toolMismatch }

        // Surface is checked when the record carries one. A record that predates
        // the field (or a non-chat filer that omits it) is not silently trusted
        // for the tool/body checks below — those still run.
        if let recordSurface = Self.string(payload["surface"]),
           Self.normalized(recordSurface) != Self.normalized(surface) {
            return .surfaceMismatch
        }

        guard case .object(let recordInput)? = payload["input"] else { return .malformedRecord }
        guard let approvedDigest = MacInjectionApprovalDigest.digest(tool: tool, input: recordInput),
              let callDigest = MacInjectionApprovalDigest.digest(tool: tool, input: input) else {
            return .malformedRecord
        }
        guard approvedDigest == callDigest else { return .bodyMismatch }

        // THE SPEND, and it happens BEFORE `.verified` is returned.
        //
        // The checks above are all read-only evidence about the record. This is
        // the first WRITE, and it is deliberately first-in-the-transaction: the
        // executor writes `executedAction` only after dispatch returns, so a
        // crash after the click landed but before the annotation left a
        // resolved-approved record with `executedAction == nil` — reusable on
        // the next launch, with the process ledger below gone and (for click /
        // scroll / ax_act) no secret-vault dependency to block the replay.
        // Durably burning the approval here means the crash window contains no
        // reusable state. The spend is never rolled back if the injection then
        // fails; see `InjectionApprovalSpendingInbox`.
        switch await inbox.consumeInjectionApproval(
            id: id,
            digest: callDigest,
            tool: tool,
            surface: surface
        ) {
        case .spent:
            break
        case .alreadySpent:
            return .alreadyConsumed
        case .unavailable:
            return .spendUnavailable
        }

        guard await ledger.consume(approvalID: id) else { return .alreadyConsumed }
        return .verified
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
