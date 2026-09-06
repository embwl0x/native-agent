import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Connector health decays (Fable 5.1 sweep item 49, 2026-09-01)
//
// THE LIE THIS REPLACES. `connectors/registry.json` carried `lastCheckedAt`
// frozen at 2026-06-02 with `healthStatus: "ok"` for every row, and the read
// path re-derived that "ok" from OAUTH-TOKEN-FILE PRESENCE
// (`connectorRowWithRuntimeOverlay`) — never from a live call. A token file on
// disk is proof that a sign-in once completed. It is not proof that the
// integration works now: the grant can be revoked, the app deleted, the scope
// dropped, the service down. Rendering that as a green "ok" is a claim the
// code cannot back (NORTHSTAR clause 2).
//
// THE SHAPE OF THE FIX — a clock, not a probe. Same shape as the affect
// half-lives: nothing polls, nothing probes, nothing schedules. A signal
// arrives when a real call succeeds, and DECAYS on its own when none does.
//   • proven by a real successful connector call inside the window → FRESH
//     ("ok"), stamped with that call's timestamp.
//   • proven once, but not within the window            → STALE ("unverified")
//   • credential present, never proven by a call        → CONFIGURED
//     ("configured, unverified")
// Only a row that currently CLAIMS a live connection (`healthStatus == "ok"`)
// AND whose green came from CREDENTIAL PRESENCE can decay. A row that already
// says needs_auth / not_connected / ready / planned / coming_soon is untouched
// — this layer only downgrades an unproven green claim; it never invents a
// state.
//
// WHY THE SECOND CONDITION (2026-09-01 review, HIGH). "healthStatus == ok" was
// the whole test, so every overlay row that reads green decayed — including the
// LOCAL readiness claims that are not credential claims at all: Telegram
// (a configured, enabled bot) and EventKit Calendar (a granted OS permission).
// Neither ever emits a connector-action receipt, so neither can ever be
// "proven"; on a fresh install or a fresh permission grant they flipped
// straight to `configured/unverified` — a NEW lie in place of the old one. The
// eligibility bit is therefore stamped explicitly by the overlay that derived
// the green (`ConnectorHealthDecay.proofSourceKey`), never inferred here.
//
// The evidence is the connector-action receipt ledger
// (`connectors/actions/receipts.jsonl`, written by
// `appendConnectorActionReceipt`), which is the one place a connector call
// that actually reached a provider is recorded. A DRY RUN is not evidence: it
// never touched the provider, so it cannot refresh a health claim.

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

    /// Row key naming WHAT made this row green. Stamped by the runtime overlay
    /// (`NativeClient.connectorRowWithRuntimeOverlay`), which is the only layer
    /// that knows whether it derived "ok" from a credential on disk or from a
    /// live local capability. Deliberately NOT read off the registry file: the
    /// overlay clears the key before deriving, so a hand-edited registry row
    /// cannot claim credential proof it does not have.
    public static let proofSourceKey = "healthProofSource"

    /// The one proof source that decays. A token/credential on disk proves a
    /// sign-in once completed and nothing about now, so its green needs a real
    /// call to stay green. Every other proof source (an OS permission, a local
    /// binary, a configured bot) is a claim the machine can still answer for
    /// directly, and there is no receipt stream that could ever refresh it.
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
    /// `lastSuccessAt` is the newest successful, non-dry-run connector call for
    /// this row's connector (see `ConnectorProofLedger`). Rows that do not
    /// claim health "ok", and rows whose green did not come from credential
    /// presence (no `proofSourceKey == credentialProofSource` stamp from the
    /// overlay), are returned unchanged.
    public static func apply(
        to row: [String: JSONValue],
        lastSuccessAt: Date?,
        now: Date,
        window: TimeInterval = provenWindow
    ) -> [String: JSONValue] {
        guard stringField(row["healthStatus"])?.lowercased() == "ok",
              stringField(row[proofSourceKey])?.lowercased() == credentialProofSource
        else { return row }
        var out = row
        switch verification(lastSuccessAt: lastSuccessAt, now: now, window: window) {
        case .fresh:
            // Keep "ok" — and replace the frozen registry stamp with the
            // timestamp of the call that actually proved it.
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

// MARK: - The proof: successful connector-action receipts

/// Reads the newest successful connector call per connector out of
/// `connectors/actions/receipts.jsonl`. This is the ONLY "the integration
/// actually worked" signal in the system — every connector action lands a
/// receipt there through `appendConnectorActionReceipt`.
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

    public static func receiptsPath(root: URL) -> URL {
        root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    /// Newest successful call per connector family, keyed by `canonicalID`.
    public static func lastSuccessByConnector(
        root: URL,
        maxTailBytes: Int = maxTailBytes
    ) -> [String: Date] {
        lastSuccessByConnector(receiptsPath: receiptsPath(root: root), maxTailBytes: maxTailBytes)
    }

    public static func lastSuccessByConnector(
        receiptsPath path: URL,
        maxTailBytes: Int = maxTailBytes
    ) -> [String: Date] {
        var newest: [String: Date] = [:]
        for line in tailLines(path: path, maxTailBytes: maxTailBytes) {
            guard let data = line.data(using: .utf8),
                  case .object(let row)? = try? JSONValue.parse(data) else { continue }
            guard let connector = string(row["connectorId"]).map(canonicalID),
                  !connector.isEmpty else { continue }
            // A dry run proves nothing about the live integration.
            if case .bool(true)? = row["dryRun"] { continue }
            guard let status = string(row["status"])?.lowercased(),
                  successStatuses.contains(status) else { continue }
            guard let created = string(row["createdAt"]),
                  let date = parseTimestamp(created) else { continue }
            if let existing = newest[connector], existing >= date { continue }
            newest[connector] = date
        }
        return newest
    }

    /// Registry ids and receipt `connectorId`s spell the same integration
    /// differently (the registry says `gcal`/`gmail`; receipts say
    /// `calendar`/`email`). Fold both onto one family key — the same aliasing
    /// `SwiftNativeConnectorAuthClient.providerID` already uses — so proof
    /// recorded under one spelling reaches the row under the other.
    public static func canonicalID(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "email", "gmail": return "gmail"
        case "calendar", "gcal", "google_calendar": return "calendar"
        case "twitter", "x": return "x"
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
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
