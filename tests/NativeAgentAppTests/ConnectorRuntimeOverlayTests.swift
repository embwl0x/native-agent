import Foundation
import GitHubConnector
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private func makeConnectorOverlayTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConnectorRuntimeOverlayTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test
func tokenBackedConnectorWithTokenPromotesStaleNeedsProbeState() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let tokenDir = root.appendingPathComponent("oauth_tokens", isDirectory: true)
    try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
    try Data(#"{"access_token":"test-token"}"#.utf8)
        .write(to: tokenDir.appendingPathComponent("x.json"), options: .atomic)

    let row: [String: JSONValue] = [
        "id": .string("x"),
        "name": .string("X"),
        "kind": .string("social"),
        "enabled": .bool(true),
        "authState": .string("connected_unverified"),
        "healthStatus": .string("needs_probe"),
    ]

    let overlay = NativeClient.connectorRowWithRuntimeOverlay(row, root: root)

    #expect(overlay["authState"] == .string("connected"))
    #expect(overlay["healthStatus"] == .string("ok"))
    #expect(overlay["enabled"] == .bool(true))
}

@Test
func tokenBackedConnectorWithoutTokenPreservesNeedsProbeState() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let row: [String: JSONValue] = [
        "id": .string("x"),
        "name": .string("X"),
        "kind": .string("social"),
        "enabled": .bool(true),
        "authState": .string("connected_unverified"),
        "healthStatus": .string("needs_probe"),
    ]

    let overlay = NativeClient.connectorRowWithRuntimeOverlay(row, root: root)

    #expect(overlay["authState"] == .string("connected_unverified"))
    #expect(overlay["healthStatus"] == .string("needs_probe"))
    #expect(overlay["enabled"] == .bool(true))
}

@Test
func slackTokenPasteSavesLegacyAndConnectorAuthFiles() async throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let token = "xoxb-" + String(repeating: "a", count: 32)
    let result = await NativeOAuthFlow.saveSlackToken(
        token,
        validateWithSlack: false,
        dataRoot: root
    )

    #expect(result.ok)

    let legacyPath = root
        .appendingPathComponent("oauth_tokens", isDirectory: true)
        .appendingPathComponent("slack.json")
    let connectorPath = root
        .appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("slack", isDirectory: true)
        .appendingPathComponent("auth.json")

    let legacy = try JSONValue.parse(Data(contentsOf: legacyPath))
    let connector = try JSONValue.parse(Data(contentsOf: connectorPath))
    #expect(stringField(legacy, "access_token") == token)
    #expect(stringField(connector, "access_token") == token)
    #expect(stringField(legacy, "auth_mode") == "manual_oauth_token")
    #expect(stringField(connector, "auth_mode") == "manual_oauth_token")

    let row = try await #require(NativeClient.readConnectorRegistryEntry(root: root, provider: "slack"))
    #expect(row["enabled"] == .bool(true))
    #expect(row["registered"] == .bool(true))
    #expect(row["authState"] == .string("connected"))
    #expect(row["healthStatus"] == .string("ok"))
}

// MARK: - A2.3 OAuth connector id-consistency (W1#8) + coming_soon (W1#5)

/// A completed Gmail sign-in lands at `connectors/gmail/auth.json`; the overlay
/// must reflect the REGISTRY id "gmail" as connected. Before the fix the token
/// set keyed on "email", so a real Gmail auth could never surface.
@Test
func gmailRegistryIdReflectsConnectedFromItsOAuthTokenPath() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("connectors/gmail", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"access_token":"test-token"}"#.utf8)
        .write(to: dir.appendingPathComponent("auth.json"), options: .atomic)

    let overlay = NativeClient.connectorRowWithRuntimeOverlay(["id": .string("gmail")], root: root)
    #expect(overlay["authState"] == .string("connected"))
    #expect(overlay["healthStatus"] == .string("ok"))
}

/// Google Calendar seeds as "gcal" but its OAuth flow's canonical id is
/// "calendar" (token at `connectors/calendar/auth.json`). The overlay must
/// bridge gcal→calendar or a connected calendar can never show. Pins the map.
@Test
func gcalRegistryIdReflectsConnectedFromCalendarOAuthTokenPath() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("connectors/calendar", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"access_token":"test-token"}"#.utf8)
        .write(to: dir.appendingPathComponent("auth.json"), options: .atomic)

    let overlay = NativeClient.connectorRowWithRuntimeOverlay(["id": .string("gcal")], root: root)
    #expect(overlay["authState"] == .string("connected"))
    #expect(overlay["healthStatus"] == .string("ok"))
}

/// A public install without an OAuth app configured is connectable rather than
/// falsely advertised as unfinished. The wizard collects the app credentials.
@Test
func oauthConnectorWithoutClientIdOrTokenNeedsAuthentication() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = ProcessInfo.processInfo.environment["NATIVE_AGENT_GMAIL_CLIENT_ID"]
    unsetenv("NATIVE_AGENT_GMAIL_CLIENT_ID")
    defer { if let saved { setenv("NATIVE_AGENT_GMAIL_CLIENT_ID", saved, 1) } }

    let overlay = NativeClient.connectorRowWithRuntimeOverlay(["id": .string("gmail")], root: root)
    #expect(overlay["authState"] == .string("not_connected"))
    #expect(overlay["healthStatus"] == .string("needs_auth"))
    #expect(overlay["enabled"] == .bool(false))
}

@Test
func notionWithoutTokenNeedsAuthentication() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let overlay = NativeClient.connectorRowWithRuntimeOverlay([
        "id": .string("notion"),
        "enabled": .bool(true),
        "authState": .string("connected"),
        "healthStatus": .string("ok"),
    ], root: root)

    #expect(overlay["enabled"] == .bool(false))
    #expect(overlay["authState"] == .string("not_connected"))
    #expect(overlay["healthStatus"] == .string("needs_auth"))
}

@Test
func malformedTokenFileCannotImpersonateConnectedCredential() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("connectors/notion", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("auth.json"), options: .atomic)

    let overlay = NativeClient.connectorRowWithRuntimeOverlay([
        "id": .string("notion"),
        "enabled": .bool(true),
        "authState": .string("connected"),
        "healthStatus": .string("ok"),
    ], root: root)

    #expect(overlay["enabled"] == .bool(false))
    #expect(overlay["authState"] == .string("not_connected"))
    #expect(overlay["healthStatus"] == .string("needs_auth"))
}

@Test
func savedOAuthAppCredentialsAreResolvedWithoutEnvironmentConfiguration() async throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = ProcessInfo.processInfo.environment["NATIVE_AGENT_GMAIL_CLIENT_ID"]
    unsetenv("NATIVE_AGENT_GMAIL_CLIENT_ID")
    defer { if let saved { setenv("NATIVE_AGENT_GMAIL_CLIENT_ID", saved, 1) } }

    let result = await NativeOAuthFlow.saveConnectorOAuthApp(
        connectorId: "gmail",
        clientId: "public-install-client-id",
        clientSecret: "",
        dataRoot: root
    )
    #expect(result.ok)
    #expect(
        NativeOAuthFlow.connectorOAuthAppCredentials(
            connectorId: "gmail",
            dataRoot: root
        ) == ConnectorOAuthAppCredentials(
            clientId: "public-install-client-id",
            clientSecret: nil
        )
    )
    let attributes = try FileManager.default.attributesOfItem(
        atPath: NativeOAuthFlow.connectorOAuthAppPath(
            connectorId: "gmail",
            dataRoot: root
        ).path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test
func notionTokenSaveCreatesCanonicalCredentialAndConnectedOverlay() async throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let token = "secret_" + String(repeating: "a", count: 32)

    let result = await NativeOAuthFlow.saveNotionToken(
        token,
        validate: false,
        dataRoot: root
    )
    #expect(result.ok)

    let authPath = root.appendingPathComponent("connectors/notion/auth.json")
    let auth = try JSONValue.parse(Data(contentsOf: authPath))
    #expect(stringField(auth, "access_token") == token)
    let attributes = try FileManager.default.attributesOfItem(atPath: authPath.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let overlay = NativeClient.connectorRowWithRuntimeOverlay(
        ["id": .string("notion")],
        root: root
    )
    #expect(overlay["enabled"] == .bool(true))
    #expect(overlay["authState"] == .string("connected"))
    #expect(overlay["healthStatus"] == .string("ok"))
}

@Test
func githubKeychainMetadataPreservesConnectedPresentation() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = GitHubCredentialStore.metadataPaths(dataRoot: root)[0]
    try FileManager.default.createDirectory(
        at: metadata.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(#"{"credential_store":"macos_keychain","validated_at":"2026-07-26T00:00:00Z"}"#.utf8)
        .write(to: metadata, options: .atomic)

    let overlay = NativeClient.connectorRowWithRuntimeOverlay([
        "id": .string("github"),
        "enabled": .bool(true),
        "authState": .string("connected"),
        "healthStatus": .string("ok"),
    ], root: root)

    #expect(overlay["enabled"] == .bool(true))
    #expect(overlay["authState"] == .string("connected"))
    #expect(overlay["healthStatus"] == .string("ok"))
}

@Test
func malformedGitHubMetadataCannotImpersonateConnectedCredential() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = GitHubCredentialStore.metadataPaths(dataRoot: root)[0]
    try FileManager.default.createDirectory(
        at: metadata.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not-json".utf8).write(to: metadata, options: .atomic)

    let overlay = NativeClient.connectorRowWithRuntimeOverlay([
        "id": .string("github"),
        "enabled": .bool(true),
        "authState": .string("connected"),
        "healthStatus": .string("ok"),
    ], root: root)

    #expect(overlay["enabled"] == .bool(false))
    #expect(overlay["authState"] == .string("not_connected"))
    #expect(overlay["healthStatus"] == .string("needs_auth"))
}

@Test
func builtInShortcutsRowCannotAppearDisabledFromStaleRegistryState() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let overlay = NativeClient.connectorRowWithRuntimeOverlay([
        "id": .string("shortcuts"),
        "enabled": .bool(false),
    ], root: root)

    #expect(overlay["enabled"] == .bool(true))
    #expect(overlay["authState"] == .string("not_required"))
    #expect(overlay["healthStatus"] == .string("ready"))
}

/// Id-consistency invariant across registry seed ↔ wizard route ↔ overlay:
/// every seeded connector that routes to native OAuth must, when its token
/// exists at the wizard's canonical path, reflect connected in the overlay
/// keyed by its REGISTRY id. This is the regression that let gmail/gcal rot.
@Test
func everySeededOAuthConnectorReflectsConnectedByItsRegistryId() throws {
    let root = try makeConnectorOverlayTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    var checkedOAuthConnectors = 0
    for record in NativeClient.defaultConnectorCatalog() {
        guard case .string(let id)? = record["id"] else { continue }
        guard case .nativeOAuth(let oauthId) = ConnectorWizardSetupRoute.resolve(provider: id) else {
            continue
        }
        checkedOAuthConnectors += 1
        let dir = root.appendingPathComponent("connectors/\(oauthId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"access_token":"test-token"}"#.utf8)
            .write(to: dir.appendingPathComponent("auth.json"), options: .atomic)

        let overlay = NativeClient.connectorRowWithRuntimeOverlay(["id": .string(id)], root: root)
        #expect(
            overlay["authState"] == .string("connected"),
            "registry connector '\(id)' (oauth '\(oauthId)') must reflect connected")
    }
    // Guard against the test silently checking nothing if the seed changes.
    #expect(checkedOAuthConnectors >= 3)
}

private func stringField(_ value: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = value,
          case .string(let string)? = obj[key] else {
        return nil
    }
    return string
}
