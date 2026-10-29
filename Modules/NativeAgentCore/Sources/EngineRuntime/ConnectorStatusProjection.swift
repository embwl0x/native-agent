import BackgroundLoops
import Connectors
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SlackBot
import TelegramBot
import Research
import Cognition
import Observation
import AppKit
import EventKit
// Blueprint: | `ConnectorStatusProjection.swift` | `ConnectorReadiness` observable engine owner: `LatestRead` publishes checked accounts, secret metadata and credential-free Slack policy; committed account updates publish through `write`, mutation verification uses its own refresh result; source invalidations; `connectorRowWithRuntimeOverlay`, `readConnectorRecords` (finishes pending Slack saves before seeding an absent registry with undecided choices; publication failures propagate), `updateConnector`, `restartSlackLane` (a Slack toggle or a phone Disconnect rebuilds the Socket Mode lane from what is saved); connector pages share decayed action/HTTP receipt evidence, including the Slack door's Web API calls |

/// The engine's checked account, secret-metadata and Slack-policy revision.
@Observable
public final class ConnectorReadiness: Sendable {
    public typealias SecretMetadata = (name: String, hosts: [String], programs: [Keyring.Program], at: Date, account: String?)
    public let root: URL
    let platform: AppConnectorStatusPlatform
    @MainActor public private(set) var accounts: Result<[ConnectorRecord], Error> = .success([])
    @MainActor public private(set) var secrets: Result<[SecretMetadata], Error>?
    @MainActor public private(set) var slackPolicy: Result<SlackIngressPolicy, Error>?
    @ObservationIgnored @MainActor lazy var snapshotRead = LatestRead()
    @MainActor public internal(set) var workspaceSnapshot: [WorkspaceRecord]?
    @MainActor public var workspaces: [WorkspaceRecord] { workspaceSnapshot ?? [] }
    @MainActor public internal(set) var workspacesReadError: String?
    @MainActor public internal(set) var actions: ConnectorActionRegistry?
    @MainActor public internal(set) var actionsReadError: String?
    @ObservationIgnored @MainActor lazy var workspacesRead = LatestRead()
    @ObservationIgnored @MainActor lazy var actionsRead = LatestRead()

    public init(root: URL, platform: AppConnectorStatusPlatform) {
        self.root = root
        self.platform = platform
    }

    /// Return this read's checked accounts, independently of snapshot publication.
    @discardableResult
    @MainActor public func refresh(quiet: Bool = false) async -> Result<[ConnectorRecord], Error> {
        let root = root, platform = platform
        let snapshot = await snapshotRead.read({
            await Task.detached(priority: .userInitiated) {
                let checked: Result<[ConnectorRecord], Error>
                do { checked = .success(quiet
                    ? try Self.checkedConnectorRecords(root: root, platform: platform)
                    : try await Self.readConnectorRecords(root: root, platform: platform)) }
                catch { checked = .failure(error) }
                return (checked,
                 Result { try Keyring.kept().map { (name: $0.name, hosts: $0.entry.hosts, programs: $0.entry.programs, at: $0.entry.at, account: $0.entry.account) } },
                 Result { try SlackSocketModeConfig.loadIngressPolicy(dataRoot: root) })
            }.value
        }) { snapshot in
            accounts = snapshot.0
            secrets = snapshot.1
            slackPolicy = snapshot.2
        }
        return snapshot.0
    }

    @MainActor public func observe() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [Self.connectorRegistryPath(root: root),
            ConnectorActionReceipt.receiptsPath(root: root), TransportAllowlist.slackMetadataPath(dataRoot: root)] +
            ["telegram/config.json", "research/config.json", "slack/config.json", "slack/state.json",
             "slack", "connectors/slack/save_intent.json"].map { root.appendingPathComponent($0) },
            stores: [.keyring],
            notifications: [NSApplication.didBecomeActiveNotification, .NSSystemClockDidChange, .EKEventStoreChanged]) {
            await self.refresh()
        }
    }

    @MainActor public func update(id: String, enabled: Bool) async throws -> ConnectorRecord? {
        let updated = try await Self.updateConnector(id: id, enabled: enabled, root: root, platform: platform)
        snapshotRead.write {
            accounts = accounts.map { rows in
                var rows = rows
                if let index = rows.firstIndex(where: { $0.id == updated.id }) { rows[index] = updated }
                else { rows.append(updated) }
                return rows
            }
        }
        let checked = await refresh()
        let confirmed = try checked.get().first { $0.id == updated.id }
        return confirmed?.enabled == enabled ? confirmed : nil
    }
    /// `proof`: the receipt ledger read once by a list caller; a single-row caller lets it be read here.
    public static func connectorRowWithRuntimeOverlay(
        _ row: [String: JSONValue],
        root: URL,
        platform: AppConnectorStatusPlatform,
        proof: [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)]? = nil
    ) -> [String: JSONValue] {
        guard let id = connectorString(row["id"]).map(normalizedConnectorID), !id.isEmpty else {
            return row
        }
        let proofs = proof ?? ConnectorProofLedger.latestByConnector(root: root)
        var out = row
        out["id"] = .string(id)
        // Health decay eligibility is DERIVED here, never carried in from the
        // registry file: a hand-edited row cannot claim credential proof.
        // Cleared first, stamped below only on credential-backed branches.
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

        // Configuration alone leaves health unknown; EventKit carries its read result.
        if id == "telegram" {
            do {
                if let cfg = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: root, includeDisconnected: false), !cfg.botToken.isEmpty {
                    out["enabled"] = .bool(cfg.enabled)
                    out["authState"] = .string("configured")
                    out["healthStatus"] = .string(cfg.enabled ? "unknown" : "disabled")
                } else {
                    out["enabled"] = .bool(false)
                    out["authState"] = .string("not_connected")
                    out["healthStatus"] = .string("needs_auth")
                }
            } catch {
                out["enabled"] = .bool(false)
                out["authState"] = .string("failed")
                out["healthStatus"] = .string("failed")
                out["runtimeDetail"] = .string("Its saved settings do not read (\(error.localizedDescription)). Disconnect it, then set it up again.")
            }
            return out
        }

        if id == "searxng" {
            do {
                if !(try SwiftNativeResearchClient.checkedSearxngBaseURL(root: root) ?? "").isEmpty {
                    if connectorBool(out["enabled"]) == nil { out["enabled"] = .bool(true) }
                    out["authState"] = .string("not_required")
                    out["healthStatus"] = .string("unknown")
                } else {
                    out["enabled"] = .bool(false)
                    out["authState"] = .string("not_required")
                    out["healthStatus"] = .string("needs_config")
                }
            } catch {
                out["enabled"] = .bool(false)
                out["authState"] = .string("failed")
                out["healthStatus"] = .string("failed")
                out["runtimeDetail"] = .string("Its saved settings do not read (\(error.localizedDescription)). Disconnect it, then set it up again.")
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
            out["healthStatus"] = .string("unknown")
            return out
        }

        if id == "browser" {
            out["enabled"] = .bool(true)
            out["authState"] = .string("not_required")
            out["healthStatus"] = .string("unknown")
            if connectorString(out["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                out["kind"] = .string("browser")
            }
            if connectorString(out["description"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                out["description"] = .string("Visible browser research and inspection with receipts.")
            }
            return out
        }

        if id == "slack" {
            let existingAuth = connectorString(out["authState"])?.lowercased()
            let existingHealth = connectorString(out["healthStatus"])?.lowercased()
            let token: Bool
            do {
                _ = try SlackCredentials.metadata(dataRoot: root)
                token = try SlackCredentials.read(.bot, dataRoot: root) != nil
                if token { out["enabled"] = .bool(try !SlackSocketModeConfig.socketModeSwitchedOff(dataRoot: root)) }
            } catch {
                // A credential that does not read fails this row, never as "no token"
                // and never the whole list; disconnecting clears it.
                out["enabled"] = .bool(false)
                out["authState"] = .string("failed")
                out["healthStatus"] = .string("failed")
                out["runtimeDetail"] = .string("The saved Slack credential does not read (\(error.localizedDescription)). Disconnect Slack, then connect it again.")
                return out
            }
            if token {
                markCredentialProof(&out, proof: proofs)
            } else {
                out["enabled"] = .bool(false)
                // No token: honor the honest-disconnected freeze if set; the
                // separately-owned Socket Mode feed is still surfaced below.
                if existingAuth != "connected_unverified" && existingHealth != "needs_probe" {
                    out["authState"] = .string("not_connected")
                    if existingHealth == nil || existingHealth == "ok" || existingHealth == "ready" || existingHealth == "connected" {
                        out["healthStatus"] = .string("needs_auth")
                    }
                }
            }
            applySlackRuntimeStateFeed(to: &out, root: root, platform: platform)
        }
        return out
    }

    public static func markCredentialProof(_ row: inout [String: JSONValue], proof: [String: (at: Date, succeeded: Bool, authorizationFailed: Bool)]) {
        row[ConnectorHealthDecay.proofSourceKey] =
            .string(ConnectorHealthDecay.credentialProofSource)
        let family = ConnectorProofLedger.canonicalID(connectorString(row["id"]) ?? "")
        row = ConnectorHealthDecay.apply(to: row, outcome: proof[family], now: Date())
    }

    public static func applySlackRuntimeStateFeed(
        to row: inout [String: JSONValue],
        root: URL,
        platform: AppConnectorStatusPlatform
    ) {
        switch SlackRuntimeStateFeed.read(dataRoot: root) {
        case .absent:
            row["runtimeStatus"] = .string("unobserved")
            row["runtimeDetail"] = .string("Socket Mode has not produced runtime state yet.")
            row["runtimeUpdatedAt"] = .null
        case .current(let snapshot):
            row["runtimeUpdatedAt"] = .string(snapshot.updatedAt)
            if snapshot.hasReportedError, let detail = snapshot.lastError {
                row["runtimeStatus"] = .string("degraded")
                row["runtimeDetail"] = .string("slack_runtime_error: \(detail). Inspect Slack connection status and its delivery receipts before resending.")
            } else if snapshot.connected {
                row["runtimeStatus"] = .string("connected")
                row["runtimeDetail"] = .string("Socket Mode heartbeat is current.")
            } else {
                row["runtimeStatus"] = .string("disconnected")
                row["runtimeDetail"] = .string("Socket Mode last reported a disconnected state.")
            }
        case .stale(let snapshot):
            row["runtimeStatus"] = .string("stale")
            row["runtimeDetail"] = .string(["slack_runtime_stale: Socket Mode heartbeat expired. Inspect Slack connection status before relying on delivery.", snapshot.lastError].compactMap { $0 }.joined(separator: " "))
            row["runtimeUpdatedAt"] = .string(snapshot.updatedAt)
        case .unavailable(let detail):
            row["runtimeStatus"] = .string("unavailable")
            row["runtimeDetail"] = .string("slack_runtime_state_unavailable: \(detail). Repair slack/state.json before relying on connection status.")
            row["runtimeUpdatedAt"] = .null
        }
        do {
            if let recovery = try SlackInboundDeliveryJournal.recoverySummary(dataRoot: root) {
                if recovery.isAtCapacity {
                    row["runtimeStatus"] = .string("intake_paused")
                    row["runtimeDetail"] = .string([connectorString(row["runtimeDetail"]), "\(recovery.pendingCount) pending replies; new message intake is paused. \(recovery.unknownCount) need recovery. Ask \(platform.agentSubject) to inspect Slack delivery recovery before any manual retry; nothing is automatically discarded or resent."].compactMap { $0 }.joined(separator: " "))
                } else if recovery.unknownCount > 0 {
                    row["runtimeStatus"] = .string("recovery_required")
                    row["runtimeDetail"] = .string([connectorString(row["runtimeDetail"]), "\(recovery.unknownCount) replies have an unknown outcome (\(recovery.pendingCount) pending). Ask \(platform.agentSubject) to inspect Slack delivery recovery before any manual retry; automatic resend is paused."].compactMap { $0 }.joined(separator: " "))
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
            row["runtimeDetail"] = .string([connectorString(row["runtimeDetail"]), "slack_recovery_unavailable: \(error.localizedDescription). New message intake may be paused; ask \(platform.agentSubject) to inspect Slack delivery recovery before resending."].compactMap { $0 }.joined(separator: " "))
        }
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


    public static func defaultConnectorName(_ id: String) -> String {
        switch id {
        case "searxng": return "SearXNG"
        case "local_files": return "Local File Workspaces"
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

    public static func readConnectorRecords(root: URL, platform: AppConnectorStatusPlatform) async throws -> [ConnectorRecord] {
        // Fresh install shows the blank-slate catalog instead of "0 connectors".
        try await seedDefaultConnectorsIfEmpty(root: root, platform: platform)
        let path = connectorRegistryPath(root: root)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            try checkedConnectorRecords(root: root, platform: platform)
        }
    }

    /// The checked reader behind the engine's published account revision.
    public static func checkedConnectorRecords(root: URL, platform: AppConnectorStatusPlatform) throws -> [ConnectorRecord] {
        let current = try ConnectorOAuthRegistry.readRegistry(at: connectorRegistryPath(root: root))
        // List and mutation projections use the same receipt-backed overlay.
        let proof = ConnectorProofLedger.latestByConnector(root: root)
        let rows = current.map {
            connectorRowWithRuntimeOverlay($0, root: root, platform: platform, proof: proof)
        }
        let data = try JSONValue.array(rows.map { .object($0) }).serializedData(pretty: false)
        return try JSONDecoder().decode([ConnectorRecord].self, from: data)
    }

    public static func updateConnector(
        id: String, enabled: Bool, root: URL, platform: AppConnectorStatusPlatform
    ) async throws -> ConnectorRecord {
        let row = try await ConnectorRegistryActions.updateConnector(
            id: id, enabled: enabled, root: root,
            projection: ConnectorRegistryProjectionPort(
                defaultName: defaultConnectorName,
                overlay: { connectorRowWithRuntimeOverlay($0, root: $1, platform: platform) }
            )
        )
        if normalizedConnectorID(id) == "slack" { await restartSlackLane(root: root) }
        return try JSONDecoder().decode(ConnectorRecord.self, from: row.serializedData(pretty: false))
    }

    /// The Socket Mode lane holds the tokens it was built with: every change to
    /// Slack's switch or credentials rebuilds it from what is saved now.
    static func restartSlackLane(root: URL) async {
        await BackgroundLoopLifetimes.shared.restartLoop(id: "slack_socket_mode") {
            await NativeAgentEngine.makeSlackSocketModeLane(dataRoot: root)
        }
    }

    /// Blank-slate connector catalog for an absent registry, so a fresh
    /// install shows connectable integrations (present-but-unconnected, clickable
    /// to connect). Auth-required services need auth; unchecked local health
    /// is unknown. All connection decisions are undecided; `enabled=false` is status.
    private static func defaultConnectorCatalog(isPublicReleaseBundle: Bool) -> [[String: JSONValue]] {
        func rec(_ id: String, _ name: String, _ kind: String,
                 _ auth: String, _ health: String, _ risk: String,
                 _ perms: [String], _ actions: [String], _ desc: String) -> [String: JSONValue] {
            [
                "id": .string(id), "name": .string(name), "kind": .string(kind),
                ConnectorOAuthRegistry.decisionField: ConnectorOAuthRegistry.ConnectionDecision.undecided.value,
                "authState": .string(auth), "healthStatus": .string(health),
                "riskClass": .string(risk), "enabled": .bool(false),
                "permissions": .array(perms.map { .string($0) }),
                "actions": .array(actions.map { .string($0) }),
                "description": .string(desc),
            ]
        }
        var catalog: [[String: JSONValue]] = [
            rec("browser", "Visible Browser", "browser", "not_required", "unknown", "network_read",
                ["browse", "screenshot"], ["open", "inspect", "capture"],
                "Visible browser research and inspection with receipts."),
            rec("local_files", "Local File Workspaces", "files", "not_required", "unknown", "file_access",
                ["workspace_read", "workspace_write"], ["search", "list", "read"],
                "Scoped folder access for user-approved workspaces."),
        ]
        // A2.5 (W1#10): SearXNG needs a self-hosted base URL, so on a fresh
        // public install it seeds as a `needs_config` dead end. Drop it from the
        // PUBLIC blank-slate seed (not a feature removal — the connector code,
        // overlay, and wizard all still handle it, and an existing registry that
        // already lists it is untouched since seeding only runs when absent).
        // Dev/personal builds keep the convenience seed.
        if !isPublicReleaseBundle {
            catalog.append(
                rec("searxng", "SearXNG", "research", "not_required", "unknown", "network_read",
                    ["search_web", "fetch_url"], ["search", "fetch"],
                    "Private metasearch connector for research."))
        }
        catalog.append(contentsOf: [
            rec("shortcuts", "Apple Shortcuts", "macos", "not_required", "unknown", "system_surface",
                ["run_intent"], ["run"],
                "Run Shortcuts for Desk tasks, health checks, status, and chat."),
            rec("telegram", "Telegram", "messaging", "needs_auth", "needs_auth", "external_send",
                ["send_message", "receive_message"], ["reply"],
                "Remote chat bridge through an allowlisted bot. Add a bot token in Telegram settings to connect."),
            rec("slack", "Slack", "messaging", "needs_auth", "needs_auth", "external_send",
                ["send_message", "receive_message"], ["reply"],
                "Remote chat bridge through allowlisted Slack channels and people. Add the bot and app tokens to connect."),
        ])
        return catalog
    }

    /// Only an absent registry bootstraps. Even an empty saved catalog belongs
    /// to the operator; damaged content is reported by the checked reader.
    private static func seedDefaultConnectorsIfEmpty(root: URL, platform: AppConnectorStatusPlatform) async throws {
        let path = connectorRegistryPath(root: root)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path.path)
                return
            } catch CocoaError.fileReadNoSuchFile {
                // Missing is the sole bootstrap case.
            }
            let catalog = JSONValue.array(
                defaultConnectorCatalog(isPublicReleaseBundle: platform.isPublicReleaseBundle).map { .object($0) }
            )
            try ConnectorOAuthRegistry.writeRegistry(catalog, at: path)
        }
    }
}
