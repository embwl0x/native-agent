import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ConnectorHealthDecay.swift` | `ConnectorHealthDecay` and checked `ConnectorProofLedger`: receipt-backed health decays without polling |

// Credential-backed health follows the latest real action receipt. A failure of authorization or transport supersedes success; proof decays without polling.

public enum ConnectorHealthDecay {
    public static let provenWindow: TimeInterval = 7 * 24 * 60 * 60

    public enum Verification: String, Sendable, Equatable {
        case fresh
        case stale
        case configured
    }

    /// Both platforms treat values outside {ok, healthy, ready, connected, active} as unverified.
    public static let unverifiedHealth = "unverified"

    /// Credentials without action proof are configured, never verified.
    public static let configuredAuth = "configured"

    /// Only credential-backed runtime receipts may stamp proof; saved registry bytes cannot grant it.
    public static let proofSourceKey = "healthProofSource"

    /// Credential-backed health requires a real connection receipt.
    public static let credentialProofSource = "credential"

    public static func verification(
        lastSuccessAt: Date?,
        now: Date,
        window: TimeInterval = provenWindow
    ) -> Verification {
        guard let lastSuccessAt else { return .configured }
        // Future timestamps still prove a call happened; clock skew must not imply decay.
        return now.timeIntervalSince(lastSuccessAt) <= window ? .fresh : .stale
    }

    /// Only the newest real connection outcome can establish health; missing receipts remain unverified.
    public static func apply(
        to row: [String: JSONValue],
        outcome: (at: Date, succeeded: Bool, authorizationFailed: Bool)?,
        now: Date,
        window: TimeInterval = provenWindow
    ) -> [String: JSONValue] {
        guard stringField(row[proofSourceKey])?.lowercased() == credentialProofSource
        else { return row }
        var out = row
        out["authState"] = .string(configuredAuth)
        if let outcome, !outcome.succeeded {
            if outcome.authorizationFailed { out["authState"] = .string("failed") }
            out["healthStatus"] = .string("failed")
            out["lastCheckedAt"] = .string(isoTimestamp(outcome.at))
            return out
        }
        let lastSuccessAt = outcome?.at
        switch verification(lastSuccessAt: lastSuccessAt, now: now, window: window) {
        case .fresh:
            out["authState"] = .string("connected")
            out["healthStatus"] = .string("ok")
            out["lastCheckedAt"] = .string(isoTimestamp(lastSuccessAt!))
        case .stale:
            out["healthStatus"] = .string(unverifiedHealth)
            out["lastCheckedAt"] = .string(isoTimestamp(lastSuccessAt!))
        case .configured:
            // Without a real check there is no honest lastCheckedAt to retain.
            out["authState"] = .string(configuredAuth)
            out["healthStatus"] = .string(unverifiedHealth)
            out["lastCheckedAt"] = .null
        }
        return out
    }

    private static func stringField(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isoTimestamp(_ date: Date) -> String {
        SwiftNativeConnectorsClient.isoTimestamp(date)
    }
}

// MARK: - Connector-action outcomes

/// Connector actions and Slack HTTP proofs share this canonical receipt schema and append owner.
public enum ConnectorProofLedger {
    /// Exclude dry_run: a preview never reaches the provider.
    public static let successStatuses: Set<String> = ["succeeded", "completed", "ok"]

    /// Bound refresh parsing; a short tail can underclaim configured versus stale, but cannot fabricate health.
    public static let maxTailBytes = 512 * 1024

    public static func latestByConnector(
        root: URL,
        maxTailBytes: Int = maxTailBytes
    ) throws -> [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)] {
        try latestByConnector(receiptsPath: ConnectorActionReceipt.receiptsPath(root: root), maxTailBytes: maxTailBytes)
    }

    public static func latestByConnector(
        receiptsPath path: URL,
        maxTailBytes: Int = maxTailBytes
    ) throws -> [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)] {
        var newest: [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)] = [:]
        guard let read = try SwiftNativePersistenceCore.tailPhysicalLines(path, limit: .max, maxBytes: maxTailBytes) else { return newest }
        // Only a real leading fragment is omitted by the physical-line owner.
        for line in read.lines.dropFirst(read.leadingFragment ? 1 : 0) {
            guard String(data: line, encoding: .utf8) != nil,
                  case .object(let row) = try JSONValue.parse(line) else { throw ledgerUnavailable(path) }
            guard let connector = row["connectorId"]?.stringValue.map(canonicalID),
                  !connector.isEmpty else { throw ledgerUnavailable(path) }
            // A dry run proves nothing about the live integration.
            if case .bool(true)? = row["dryRun"] { continue }
            guard let status = row["status"]?.stringValue?.lowercased() else { throw ledgerUnavailable(path) }
            guard successStatuses.contains(status) || status == "failed" else { continue }
            let rejection = connectionRejection(row["output"])
            if status == "failed", rejection == nil { continue }
            // Local status success proves no transport; a failed credential check still invalidates an earlier successful call.
            if let action = row["actionId"]?.stringValue?.lowercased(),
               status != "failed", action.hasSuffix(".status") {
                continue
            }
            guard let created = row["createdAt"]?.stringValue,
                  let date = NativeTimestampFormat.parseISO8601FractionalFirst(created) else { throw ledgerUnavailable(path) }
            if let existing = newest[connector], existing.at > date { continue }
            newest[connector] = (date, successStatuses.contains(status), status == "failed" && rejection == true)
        }
        return newest
    }

    private static func ledgerUnavailable(_ path: URL) -> NSError {
        NSError(domain: "NativeAgentConnectorProof", code: -1,
            userInfo: [NSLocalizedDescriptionKey: """
                Connector evidence is unreadable or malformed at \(path.path). Repair the receipt ledger before trusting connection health.
                """])
    }

    /// True for rejected authorization, false for a failed transport, nil for action/local failures that say nothing about the connection's health.
    private static func connectionRejection(_ output: JSONValue?) -> Bool? {
        guard case .object(let fields)? = output else { return nil }
        let error = fields["error"]?.stringValue?.lowercased() ?? ""
        if error == "transport_failed" { return false }
        if ["invalid_auth", "not_authed", "token_revoked", "account_inactive",
            "invalid_token", "token_expired", "invalid_grant", "invalid_client",
            "unauthorized_client", "refresh_rejected"].contains(error) { return true }
        let code: Int?
        if case .int(let value)? = fields["statusCode"] ?? fields["httpStatus"] {
            code = Int(value)
        } else { code = error.hasPrefix("http_") ? Int(error.dropFirst(5)) : nil }
        if code == 401 { return true }
        if let code, (500...599).contains(code) { return false }
        return nil
    }

    public static func canonicalID(_ raw: String) -> String {
        ConnectorOAuthRegistry.normalizedConnectorID(raw)
    }
}
