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

// Blueprint: | `MacInjectionApproval.swift` | `MacInjectionCapability`: Expiring single-use input authority, approval digests and redacted secret replay |

// MARK: - Approval capability

/// Replay authority is body-bound, expiring and single-use; an approval marker alone grants nothing. Ordinary dispatch retains policy, Full Mac, category, TCC
/// and driver gates.
public struct MacInjectionCapability: Sendable, Equatable {
    /// Retain the authorizing decision id so refusals can identify its source.
    public let approvalID: String
    public let action: String
    public let bodyDigest: String
    /// The authorizing dispatcher supplies the issue clock.
    public let issuedAt: Date
    public let ttlSeconds: Double
    /// The ledger consumes each nonce once.
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

    /// Allow a dispatcher hop without leaving time to bank authorization.
    public static let defaultTTLSeconds: Double = 120

    /// Minting does not independently verify approval; the caller must supply a resolved decision id.
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

    /// Surface validation failures verbatim so blocked input remains diagnosable.
    public enum AuthorizationFailure: String, Sendable, Equatable {
        case actionMismatch = "capability_action_mismatch"
        case bodyMismatch = "capability_body_mismatch"
        case expired = "capability_expired"
        case alreadyUsed = "capability_already_used"
        case digestUnavailable = "capability_digest_unavailable"
    }

    /// Validation is side-effect free; the execution owner consumes the capability only after it passes.
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

    /// Exclude injected transport keys so the approved argument digest matches the dispatched body. `__` keys, operation ids and trigger labels describe
    /// transport rather than the authorized effect.
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

/// The process-global ledger makes one approval buy one injection across dispatchers, tasks and actors.
public actor MacInjectionCapabilityLedger {
    public static let shared = MacInjectionCapabilityLedger()

    private var consumedAt: [String: Date] = [:]

    public func consume(nonce: String, now: Date = Date()) -> Bool {
        prune(now: now)
        guard consumedAt[nonce] == nil else { return false }
        consumedAt[nonce] = now
        return true
    }

    /// Entries older than an hour exceed the two-minute TTL and only retain memory.
    private func prune(now: Date) {
        guard consumedAt.count > 256 else { return }
        for (nonce, stamp) in consumedAt where now.timeIntervalSince(stamp) > 3600 {
            consumedAt.removeValue(forKey: nonce)
        }
    }
}

// MARK: - Approval-record binding digest

/// Bind approval to the redacted body the person saw; separately bind the capability to the rehydrated body that executes.
public enum MacInjectionApprovalDigest {
    /// Exclude injected transport keys just as the capability digest does; unserializable input has no digest.
    public static func digest(tool: String, input: [String: JSONValue], turn: Turn?) -> String? {
        let action = MacInjectionToolNames.action(forTool: tool)
            ?? MacInjectionArgRedaction.normalized(tool)
        let redacted = MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn)
        return MacInjectionCapability.bodyDigest(action: action, body: redacted)
    }
}

/// Pending approval secrets stay in process memory with a TTL; persisted approvals are redacted, and a restart makes replay refuse
/// `injection_secret_unavailable`.
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

    /// Consume secrets once so replay cannot reuse them.
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
