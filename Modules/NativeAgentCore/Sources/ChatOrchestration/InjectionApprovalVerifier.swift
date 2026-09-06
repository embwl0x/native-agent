import Foundation
import CryptoKit
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
/// what a forgery looks like. The process ledger then makes the exemption
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

/// Process-global single-use ledger for NON-injection replay exemptions. The
/// durable effect spend is written by the executor before dispatch, so it
/// cannot also serve as this dispatch's single-use fence; this can.
public actor ApprovedReplayConsumptionLedger {
    public static let shared = ApprovedReplayConsumptionLedger()

    private var consumed: Set<String> = []
    private var consumedAt: [String: Date] = [:]

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

public struct ApprovalInboxApprovedReplayVerifier: ApprovedReplayVerifying {
    /// How long after the executor's durable spend a replay still counts as
    /// that executor's dispatch. The spend is written immediately before
    /// `dispatch`, so this only has to cover the gate chain in front of it.
    public static let spendFreshnessSeconds: TimeInterval = 300

    private let inbox: SwiftNativeApprovalInbox
    private let ledger: ApprovedReplayConsumptionLedger
    private let now: @Sendable () -> Date

    public init(
        dataRoot: URL,
        ledger: ApprovedReplayConsumptionLedger = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
        self.ledger = ledger
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
        guard Self.sameTool(recordTool, tool) else { return .toolMismatch }
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
              Self.sameTool(spentAction, tool),
              let spentSurface = Self.string(marker["surface"]),
              Self.normalized(spentSurface) == Self.normalized(surface),
              let spentAt = Self.string(marker["spentAt"]),
              let spentDate = Self.parseTimestamp(spentAt) else {
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

        guard await ledger.consume(approvalID: id, now: now()) else { return .alreadyConsumed }
        return .verified
    }

    /// The executor's own "nothing ran" annotation: a replay op that failed
    /// before dispatch. Any other executed value is a spent record.
    private static func isFailedReplayStamp(_ executed: JSONValue) -> Bool {
        guard case .object(let stamp) = executed else { return false }
        return stamp["op"] == .string("chat_tool_approval_replay")
            && stamp["status"] == .string("failed")
    }

    private static func sameTool(_ lhs: String, _ rhs: String) -> Bool {
        // The record persists the spelling the caller used; the dispatch chain
        // canonicalizes dotted aliases outside every gate, so compare canonical
        // names on both sides.
        normalized(CanonicalToolNameDispatcher.canonical(lhs))
            == normalized(CanonicalToolNameDispatcher.canonical(rhs))
    }

    /// The digest the executor stores in the spend marker: SHA-256 over the
    /// approval record payload's compact (sorted-key, so stable) serialization.
    /// Mirrors `NativeClient+ApprovalExecutors.approvalEffectDigest`.
    static func effectDigest(_ payload: JSONValue) -> String {
        let bytes = (try? payload.serializedData(pretty: false)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
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
