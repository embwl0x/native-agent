import Connectors
import Foundation
import NativeAgentShared
import PersistenceCore
import GitHubConnector
import SlackConnector
import SlackBot
import TelegramBot

/// Platform permission evidence and the current display voice are supplied lazily.
public protocol ConnectorStatusPlatform: Sendable {
    func calendarEventKitReadState() -> String
    var agentSubject: String { get }
    /// A distributed public build seeds no self-hosted connectors.
    var isPublicReleaseBundle: Bool { get }
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
                // No usable token behind the claim: the owner has to sign in, not "check".
                out["enabled"] = .bool(false)
                out["healthStatus"] = .string("needs_auth")
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
                out["enabled"] = .bool(false)
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
            if let recovery = try SlackInboundDeliveryJournal.recoverySummary(dataRoot: root) {
                if recovery.isAtCapacity {
                    row["runtimeStatus"] = .string("intake_paused")
                    row["runtimeDetail"] = .string("\(recovery.pendingCount) pending replies; new message intake is paused. \(recovery.unknownCount) need recovery. Ask \(platform.agentSubject) to inspect Slack delivery recovery before any manual retry; nothing is automatically discarded or resent.")
                } else if recovery.unknownCount > 0 {
                    row["runtimeStatus"] = .string("recovery_required")
                    row["runtimeDetail"] = .string("\(recovery.unknownCount) replies have an unknown outcome (\(recovery.pendingCount) pending). Ask \(platform.agentSubject) to inspect Slack delivery recovery before any manual retry; automatic resend is paused.")
                } else if recovery.pendingCount > 0 {
                    let detail = connectorString(row["runtimeDetail"]) ?? ""
                    row["runtimeDetail"] = .string("\(detail) \(recovery.pendingCount) accepted replies are pending delivery.")
                }
                if recovery.hasQuarantinedEvidence {
                    let detail = connectorString(row["runtimeDetail"]) ?? ""
                    row["runtimeDetail"] = .string("\(detail) A damaged Slack delivery journal was moved aside (.stale-<ts>). Accepted replies that were not delivered may only exist in that file; ask \(platform.agentSubject) to inspect it before any manual retry.")
                }
            }
        } catch {
            row["runtimeStatus"] = .string("recovery_unavailable")
            row["runtimeDetail"] = .string("Slack delivery recovery state cannot be read safely. New message intake may be paused; ask \(platform.agentSubject) to inspect it before retrying.")
        }
    }

    public static func oauthConnectorTokenExists(oauthId: String, root: URL) -> Bool {
        // Slack's token is in Keychain, not its files (SlackCredentials).
        if oauthId == "slack" { return (try? SlackCredentials.read(.bot, dataRoot: root)) != nil }
        let pkce = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(oauthId, isDirectory: true)
            .appendingPathComponent("auth.json")
        let mirror = root
            .appendingPathComponent("oauth_tokens", isDirectory: true)
            .appendingPathComponent("\(oauthId).json")
        return [pkce, mirror].contains { path in
            guard let data = try? ConnectorCredentialFile.read(at: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            // A token past its `expires_at` is not a credential (10-10: X read
            // "on" for 16 days on an expired token while Doctor said the owner
            // must sign in). Epoch seconds or an ISO stamp; no stamp means no expiry.
            if let stamp = object["expires_at"] {
                // The token writer stores the epoch as a string ("1790287928.98"); ISO is tolerated too.
                let expires: Date? = (stamp as? Double).map(Date.init(timeIntervalSince1970:))
                    ?? (stamp as? String).flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:))
                    ?? (stamp as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                if let expires, expires <= Date() { return false }
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
        guard let data = try? ConnectorCredentialFile.read(at: path),
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

    public static func readConnectorRecords(root: URL, platform: any ConnectorStatusPlatform) async throws -> [ConnectorRecord] {
        // Fresh install shows the blank-slate catalog instead of "0 connectors".
        await seedDefaultConnectorsIfEmpty(root: root, platform: platform)
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
        // gate (`updateConnector`), which asks a different
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

    public static func updateConnector(
        id: String, enabled: Bool, root: URL, platform: any ConnectorStatusPlatform
    ) async throws -> ConnectorRecord {
        let row = try await ConnectorRegistryActions.updateConnector(
            id: id, enabled: enabled, root: root,
            projection: ConnectorRegistryProjectionPort(
                defaultName: defaultConnectorName,
                overlay: { connectorRowWithRuntimeOverlay($0, root: $1, platform: platform) }
            )
        )
        return try JSONDecoder().decode(ConnectorRecord.self, from: row.serializedData(pretty: false))
    }

    /// Blank-slate connector catalog seeded into an EMPTY registry so a fresh
    /// install shows connectable integrations (present-but-unconnected, clickable
    /// to connect) and the agent can see what it could connect to — instead of
    /// "0 connectors". Auth-required services land as `needs_auth` (→ a "Connect"
    /// button); local/no-auth ones as `ready`. All `enabled=false`.
    private static func defaultConnectorCatalog(isPublicReleaseBundle: Bool) -> [[String: JSONValue]] {
        func rec(_ id: String, _ name: String, _ kind: String,
                 _ auth: String, _ health: String, _ risk: String,
                 _ perms: [String], _ actions: [String], _ desc: String) -> [String: JSONValue] {
            [
                "id": .string(id), "name": .string(name), "kind": .string(kind),
                "authState": .string(auth), "healthStatus": .string(health),
                "riskClass": .string(risk), "enabled": .bool(false),
                "permissions": .array(perms.map { .string($0) }),
                "actions": .array(actions.map { .string($0) }),
                "description": .string(desc),
            ]
        }
        var catalog: [[String: JSONValue]] = [
            rec("browser", "Visible Browser", "browser", "not_required", "ready", "network_read",
                ["browse", "screenshot"], ["open", "inspect", "capture"],
                "Visible browser research and inspection with receipts."),
            rec("local_files", "Local File Workspaces", "files", "not_required", "ready", "file_access",
                ["workspace_read", "workspace_write"], ["search", "list", "read"],
                "Scoped folder access for user-approved workspaces."),
        ]
        // A2.5 (W1#10): SearXNG needs a self-hosted base URL, so on a fresh
        // public install it seeds as a `needs_config` dead end. Drop it from the
        // PUBLIC blank-slate seed (not a feature removal — the connector code,
        // overlay, and wizard all still handle it, and an existing registry that
        // already lists it is untouched since seeding only runs when empty).
        // Dev/personal builds keep the convenience seed.
        if !isPublicReleaseBundle {
            catalog.append(
                rec("searxng", "SearXNG", "research", "not_required", "ready", "network_read",
                    ["search_web", "fetch_url"], ["search", "fetch"],
                    "Private metasearch connector for research."))
        }
        catalog.append(contentsOf: [
            rec("shortcuts", "Apple Shortcuts", "macos", "not_required", "ready", "system_surface",
                ["run_intent"], ["run"],
                "Run Shortcuts for Desk tasks, health checks, status, and chat."),
            rec("telegram", "Telegram", "messaging", "needs_auth", "needs_auth", "external_send",
                ["send_message", "receive_message"], ["reply"],
                "Remote chat bridge through an allowlisted bot. Add a bot token in Telegram settings to connect."),
            rec("github", "GitHub", "dev", "needs_auth", "needs_auth", "network_write",
                ["repo_read", "repo_write"], ["search", "read", "write"],
                "Read and write issues, PRs, and files across your repositories."),
            rec("slack", "Slack", "messaging", "needs_auth", "needs_auth", "external_send",
                ["read_messages", "send_message"], ["read", "send"],
                "Read and post messages in your Slack workspaces."),
            rec("notion", "Notion", "docs", "needs_auth", "needs_auth", "network_read",
                ["read"], ["search", "read"],
                "Search and read pages shared with a validated Notion integration."),
            rec("gmail", "Gmail", "email", "needs_auth", "needs_auth", "network_read",
                ["read_email"], ["search", "read"],
                "Search and read email through your connected Google account."),
            rec("gcal", "Google Calendar", "calendar", "needs_auth", "needs_auth", "network_read",
                ["read_events"], ["read"],
                "Read events from your connected primary Google Calendar."),
            rec("x", "X (Twitter)", "social", "needs_auth", "needs_auth", "external_send",
                ["read", "post"], ["search", "post"],
                "Read your timeline and post with approval via OAuth."),
        ])
        return catalog
    }

    /// Only an absent registry bootstraps. Even an empty saved catalog belongs
    /// to the operator; damaged content is reported by the checked reader.
    private static func seedDefaultConnectorsIfEmpty(root: URL, platform: any ConnectorStatusPlatform) async {
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        _ = try? await persistence.withFileLock(path) {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path.path)
                return
            } catch CocoaError.fileReadNoSuchFile {
                // Missing is the sole bootstrap case.
            }
            let catalog = JSONValue.array(
                defaultConnectorCatalog(isPublicReleaseBundle: platform.isPublicReleaseBundle).map { .object($0) }
            )
            try await persistence.writeJSON(catalog, to: path)
        }
    }
}
