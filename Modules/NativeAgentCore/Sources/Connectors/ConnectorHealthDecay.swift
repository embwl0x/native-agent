import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ConnectorHealthDecay.swift` | `ConnectorHealthDecay` and `ConnectorProofLedger`: credential-backed health from latest actual receipts, decayed by age without polling |

// Credential-backed health follows the latest real action receipt. A failure
// of authorization or transport supersedes success; proof decays without polling.

public enum ConnectorHealthDecay {
    /// A connector untouched for this long stops reading green. Seven days —
    /// the sweep's stated window.
    public static let provenWindow: TimeInterval = 7 * 24 * 60 * 60

    public enum Verification: String, Sendable, Equatable {
        /// A real connector call succeeded inside the window.
        case fresh
        /// A real call succeeded once, but not inside the window.
        case stale
        /// A credential exists; no successful call has ever been recorded.
        case configured
    }

    /// Health value written for anything that is not currently proven. Chosen
    /// so the existing "is this green" predicates on both platforms fall
    /// through to their not-healthy branch (the iOS reader treats every value
    /// outside {ok, healthy, ready, connected, active} as needs-attention), and
    /// so the Mac's own `ConnectorUIState` can name it explicitly.
    public static let unverifiedHealth = "unverified"

    /// Auth value written when a credential exists but nothing has ever proven
    /// it works — rendered "configured, unverified".
    public static let configuredAuth = "configured"

    /// Stamped only by the runtime's credential-backed branches. The overlay
    /// clears the saved key, so registry bytes cannot grant proof.
    public static let proofSourceKey = "healthProofSource"

    /// Credential-backed health requires a real connection receipt.
    public static let credentialProofSource = "credential"

    public static func verification(
        lastSuccessAt: Date?,
        now: Date,
        window: TimeInterval = provenWindow
    ) -> Verification {
        guard let lastSuccessAt else { return .configured }
        // A timestamp in the future is still evidence the call happened; clock
        // skew must not read as decay.
        return now.timeIntervalSince(lastSuccessAt) <= window ? .fresh : .stale
    }

    /// Apply the decay to one already-derived registry row.
    ///
    /// `outcome` is the newest non-dry-run connection outcome. Credential-backed
    /// rows derive health from it, including when no receipt has arrived.
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
            // A credential and nothing behind it. There was never a check, so
            // there is no honest `lastCheckedAt` — the frozen stamp dies here
            // rather than being carried forward as if it meant something.
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

    /// Same ISO-8601 spelling the rest of this module emits.
    public static func isoTimestamp(_ date: Date) -> String {
        SwiftNativeConnectorsClient.isoTimestamp(date)
    }
}

// MARK: - Connector-action outcomes

/// Reads the newest connector outcome per connector out of
/// `connectors/actions/receipts.jsonl`. This is the ONLY "the integration
/// actually worked" signal in the system — connector actions and Slack HTTP
/// proofs share ConnectorActionReceipt's schema and append owner.
public enum ConnectorProofLedger {
    /// Receipt statuses that mean the provider was reached and answered.
    /// `dry_run` is deliberately absent: a dry run never left the machine.
    public static let successStatuses: Set<String> = ["succeeded", "completed", "ok"]

    /// The tail scanned on each read. Bounded so a multi-megabyte append-only
    /// ledger never becomes a full-file parse on every Connectors refresh. The
    /// failure mode of a too-short tail is a connector reading `configured`
    /// instead of `stale` — both render "unverified", so the bound can only
    /// under-claim, never fabricate a green.
    public static let maxTailBytes = 512 * 1024

    /// Newest success or connection rejection per family, keyed by `canonicalID`.
    public static func latestByConnector(
        root: URL,
        maxTailBytes: Int = maxTailBytes
    ) -> [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)] {
        latestByConnector(receiptsPath: ConnectorActionReceipt.receiptsPath(root: root), maxTailBytes: maxTailBytes)
    }

    public static func latestByConnector(
        receiptsPath path: URL,
        maxTailBytes: Int = maxTailBytes
    ) -> [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)] {
        var newest: [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)] = [:]
        for line in tailLines(path: path, maxTailBytes: maxTailBytes) {
            guard let data = line.data(using: .utf8),
                  case .object(let row)? = try? JSONValue.parse(data) else { continue }
            guard let connector = string(row["connectorId"]).map(canonicalID),
                  !connector.isEmpty else { continue }
            // A dry run proves nothing about the live integration.
            if case .bool(true)? = row["dryRun"] { continue }
            guard let status = string(row["status"])?.lowercased(),
                  successStatuses.contains(status) || status == "failed" else { continue }
            let rejection = connectionRejection(row["output"])
            if status == "failed", rejection == nil { continue }
            // Local status success proves no transport; a failed credential
            // check still invalidates an earlier successful call.
            if let action = string(row["actionId"])?.lowercased(),
               status != "failed", action.hasSuffix(".status") {
                continue
            }
            guard let created = string(row["createdAt"]),
                  let date = NativeTimestampFormat.parseISO8601FractionalFirst(created) else { continue }
            if let existing = newest[connector], existing.at > date { continue }
            newest[connector] = (date, successStatuses.contains(status), status == "failed" && rejection == true)
        }
        return newest
    }

    /// True for rejected authorization, false for a failed transport, nil for
    /// action/local failures that say nothing about the connection's health.
    private static func connectionRejection(_ output: JSONValue?) -> Bool? {
        guard case .object(let fields)? = output else { return nil }
        let error = string(fields["error"])?.lowercased() ?? ""
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

    /// Registry ids and receipt `connectorId`s compare as one key, trimmed and lowercased.
    public static func canonicalID(_ raw: String) -> String {
        ConnectorOAuthRegistry.normalizedConnectorID(raw)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }


    /// Bounded tail read. The first (possibly partial) line of a seeked read is
    /// dropped, matching the app-side `tailJSONL` idiom.
    private static func tailLines(path: URL, maxTailBytes: Int) -> [String] {
        guard maxTailBytes > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let sizeNumber = attrs[.size] as? NSNumber else { return [] }
        let size = sizeNumber.uint64Value
        guard size > 0 else { return [] }
        let toRead = min(size, UInt64(maxTailBytes))
        let seeked = size > toRead
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        if seeked, (try? handle.seek(toOffset: size - toRead)) == nil { return [] }
        guard let data = try? handle.read(upToCount: Int(toRead)), !data.isEmpty else { return [] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if seeked, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
