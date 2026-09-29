import Connectors
import Foundation
import NativeAgentShared
import PersistenceCore
import GitHubConnector
import SlackConnector
import SlackBot
import TelegramBot

/// Platform permission evidence and the current display voice are supplied lazily.
public protocol ConnectorStatusPlatform {
    func calendarEventKitReadState() -> String
    var agentSubject: String { get }
}

public enum ConnectorStatusProjection {
    public static func connectorRowWithRuntimeOverlay(
        _ row: [String: JSONValue],
        root: URL,
        platform: any ConnectorStatusPlatform
    ) -> [String: JSONValue] {
        guard let id = connectorString(row["id"]).map(normalizedConnectorID), !id.isEmpty else {
            return row
        }
        var out = row
        out["id"] = .string(id)
        // Health decay eligibility is DERIVED here, never carried in from the
        // registry file: a hand-edited row must not be able to claim (or
        // disclaim) credential proof. Cleared first, stamped below only on the
        // branches whose green comes from a token/credential being present.
        out.removeValue(forKey: ConnectorHealthDecay.proofSourceKey)
        if connectorString(out["name"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            out["name"] = .string(defaultConnectorName(id))
        }
        if connectorString(out["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            out["kind"] = .string("connector")
        }
        if connectorString(out["description"]) == nil {
            out["description"] = .string("")
        }

        // NO credential-proof stamp below: Telegram's green is a LOCAL
        // readiness claim (a configured bot the poll loop owns), and it never
        // emits a connector-action receipt, so decay could only ever downgrade
        // it and never restore it. Same for the EventKit calendar branch.
        if id == "telegram" {
            if let cfg = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: root), !cfg.botToken.isEmpty {
                out["enabled"] = .bool(cfg.enabled)
                out["authState"] = .string("configured")
                out["healthStatus"] = .string(cfg.enabled ? "ok" : "disabled")
            } else {
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_connected")
                out["healthStatus"] = .string("needs_auth")
            }
            return out
        }

        if id == "searxng" {
            if !searxngBaseURL(root: root).isEmpty {
                if connectorBool(out["enabled"]) == nil { out["enabled"] = .bool(true) }
                out["authState"] = .string("not_required")
                out["healthStatus"] = .string("ready")
            } else {
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_required")
                out["healthStatus"] = .string("needs_config")
            }
            return out
        }

        if id == "calendar" {
            switch platform.calendarEventKitReadState() {
            case "ready":
                out["enabled"] = .bool(true)
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
            case "probe_needed":
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_required")
                out["healthStatus"] = .string("probe_needed")
            case "needs_permission":
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_required")
                out["healthStatus"] = .string("needs_permission")
            default:
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_required")
                out["healthStatus"] = .string("unknown")
            }
            return out
        }

        if id == "shortcuts" {
            out["enabled"] = .bool(true)
            out["authState"] = .string("not_required")
            out["healthStatus"] = .string("ready")
            return out
        }

        if id == "browser" {
            out["enabled"] = .bool(true)
            out["authState"] = .string("not_required")
            out["healthStatus"] = .string("ready")
            if connectorString(out["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                out["kind"] = .string("browser")
            }
            if connectorString(out["description"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                out["description"] = .string("Visible browser research and inspection with receipts.")
            }
            return out
        }

        // GitHub's secret is Keychain-backed. The paired auth metadata is
        // created only after a Keychain write-and-read verification and is
        // removed during revoke, so it is the synchronous presentation proof
        // used by this overlay. Actual GitHub actions still resolve the secret
        // from Keychain and fail closed if it was removed externally.
        if id == "github" {
            let metadataExists = GitHubCredentialStore.metadataPaths(dataRoot: root)
                .contains { path in
                    guard let data = try? Data(contentsOf: path),
                          case .object(let metadata) = try? JSONValue.parse(data),
                          connectorString(metadata["credential_store"]) == "macos_keychain"
                    else {
                        return false
                    }
                    return true
                }
            if metadataExists {
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
                markCredentialProof(&out)
            } else {
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_connected")
                out["healthStatus"] = .string("needs_auth")
            }
            return out
        }

        if id == "notion" {
            out["description"] = .string(
                "Search and read pages shared with a validated Notion integration."
            )
            if Self.oauthConnectorTokenExists(oauthId: "notion", root: root) {
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
                markCredentialProof(&out)
            } else {
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_connected")
                out["healthStatus"] = .string("needs_auth")
            }
            return out
        }

        // OAuth PKCE connectors (Google / X). Their registry ids (gmail/gcal/x)
        // map to the OAuth flow's canonical ids (gmail/calendar/x) — the SAME
        // aliases ConnectorWizardSetupRoute uses. The overlay MUST key
        // connected-detection by these registry ids: previously the connected
        // branch keyed on "calendar" and the token set on "email", so registry
        // rows "gcal"/"gmail" could NEVER reflect a completed sign-in
        // (A2.3 id-mismatch, W1#8). Order: a real token wins; else an explicit
        // honest-disconnected freeze is preserved; else present needs_auth so
        // the public wizard can collect an operator-owned OAuth app.
        if let oauth = Self.pkceOAuthConnectors[id] {
            out["description"] = .string(oauth.setupNote)
            if Self.oauthConnectorTokenExists(oauthId: oauth.oauthId, root: root) {
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
                markCredentialProof(&out)
                return out
            }
            let existingAuth = connectorString(out["authState"])?.lowercased()
            let existingHealth = connectorString(out["healthStatus"])?.lowercased()
            if existingAuth == "connected_unverified" || existingHealth == "needs_probe" {
                return out
            }
            if !Self.oauthConnectorAppExists(
                oauthId: oauth.oauthId,
                clientIdEnv: oauth.clientIdEnv,
                root: root
            ) {
                out["enabled"] = .bool(false)
                out["authState"] = .string("not_connected")
                out["healthStatus"] = .string("needs_auth")
                return out
            }
            out["enabled"] = .bool(false)
            out["authState"] = .string("not_connected")
            out["healthStatus"] = .string("needs_auth")
            return out
        }

        let tokenBacked: Set<String> = ["email", "slack"]
        if tokenBacked.contains(id) {
            let existingAuth = connectorString(out["authState"])?.lowercased()
            let existingHealth = connectorString(out["healthStatus"])?.lowercased()
            if Self.oauthConnectorTokenExists(oauthId: id, root: root) {
                // A token on disk is hard proof of a real connection;
                // promote regardless of a stale needs_probe / unverified flag.
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
                markCredentialProof(&out)
            } else {
                // No token: honor the honest-disconnected freeze if set.
                if existingAuth == "connected_unverified" || existingHealth == "needs_probe" {
                    // Slack's credential state remains frozen, but its
                    // separately-owned Socket Mode feed still has to be
                    // surfaced below. Other token-backed connectors have no
                    // such runtime feed.
                    if id != "slack" { return out }
                }
                if existingAuth != "connected_unverified" && existingHealth != "needs_probe" {
                    out["authState"] = .string("not_connected")
                    if existingHealth == nil || existingHealth == "ok" || existingHealth == "ready" || existingHealth == "connected" {
                        out["healthStatus"] = .string("needs_auth")
                    }
                }
            }
        }
        if id == "slack" {
            applySlackRuntimeStateFeed(to: &out, root: root, platform: platform)
        }
        return out
    }

    public static func markCredentialProof(_ row: inout [String: JSONValue]) {
        row[ConnectorHealthDecay.proofSourceKey] =
            .string(ConnectorHealthDecay.credentialProofSource)
    }

    public static func applySlackRuntimeStateFeed(
        to row: inout [String: JSONValue],
        root: URL,
        platform: any ConnectorStatusPlatform
    ) {
        switch SlackRuntimeStateFeed.read(dataRoot: root) {
        case .absent:
            row["runtimeStatus"] = .string("unobserved")
            row["runtimeDetail"] = .string("Socket Mode has not produced runtime state yet.")
            row["runtimeUpdatedAt"] = .null
        case .current(let snapshot):
            row["runtimeUpdatedAt"] = .string(snapshot.updatedAt)
            if snapshot.hasReportedError {
                row["runtimeStatus"] = .string("degraded")
                row["runtimeDetail"] = .string("Socket Mode reported a runtime error.")
            } else if snapshot.connected {
                row["runtimeStatus"] = .string("connected")
                row["runtimeDetail"] = .string("Socket Mode heartbeat is current.")
            } else {
                row["runtimeStatus"] = .string("disconnected")
                row["runtimeDetail"] = .string("Socket Mode last reported a disconnected state.")
            }
        case .stale(let snapshot):
            row["runtimeStatus"] = .string("stale")
            row["runtimeDetail"] = .string("Socket Mode state has not refreshed within its heartbeat window.")
            row["runtimeUpdatedAt"] = .string(snapshot.updatedAt)
        case .unavailable:
            row["runtimeStatus"] = .string("unavailable")
            row["runtimeDetail"] = .string("Socket Mode runtime state could not be read safely.")
            row["runtimeUpdatedAt"] = .null
        }
        do {
            if let recovery = try SlackInboundDeliveryJournal.recoverySummary(dataRoot: root),
               recovery.hasQuarantinedEvidence {
                row["runtimeStatus"] = .string("recovery_quarantined")
                row["runtimeDetail"] = .string("A damaged Slack delivery journal was moved aside (.stale-<ts>) and a fresh one started; intake is running again. Accepted-but-undelivered replies may only exist in that file — ask \(platform.agentSubject) to inspect it before any manual retry.")
            } else if let recovery = try SlackInboundDeliveryJournal.recoverySummary(dataRoot: root),
                      recovery.pendingCount > 0 {
                if recovery.isAtCapacity {
                    row["runtimeStatus"] = .string("intake_paused")
                    row["runtimeDetail"] = .string("\(recovery.pendingCount) pending replies; new message intake is paused. \(recovery.unknownCount) need recovery. Ask \(platform.agentSubject) to inspect Slack delivery recovery before any manual retry; nothing is automatically discarded or resent.")
                } else if recovery.unknownCount > 0 {
                    row["runtimeStatus"] = .string("recovery_required")
                    row["runtimeDetail"] = .string("\(recovery.unknownCount) replies have an unknown outcome (\(recovery.pendingCount) pending). Ask \(platform.agentSubject) to inspect Slack delivery recovery before any manual retry; automatic resend is paused.")
                } else {
                    let detail = connectorString(row["runtimeDetail"]) ?? ""
                    row["runtimeDetail"] = .string("\(detail) \(recovery.pendingCount) accepted replies are pending delivery.")
                }
            }
        } catch {
            row["runtimeStatus"] = .string("recovery_unavailable")
            row["runtimeDetail"] = .string("Slack delivery recovery state cannot be read safely. New message intake may be paused; ask \(platform.agentSubject) to inspect it before retrying.")
        }
    }

    public static func oauthConnectorTokenExists(oauthId: String, root: URL) -> Bool {
        let pkce = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(oauthId, isDirectory: true)
            .appendingPathComponent("auth.json")
        let mirror = root
            .appendingPathComponent("oauth_tokens", isDirectory: true)
            .appendingPathComponent("\(oauthId).json")
        return [pkce, mirror].contains { path in
            guard let data = try? Data(contentsOf: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return ["access_token", "oauth_token", "token"].contains { key in
                guard let value = object[key] as? String else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    public static func oauthConnectorAppExists(
        oauthId: String,
        clientIdEnv: String,
        root: URL
    ) -> Bool {
        if let value = ProcessInfo.processInfo.environment[clientIdEnv],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let path = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(oauthId, isDirectory: true)
            .appendingPathComponent("oauth_app.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = object["client_id"] as? String else {
            return false
        }
        return !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func connectorRows(from value: JSONValue) -> [[String: JSONValue]] {
        ConnectorOAuthRegistry.connectorRows(from: value)
    }

    public static func connectorRow(_ row: [String: JSONValue], matches providerID: String) -> Bool {
        ConnectorOAuthRegistry.connectorRow(row, matches: providerID)
    }

    public static func normalizedConnectorID(_ raw: String) -> String {
        ConnectorOAuthRegistry.normalizedConnectorID(raw)
    }

    public static func connectorString(_ value: JSONValue?) -> String? {
        ConnectorOAuthRegistry.connectorString(value)
    }

    public static func connectorBool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if case .bool(let bool) = value { return bool }
        return nil
    }

    public static func searxngBaseURL(root: URL) -> String {
        let path = root.appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["searxng_base_url"] as? String
        else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func defaultConnectorName(_ id: String) -> String {
        switch id {
        case "searxng": return "SearXNG"
        case "local_files": return "Local File Workspaces"
        case "github": return "GitHub"
        case "x": return "X"
        case "agentmail": return "AgentMail"
        default:
            return id
                .split(separator: "_")
                .map { part in part.prefix(1).uppercased() + part.dropFirst() }
                .joined(separator: " ")
        }
    }

    public static func connectorRegistryPath(root: URL) -> URL {
        ConnectorOAuthRegistry.connectorRegistryPath(root: root)
    }

    public static let pkceOAuthConnectors:
        [String: (clientIdEnv: String, oauthId: String, setupNote: String)] = [
        "gmail": ("NATIVE_AGENT_GMAIL_CLIENT_ID", "gmail",
                  "Search and read Gmail through an operator-configured Google OAuth app."),
        "gcal": ("NATIVE_AGENT_CALENDAR_CLIENT_ID", "calendar",
                 "Read Google Calendar through an operator-configured Google OAuth app."),
        "x": ("NATIVE_AGENT_X_CLIENT_ID", "x",
              "Use the X tools through an operator-configured X OAuth app."),
    ]

    public static func readConnectorRecords(root: URL, platform: any ConnectorStatusPlatform, seedDefaults: () async -> Void) async throws -> [ConnectorRecord] {
        // Fresh install shows the blank-slate catalog instead of "0 connectors".
        await seedDefaults()
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        let current = try await persistence.withFileLock(path) {
            try ConnectorOAuthRegistry.readRegistry(at: path)
        }
        // Fable 5.1 item 49 — health DECAYS. The overlay below derives "ok" from
        // credential PRESENCE (a token file, a saved config), which proves a
        // sign-in once completed, not that the integration works now. This
        // layer asks the connector-action receipt ledger whether a real,
        // non-dry-run call has succeeded lately and downgrades an unproven
        // green to "unverified" — a clock, never a probe. Only rows the overlay
        // stamped as credential-proved are eligible: a local readiness claim
        // (Telegram's configured bot, EventKit's granted calendar permission)
        // has no receipt stream that could ever refresh it, so decaying it
        // would swap one lie for another. It is applied HERE,
        // on the list read that feeds both the Connectors view and the phone
        // projection, and deliberately NOT on the mutation path's readiness
        // gate (NativeClient+RegistryMutations), which asks a different
        // question: may this connector be enabled at all.
        let proof = ConnectorProofLedger.lastSuccessByConnector(root: root)
        let decayNow = Date()
        let checkedRows = try ConnectorOAuthRegistry.checkedConnectorRows(from: current)
        // The phone's readiness and action eligibility must not conceal a
        // malformed credential behind a second, apparently healthy source.
        for row in checkedRows {
            let id = normalizedConnectorID(connectorString(row["id"]) ?? "")
            if id == "telegram" {
                try TelegramBot.TelegramConfig.validateSavedConfiguration(dataRoot: root)
            }
            if id == "searxng" {
                let config = try await persistence.readJSON(root.appendingPathComponent("research/config.json"), ifMissing: .object([:]))
                guard case .object(let fields) = config,
                      fields["searxng_base_url"] == nil || connectorString(fields["searxng_base_url"]) != nil else {
                    throw PersistenceCoreError.ioFailure("Saved SearXNG settings must contain a string URL")
                }
            }
            if ["github", "slack", "notion", "gmail", "gcal", "x", "email"].contains(id) {
                let oauthID = id == "gcal" ? "calendar" : id
                for path in [
                    root.appendingPathComponent("oauth_tokens/\(oauthID).json"),
                    root.appendingPathComponent("connectors/\(oauthID)/auth.json"),
                    root.appendingPathComponent("connectors/\(oauthID)/oauth_app.json"),
                ] {
                    _ = try ConnectorOAuthRegistry.checkedCredentialObject(at: path)
                }
            }
        }
        let rows = checkedRows
            .map { connectorRowWithRuntimeOverlay($0, root: root, platform: platform) }
            .map { row -> [String: JSONValue] in
                let family = ConnectorProofLedger.canonicalID(connectorString(row["id"]) ?? "")
                return ConnectorHealthDecay.apply(
                    to: row,
                    lastSuccessAt: proof[family],
                    now: decayNow
                )
            }
        let data = try JSONValue.array(rows.map { .object($0) }).serializedData(pretty: false)
        return try JSONDecoder().decode([ConnectorRecord].self, from: data)
    }
}
