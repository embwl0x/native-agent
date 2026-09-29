import Foundation
import ProviderRouting
import PersistenceCore
import TrustCenter
import ChatOrchestration

public struct ConnectorRegistrationStatus: Codable, Sendable {
    public var registered: Bool
    public var registeredAt: String?
    public var clientIdPresent: Bool

    enum CodingKeys: String, CodingKey {
        case registered
        case registeredAt = "registered_at"
        case clientIdPresent = "client_id_present"
    }
}

public struct ConnectorRegisterAppResponse: Codable, Sendable {
    public var provider: String?
    public var programmatic: Bool?
    public var approvalUrl: String?
    public var callbackPath: String?
    public var portalUrl: String?
    public var note: String?
    public var reason: String?
    public var nextSteps: [String]?

    enum CodingKeys: String, CodingKey {
        case provider, note, reason
        case programmatic
        case approvalUrl = "approval_url"
        case callbackPath = "callback_path"
        case portalUrl = "portal_url"
        case nextSteps = "next_steps"
    }
}

public enum ConnectorWizardSetupRoute: Equatable, Sendable {
    case manualToken
    case notionToken
    case nativeOAuth(connectorId: String)
    case unavailable

    /// One table, in `InlineInteractionRegistry`. The wizard and the inline
    /// card must never disagree about how an account is connected: a card that
    /// offers "Sign in with GitHub" while the wizard wants a pasted token is a
    /// lie the person only discovers after tapping. The registry answers which
    /// route applies; the two token routes stay distinct here because Notion's
    /// paste screen is its own.
    public static func resolve(provider: String) -> Self {
        let canonical = InlineInteractionRegistry.canonicalConnectorID(provider)
        switch InlineInteractionRegistry.connectorSetup(for: canonical) {
        case .manualToken:
            // Telegram has no wizard page; only the three token pastes below.
            switch canonical {
            case "notion": return .notionToken
            case "slack", "github": return .manualToken
            default: return .unavailable
            }
        case .oauth:
            // The OAuth store spells Google Calendar `calendar`, while the
            // connector registry spells it `gcal`.
            return .nativeOAuth(connectorId: canonical == "gcal" ? "calendar" : canonical)
        case .unavailable:
            return .unavailable
        }
    }
}

public enum ConnectorWizardActions {
    // --- Connector wizard ---------------------------------------------------
    // DAEMON-DEAD PORT (2026-06-02): registry decode of
    // <dataRoot>/connectors/registry.json. Missing entry → not-registered.
    public static func getConnectorRegistrationStatus(provider: String) async throws -> ConnectorRegistrationStatus {
        let root = PersistenceCore.defaultDataRoot()
        let entry = try await ConnectorOAuthRegistry.readConnectorRegistryEntry(root: root, provider: provider)
        if case .nativeOAuth(let connectorId) =
            ConnectorWizardSetupRoute.resolve(provider: provider),
           NativeOAuthFlow.connectorOAuthAppCredentials(
               connectorId: connectorId,
               dataRoot: root
           ) != nil {
            return ConnectorRegistrationStatus(
                registered: true,
                registeredAt: nil,
                clientIdPresent: true
            )
        }
        if let entry {
            let registered: Bool = {
                if case .bool(let b)? = entry["registered"] { return b }
                return false
            }()
            let registeredAt: String? = {
                if case .string(let s)? = entry["registered_at"] { return s }
                if case .string(let s)? = entry["registeredAt"] { return s }
                return nil
            }()
            let clientIdPresent: Bool = {
                if case .bool(let b)? = entry["client_id_present"] { return b }
                if case .bool(let b)? = entry["clientIdPresent"] { return b }
                return false
            }()
            return ConnectorRegistrationStatus(
                registered: registered,
                registeredAt: registeredAt,
                clientIdPresent: clientIdPresent
            )
        }
        return ConnectorRegistrationStatus(registered: false, registeredAt: nil, clientIdPresent: false)
    }

    // DAEMON-DEAD PORT (2026-06-02): in-process register-app is non-programmatic
    // — the real OAuth client_id provisioning lived in the daemon's per-provider
    // portal flow. Mark the connector entry registered in
    // <dataRoot>/connectors/registry.json so the wizard can advance, and return
    // an envelope that surfaces the per-provider portal URL the user must visit
    // manually.
    public static func registerConnectorApp(provider: String) async throws -> ConnectorRegisterAppResponse {
        let now = SwiftNativeManifestSigner.isoTimestamp(Date())
        _ = try await ConnectorOAuthRegistry.mutateConnectorRegistryEntry(
            root: PersistenceCore.defaultDataRoot(),
            provider: provider,
            createIfMissing: true
        ) { entry in
            entry["registered"] = .bool(true)
            entry["registered_at"] = .string(now)
            entry["registeredAt"] = .string(now)
        }
        let portal: String? = {
            switch provider.lowercased() {
            case "google", "gmail", "email", "calendar", "gcal",
                 "googlecalendar", "google_calendar", "googledrive":
                return "https://console.cloud.google.com/apis/credentials"
            case "x", "twitter": return "https://developer.x.com/en/portal/dashboard"
            case "linear": return "https://linear.app/settings/api/applications/new"
            case "github": return "https://github.com/settings/applications/new"
            case "slack": return "https://api.slack.com/apps"
            default: return nil
            }
        }()
        return ConnectorRegisterAppResponse(
            provider: provider,
            programmatic: false,
            approvalUrl: nil,
            callbackPath: nil,
            portalUrl: portal,
            note: "Create an OAuth app at the provider portal, then save its client credentials in this wizard.",
            reason: nil,
            nextSteps: portal.map {
                [
                    "Open \($0)",
                    "Create an OAuth client with the redirect URI shown here",
                    "Paste the client ID and optional secret below",
                ]
            }
        )
    }

}

extension ConnectorOAuthRegistry {
    public static func connectorRows(from value: JSONValue) -> [[String: JSONValue]] {
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

    public static func readConnectorRegistryEntry(
        root: URL,
        provider: String
    ) async throws -> [String: JSONValue]? {
        let providerID = normalizedConnectorID(provider)
        guard !providerID.isEmpty else { return nil }
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        let current = try await persistence.withFileLock(path) {
            try readRegistry(at: path)
        }
        return try checkedConnectorRows(from: current)
            .first { connectorRow($0, matches: providerID) }
    }
}
