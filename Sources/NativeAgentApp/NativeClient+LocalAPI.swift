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
import CapabilityFoundry

extension NativeClient {
    /// Daemon-dead local-file read helper. Reads `url` if present; otherwise
    /// decodes `fallbackJSON`. Used by the wave-P2 port batch — every method
    /// that used to hit a daemon GET route for a JSON file now reads the same
    /// file (or its sibling on the new schema) directly off disk.
    static func readLocalJSON<T: Decodable>(_ url: URL, fallbackJSON: String) throws -> T {
        let data: Data
        if FileManager.default.fileExists(atPath: url.path),
           let read = try? Data(contentsOf: url) {
            data = read
        } else {
            data = Data(fallbackJSON.utf8)
        }
        return try JSONDecoder.nativeAgent.decode(T.self, from: data)
    }

    static func readJSONObject(at path: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func readAutoDoctorConfig(dataRoot: URL) -> AutoDoctorConfig {
        let path = dataRoot
            .appendingPathComponent("auto_doctor", isDirectory: true)
            .appendingPathComponent("config.json")
        let object = readJSONObject(at: path)
        var config = AutoDoctorConfig()
        config.enabled = boolValue(object["enabled"])
        config.runOnStartup = boolValue(object["run_on_startup"])
        config.intervalSeconds = intValue(object["interval_seconds"])
        config.usesModelCalls = boolValue(object["uses_model_calls"])
        config.checkLLM = boolValue(object["check_llm"])
        return config
    }

    static func readModelRoutingConfig(dataRoot: URL) -> ModelRoutingConfig {
        let defaultModel = nativeAgentPrimaryModel
        let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let surfaces = readJSONObject(at: providersDir.appendingPathComponent("surfaces.json"))
        let activeRaw = readJSONObject(at: providersDir.appendingPathComponent("active.json"))
        var active: [String: String] = [:]
        for (surface, value) in activeRaw {
            if let provider = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !provider.isEmpty {
                active[surface] = provider
            }
        }

        var surfacePrefs: [String: ModelSurfacePreference] = [:]
        for surface in Set(surfaces.keys).union(active.keys).sorted() {
            let raw = surfaces[surface]
            var model: String?
            var effort: String?
            var serviceTier: String?
            if let entry = raw as? [String: Any] {
                model = stringValue(entry["model"])
                effort = stringValue(entry["reasoningEffort"]) ?? stringValue(entry["reasoning_effort"])
                serviceTier = stringValue(entry["serviceTier"]) ?? stringValue(entry["service_tier"])
            } else {
                model = stringValue(raw)
            }
            let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (trimmedModel?.isEmpty == false) ? trimmedModel! : defaultModel
            let resolvedEffort = (trimmedEffort?.isEmpty == false) ? trimmedEffort! : "medium"
            surfacePrefs[surface] = ModelSurfacePreference(
                surface: surface,
                model: resolvedModel,
                reasoningEffort: resolvedEffort,
                serviceTier: serviceTier == "priority" ? "priority" : "default",
                source: active[surface],
                modelKnown: nil
            )
        }

        func pref(_ surface: String) -> ModelSurfacePreference {
            surfacePrefs[surface] ?? ModelSurfacePreference(
                surface: surface,
                model: defaultModel,
                reasoningEffort: "medium",
                serviceTier: "default",
                source: active[surface],
                modelKnown: nil
            )
        }
        let efforts = [
            ReasoningEffortOption(id: "none", label: "None", description: nil),
            ReasoningEffortOption(id: "low", label: "Low", description: nil),
            ReasoningEffortOption(id: "medium", label: "Medium", description: nil),
            ReasoningEffortOption(id: "high", label: "High", description: nil),
            ReasoningEffortOption(id: "xhigh", label: "XHigh", description: nil),
            ReasoningEffortOption(id: "max", label: "Max", description: nil),
            ReasoningEffortOption(id: "ultra", label: "Ultra", description: nil)
        ]
        let current = ModelRoutingCurrent(
            chat: pref("chat"),
            telegram: pref("telegram"),
            ios: surfacePrefs["ios"],
            executions: surfacePrefs["missions"],
            autonomy: surfacePrefs["autonomy"],
            swarms: surfacePrefs["swarms"],
            dream: surfacePrefs["dream"],
            training: surfacePrefs["training"]
        )
        return ModelRoutingConfig(
            status: "ok",
            defaultModel: defaultModel,
            fallbackModels: ["claude-sonnet-5"],
            reasoningEfforts: efforts,
            current: current
        )
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
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
                "System automation surface for Workshop tasks, Doctor, status, and chat."),
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

    /// Seed the default catalog ONLY when the registry has zero rows (fresh
    /// install, or a deleted registry). Idempotent — never clobbers an existing
    /// registry, so a real user's connected state is preserved.
    static func seedDefaultConnectorsIfEmpty(root: URL) async {
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        _ = try? await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .array([]))
            // Use connectorRows so an older OBJECT-shaped registry (also valid)
            // isn't mistaken for empty and clobbered — only a truly empty
            // registry gets seeded.
            if !connectorRows(from: current).isEmpty { return }
            let catalog = JSONValue.array(defaultConnectorCatalog().map { .object($0) })
            try? await persistence.writeJSON(catalog, to: path)
        }
    }

    static func readConnectorRecords(root: URL) async throws -> [ConnectorRecord] {
        // Fresh install shows the blank-slate catalog instead of "0 connectors".
        await seedDefaultConnectorsIfEmpty(root: root)
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        let current = try await persistence.withFileLock(path) {
            await persistence.readJSON(path, defaultValue: .array([]))
        }
        let rows = connectorRows(from: current)
            .map { connectorRowWithRuntimeOverlay($0, root: root) }
        let data = try JSONValue.array(rows.map { .object($0) }).serializedData(pretty: false)
        return try decodeLossyArray(data, context: "getConnectors(swift registry)")
    }

    // W-H CutoverSeams-band lift (move-only): fileprivate→internal so the
    // relocated seam wrappers (NativeClient+CutoverSeams.swift) still reach it.
    static func readConnectorRegistryEntry(
        root: URL,
        provider: String
    ) async throws -> [String: JSONValue]? {
        let providerID = normalizedConnectorID(provider)
        guard !providerID.isEmpty else { return nil }
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        let current = try await persistence.withFileLock(path) {
            await persistence.readJSON(path, defaultValue: .array([]))
        }
        return connectorRows(from: current)
            .first { connectorRow($0, matches: providerID) }
    }

    // W-H CutoverSeams-band lift (move-only): fileprivate→internal so the
    // relocated seam wrappers (NativeClient+CutoverSeams.swift) still reach it.
    static func mutateConnectorRegistryEntry(
        root: URL,
        provider: String,
        createIfMissing: Bool,
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> Void
    ) async throws -> [String: JSONValue] {
        let providerID = normalizedConnectorID(provider)
        guard !providerID.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "Connector provider id is empty"
            ])
        }
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .array([]))
            switch current {
            case .array(var rows):
                for idx in rows.indices {
                    guard case .object(var entry) = rows[idx],
                          connectorRow(entry, matches: providerID)
                    else { continue }
                    entry["id"] = .string(providerID)
                    mutate(&entry)
                    rows[idx] = .object(entry)
                    try await persistence.writeJSON(.array(rows), to: path)
                    return entry
                }
                guard createIfMissing else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                        NSLocalizedDescriptionKey: "Connector \(providerID) not found in \(path.path)"
                    ])
                }
                var entry: [String: JSONValue] = ["id": .string(providerID)]
                mutate(&entry)
                rows.append(.object(entry))
                try await persistence.writeJSON(.array(rows), to: path)
                return entry
            case .object(var object):
                var entry: [String: JSONValue]
                if case .object(let existing)? = object[providerID] {
                    entry = existing
                } else if let matchedKey = object.keys.first(where: { $0.lowercased() == providerID }),
                          case .object(let existing)? = object[matchedKey] {
                    entry = existing
                    object.removeValue(forKey: matchedKey)
                } else {
                    guard createIfMissing else {
                        throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                            NSLocalizedDescriptionKey: "Connector \(providerID) not found in \(path.path)"
                        ])
                    }
                    entry = [:]
                }
                entry["id"] = .string(providerID)
                mutate(&entry)
                object[providerID] = .object(entry)
                try await persistence.writeJSON(.object(object), to: path)
                return entry
            default:
                guard createIfMissing else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                        NSLocalizedDescriptionKey: "Connector \(providerID) not found in \(path.path)"
                    ])
                }
                var entry: [String: JSONValue] = ["id": .string(providerID)]
                mutate(&entry)
                try await persistence.writeJSON(.array([.object(entry)]), to: path)
                return entry
            }
        }
    }

    // W-H RegistryMutations-band lift (move-only): fileprivate->internal.
    static func connectorRowWithRuntimeOverlay(
        _ row: [String: JSONValue],
        root: URL
    ) -> [String: JSONValue] {
        guard let id = connectorString(row["id"]).map(normalizedConnectorID), !id.isEmpty else {
            return row
        }
        var out = row
        out["id"] = .string(id)
        if connectorString(out["name"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            out["name"] = .string(defaultConnectorName(id))
        }
        if connectorString(out["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            out["kind"] = .string("connector")
        }
        if connectorString(out["description"]) == nil {
            out["description"] = .string("")
        }

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
            switch calendarEventKitReadState() {
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
                out["enabled"] = .bool(true)
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
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
                out["enabled"] = .bool(true)
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
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
            let token = root.appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: token.path) {
                // A token on disk is hard proof of a real connection;
                // promote regardless of a stale needs_probe / unverified flag.
                out["authState"] = .string("connected")
                out["healthStatus"] = .string("ok")
            } else {
                // No token: honor the honest-disconnected freeze if set.
                if existingAuth == "connected_unverified" || existingHealth == "needs_probe" {
                    return out
                }
                out["authState"] = .string("not_connected")
                if existingHealth == nil || existingHealth == "ok" || existingHealth == "ready" || existingHealth == "connected" {
                    out["healthStatus"] = .string("needs_auth")
                }
            }
        }
        return out
    }

    /// Registry connector id → (client-id env var, OAuth-flow canonical id,
    /// setup note). The `oauthId` matches `connectorTokenPath`'s
    /// directory (`connectors/<oauthId>/auth.json`) and the wizard's
    /// `ConnectorWizardSetupRoute` mapping, so the overlay, the OAuth flow, and
    /// the wizard all agree on one id per connector. Client ids may come from
    /// the environment or the public connector wizard's owner-only local file.
    static let pkceOAuthConnectors:
        [String: (clientIdEnv: String, oauthId: String, setupNote: String)] = [
        "gmail": ("NATIVE_AGENT_GMAIL_CLIENT_ID", "gmail",
                  "Search and read Gmail through an operator-configured Google OAuth app."),
        "gcal": ("NATIVE_AGENT_CALENDAR_CLIENT_ID", "calendar",
                 "Read Google Calendar through an operator-configured Google OAuth app."),
        "x": ("NATIVE_AGENT_X_CLIENT_ID", "x",
              "Use the X tools through an operator-configured X OAuth app."),
    ]

    /// True when a completed OAuth token exists for `oauthId`, at EITHER the
    /// PKCE flow's write path (`connectors/<oauthId>/auth.json`) or the legacy/
    /// mirror path (`oauth_tokens/<oauthId>.json`, e.g. the X executor mirror).
    /// A non-empty access token is required; an empty or malformed file cannot
    /// impersonate a connected account.
    static func oauthConnectorTokenExists(oauthId: String, root: URL) -> Bool {
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

    static func oauthConnectorAppExists(
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
        root.appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("registry.json")
    }

    static func connectorRows(from value: JSONValue) -> [[String: JSONValue]] {
        switch value {
        case .array(let rows):
            return rows.compactMap {
                guard case .object(let object) = $0 else { return nil }
                return object
            }
        case .object(let object):
            return object.keys.sorted().compactMap { key in
                guard case .object(var entry)? = object[key] else { return nil }
                if connectorString(entry["id"]) == nil {
                    entry["id"] = .string(normalizedConnectorID(key))
                }
                return entry
            }
        default:
            return []
        }
    }

    static func connectorRow(_ row: [String: JSONValue], matches providerID: String) -> Bool {
        guard let id = connectorString(row["id"]) else { return false }
        return normalizedConnectorID(id) == providerID
    }

    // W-H RegistryMutations-band lift (move-only): private->internal.
    static func normalizedConnectorID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func connectorString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value { return string }
        return nil
    }

    static func connectorBool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if case .bool(let bool) = value { return bool }
        return nil
    }

    static func searxngBaseURL(root: URL) -> String {
        let path = root.appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["searxng_base_url"] as? String
        else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultConnectorName(_ id: String) -> String {
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
}
