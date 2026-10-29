import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
#endif

// Blueprint: | `MacInjectionApproval.swift` | `MacInjectionCapability`, ledger, context, approval digest and secret vault: body-bound expiring single-use input authority and redacted approval evidence |

// MARK: - Approval capability

/// A body-bound, expiring, single-use authorization to synthesize input.
///
/// Explicit approved replay validates the action, body digest, TTL and single-use nonce.
/// Ordinary dispatch uses policy, Full Mac, category, TCC and driver gates directly.
/// `mint` requires the caller's decision id; a JSON approval marker has no authority.
public struct MacInjectionCapability: Sendable, Equatable {
    /// Approval record id (or an equivalent resolved-decision id) this
    /// capability was minted from. Recorded in refusals for audit.
    public let approvalID: String
    /// The single MacControl action this authorizes — "keystroke", "click",
    /// "scroll", or "ax_act".
    public let action: String
    /// SHA-256 over the canonicalized body this authorizes.
    public let bodyDigest: String
    /// Monotonic-ish issue stamp; the authorizing dispatcher supplies `now`.
    public let issuedAt: Date
    /// Seconds after `issuedAt` the capability stops authorizing anything.
    public let ttlSeconds: Double
    /// Unique per mint; the ledger consumes this to enforce single use.
    public let nonce: String

    private init(
        approvalID: String,
        action: String,
        bodyDigest: String,
        issuedAt: Date,
        ttlSeconds: Double,
        nonce: String
    ) {
        self.approvalID = approvalID
        self.action = action
        self.bodyDigest = bodyDigest
        self.issuedAt = issuedAt
        self.ttlSeconds = ttlSeconds
        self.nonce = nonce
    }

    /// Default lifetime of an injection authorization. Long enough to cross a
    /// dispatcher hop, far too short to bank.
    public static let defaultTTLSeconds: Double = 120

    /// Construct a capability without independently checking human approval.
    /// - Parameter approvalID: an approval or automatic-decision id. Empty ⇒ nil.
    public static func mint(
        approvalID: String,
        action: String,
        body: [String: JSONValue],
        now: Date = Date(),
        ttlSeconds: Double = MacInjectionCapability.defaultTTLSeconds
    ) -> MacInjectionCapability? {
        let trimmedApproval = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApproval.isEmpty else { return nil }
        let normalizedAction = Self.normalizedAction(action)
        guard macControlAccessibilityInjectionActions.contains(normalizedAction) else { return nil }
        guard let digest = Self.bodyDigest(action: normalizedAction, body: body) else { return nil }
        return MacInjectionCapability(
            approvalID: trimmedApproval,
            action: normalizedAction,
            bodyDigest: digest,
            issuedAt: now,
            ttlSeconds: ttlSeconds,
            nonce: UUID().uuidString
        )
    }

    /// Why an authorization failed. Surfaced verbatim in the refusal so a
    /// blocked injection is diagnosable without guessing.
    public enum AuthorizationFailure: String, Sendable, Equatable {
        case actionMismatch = "capability_action_mismatch"
        case bodyMismatch = "capability_body_mismatch"
        case expired = "capability_expired"
        case alreadyUsed = "capability_already_used"
        case digestUnavailable = "capability_digest_unavailable"
    }

    /// Pure predicate — no ledger side effect. `SwiftNativeMacControl` calls
    /// `MacInjectionCapabilityLedger.consume` after this passes.
    public func authorizationFailure(
        action rawAction: String,
        body: [String: JSONValue],
        now: Date
    ) -> AuthorizationFailure? {
        let normalized = Self.normalizedAction(rawAction)
        guard normalized == action else { return .actionMismatch }
        guard now.timeIntervalSince(issuedAt) <= ttlSeconds,
              now.timeIntervalSince(issuedAt) >= -5 else { return .expired }
        guard let digest = Self.bodyDigest(action: normalized, body: body) else {
            return .digestUnavailable
        }
        guard digest == bodyDigest else { return .bodyMismatch }
        return nil
    }

    static func normalizedAction(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Canonical digest over (action, body). Transport/plumbing keys the tool
    /// chain injects below the approval point are excluded so the digest a
    /// dispatcher computes over the model's arguments still matches the body
    /// MacControl receives:
    ///   • any `__`-prefixed key (`__session_id` and friends),
    ///   • `operationId` / `operation_id` (minted inside dispatch),
    ///   • `trigger` (a surface label, not an argument).
    public static func bodyDigest(action: String, body: [String: JSONValue]) -> String? {
        var canonicalBody: [String: JSONValue] = [:]
        for (key, value) in body {
            if key.hasPrefix("__") { continue }
            if key == "operationId" || key == "operation_id" || key == "trigger" { continue }
            canonicalBody[key] = value
        }
        let envelope = JSONValue.object([
            "action": .string(normalizedAction(action)),
            "body": .object(canonicalBody),
        ])
        guard let data = try? envelope.serializedData(pretty: false) else { return nil }
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

/// Single-use enforcement for minted capabilities. Process-global by design:
/// the point is that ONE approval buys ONE injection no matter which dispatcher
/// instance, task, or actor presents the capability.
public actor MacInjectionCapabilityLedger {
    public static let shared = MacInjectionCapabilityLedger()

    private var consumedAt: [String: Date] = [:]

    /// Consume `nonce`. Returns false if it was already spent.
    public func consume(nonce: String, now: Date = Date()) -> Bool {
        prune(now: now)
        guard consumedAt[nonce] == nil else { return false }
        consumedAt[nonce] = now
        return true
    }

    /// Entries older than an hour cannot authorize anything anyway (the TTL is
    /// two minutes), so retaining them only grows memory.
    private func prune(now: Date) {
        guard consumedAt.count > 256 else { return }
        for (nonce, stamp) in consumedAt where now.timeIntervalSince(stamp) > 3600 {
            consumedAt.removeValue(forKey: nonce)
        }
    }
}

/// Carries a minted capability from the approval point down to
/// `impl_mac_control_tool`, which cannot receive it as a parameter:
/// `ToolDispatchClient.dispatch(tool:input:surface:)` is a fixed protocol
/// signature shared by every tool.
///
/// A TaskLocal is the right shape here — it is scoped to the exact
/// `inner.dispatch` call the approval authorized and unwinds automatically, so
/// a later tool call in the same turn does not inherit it. It is NOT the
/// security boundary on its own: the capability's action+body binding and
/// single-use ledger are what make an inherited or captured value useless.
public enum MacInjectionCapabilityContext {
    @TaskLocal public static var current: MacInjectionCapability?
}

// MARK: - Approval-record binding digest

/// The digest an APPROVAL RECORD is bound to.
///
/// `MacInjectionCapability.bodyDigest` binds the capability to the body that
/// actually runs (secrets rehydrated). This binds the human's decision to the
/// body they were SHOWN — the redacted form, which is what the record persists.
/// Both are needed: the first stops a capability authorizing a different call,
/// the second stops a replay claiming an approval that was granted for
/// something else.
public enum MacInjectionApprovalDigest {
    /// Digest over the redacted (persisted) form of `input`, canonicalized the
    /// same way the capability digest is, so transport keys the tool chain
    /// injects below the approval point do not change it. Returns nil only when
    /// the input cannot be serialized.
    public static func digest(tool: String, input: [String: JSONValue]) -> String? {
        let action = MacInjectionToolNames.action(forTool: tool)
            ?? MacInjectionArgRedaction.normalized(tool)
        let redacted = MacInjectionArgRedaction.redacted(tool: tool, input: input)
        return MacInjectionCapability.bodyDigest(action: action, body: redacted)
    }
}

/// Pending approval secrets stay in process memory with a TTL; persisted approvals are redacted, and a restart makes replay refuse `injection_secret_unavailable`.
public actor MacInjectionSecretVault {
    public static let shared = MacInjectionSecretVault()

    private struct Entry {
        let secrets: [String: String]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    /// Approvals resolve on human time; an hour is generous and bounded.
    public static let ttlSeconds: Double = 3600

    public func store(approvalID: String, secrets: [String: String], now: Date = Date()) {
        prune(now: now)
        guard !secrets.isEmpty else { return }
        entries[approvalID] = Entry(secrets: secrets, storedAt: now)
    }

    /// Take and REMOVE the secrets for `approvalID`. Single use, like the
    /// capability it feeds.
    public func take(approvalID: String, now: Date = Date()) -> [String: String]? {
        prune(now: now)
        guard let entry = entries.removeValue(forKey: approvalID) else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= Self.ttlSeconds else { return nil }
        return entry.secrets
    }

    private func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.storedAt) <= Self.ttlSeconds }
    }
}
