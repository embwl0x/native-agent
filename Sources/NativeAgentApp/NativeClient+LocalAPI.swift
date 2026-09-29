import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import SlackBot
import GitHubConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

extension NativeClient {
    /// Daemon-dead local-file read helper. Reads `url` if present; otherwise
    /// decodes `fallbackJSON`. Used by the wave-P2 port batch — every method
    /// that used to hit a daemon GET route for a JSON file now reads the same
    /// file (or its sibling on the new schema) directly off disk.
    static func readLocalJSON<T: Decodable>(_ url: URL, fallbackJSON: String) throws -> T {
        try RuntimeReadProjection.readLocalJSON(url, fallbackJSON: fallbackJSON)
    }

    static func readJSONObject(at path: URL) -> [String: Any] {
        ProvidersFacade.readJSONObject(at: path)
    }

    static func readAutoDoctorConfig(dataRoot: URL) -> AutoDoctorConfig {
        DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
    }

    static func readModelRoutingConfig(dataRoot: URL) -> ModelRoutingConfig {
        ProvidersFacade.readModelRoutingConfig(dataRoot: dataRoot)
    }

    static func stringValue(_ value: Any?) -> String? {
        ProvidersFacade.stringValue(value)
    }

    static func boolValue(_ value: Any?) -> Bool? {
        DoctorStatusProjection.boolValue(value)
    }

    static func intValue(_ value: Any?) -> Int? {
        DoctorStatusProjection.intValue(value)
    }

    /// Blank-slate connector catalog seeded into an EMPTY registry so a fresh
    /// install shows connectable integrations (present-but-unconnected, clickable
    /// to connect) and the agent can see what it could connect to — instead of
    /// "0 connectors". Auth-required services land as `needs_auth` (→ a "Connect"
    /// button); local/no-auth ones as `ready`. All `enabled=false`.
    static func defaultConnectorCatalog() -> [[String: JSONValue]] {
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
        if !NativeAgentPaths.isPublicReleaseBundle {
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
    static func seedDefaultConnectorsIfEmpty(root: URL) async {
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        _ = try? await persistence.withFileLock(path) {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path.path)
                return
            } catch CocoaError.fileReadNoSuchFile {
                // Missing is the sole bootstrap case.
            }
            let catalog = JSONValue.array(defaultConnectorCatalog().map { .object($0) })
            try await persistence.writeJSON(catalog, to: path)
        }
    }

    static func readConnectorRecords(root: URL) async throws -> [ConnectorRecord] {
        try await ConnectorStatusProjection.readConnectorRecords(root: root, platform: NativeClientStatusPlatform(), seedDefaults: { await Self.seedDefaultConnectorsIfEmpty(root: root) })
    }

    static func readConnectorRegistryEntry(
        root: URL,
        provider: String
    ) async throws -> [String: JSONValue]? {
        try await ConnectorOAuthRegistry.readConnectorRegistryEntry(root: root, provider: provider)
    }

    static func mutateConnectorRegistryEntry(
        root: URL, provider: String, createIfMissing: Bool,
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> Void
    ) async throws -> [String: JSONValue] {
        try await ConnectorOAuthRegistry.mutateConnectorRegistryEntry(
            root: root, provider: provider, createIfMissing: createIfMissing, mutate: mutate
        )
    }

    static func connectorRowWithRuntimeOverlay(
        _ row: [String: JSONValue],
        root: URL
    ) -> [String: JSONValue] {
        ConnectorStatusProjection.connectorRowWithRuntimeOverlay(row, root: root, platform: NativeClientStatusPlatform())
    }

    /// Stamp the decay-eligibility bit on a row whose green was just derived
    /// from a token/credential being present on disk. `ConnectorHealthDecay`
    /// decays exactly these rows and leaves every other green alone.


    /// Keep credential readiness and Socket Mode evidence separate. Slack can
    /// post with a valid bot token while inbound Socket Mode has not started;
    /// conversely, a stale runtime feed must be displayed as stale rather than
    /// silently changing the credential claim to disconnected.


    /// Registry connector id → (client-id env var, OAuth-flow canonical id,
    /// setup note). The `oauthId` matches `connectorTokenPath`'s
    /// directory (`connectors/<oauthId>/auth.json`) and the wizard's
    /// `ConnectorWizardSetupRoute` mapping, so the overlay, the OAuth flow, and
    /// the wizard all agree on one id per connector. Client ids may come from
    /// the environment or the public connector wizard's owner-only local file.
    static let pkceOAuthConnectors = ConnectorStatusProjection.pkceOAuthConnectors

    /// True when a completed OAuth token exists for `oauthId`, at EITHER the
    /// PKCE flow's write path (`connectors/<oauthId>/auth.json`) or the legacy/
    /// mirror path (`oauth_tokens/<oauthId>.json`, e.g. the X executor mirror).
    /// A non-empty access token is required; an empty or malformed file cannot
    /// impersonate a connected account.
    static func oauthConnectorTokenExists(oauthId: String, root: URL) -> Bool {
        ConnectorStatusProjection.oauthConnectorTokenExists(oauthId: oauthId, root: root)
    }

    static func oauthConnectorAppExists(
        oauthId: String,
        clientIdEnv: String,
        root: URL
    ) -> Bool {
        ConnectorStatusProjection.oauthConnectorAppExists(oauthId: oauthId, clientIdEnv: clientIdEnv, root: root)
    }

    static func calendarEventKitReadState() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return "ready"
        case .notDetermined:
            return "probe_needed"
        case .writeOnly, .denied, .restricted:
            return "needs_permission"
        @unknown default:
            return "unknown"
        }
    }

    static func connectorRegistryPath(root: URL) -> URL {
        ConnectorOAuthRegistry.connectorRegistryPath(root: root)
    }

    static func connectorRows(from value: JSONValue) -> [[String: JSONValue]] {
        ConnectorStatusProjection.connectorRows(from: value)
    }

    static func connectorRow(_ row: [String: JSONValue], matches providerID: String) -> Bool {
        ConnectorOAuthRegistry.connectorRow(row, matches: providerID)
    }

    static func normalizedConnectorID(_ raw: String) -> String {
        ConnectorOAuthRegistry.normalizedConnectorID(raw)
    }

    static func connectorString(_ value: JSONValue?) -> String? {
        ConnectorOAuthRegistry.connectorString(value)
    }

    static func connectorBool(_ value: JSONValue?) -> Bool? {
        ConnectorStatusProjection.connectorBool(value)
    }

    static func searxngBaseURL(root: URL) -> String {
        ConnectorStatusProjection.searxngBaseURL(root: root)
    }

    static func defaultConnectorName(_ id: String) -> String {
        ConnectorStatusProjection.defaultConnectorName(id)
    }
}
