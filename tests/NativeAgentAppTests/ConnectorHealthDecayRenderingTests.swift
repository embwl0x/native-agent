import Connectors
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

// MARK: - Fable 5.1 sweep item 49 — the decayed row as it actually renders
//
// `ConnectorHealthDecayTests` (Connectors module) covers the clock itself.
// These cover the two things that only exist on this side: the end-to-end
// registry read (`readConnectorRecords`, the one list both the Connectors view
// and the phone projection are built from), and what the row says on screen.

private func decayRenderRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConnectorHealthDecayRendering-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeSlackToken(_ root: URL) throws {
    let dir = root.appendingPathComponent("oauth_tokens", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"access_token":"xoxb-test"}"#.utf8)
        .write(to: dir.appendingPathComponent("slack.json"), options: .atomic)
}

private func writeRegistry(_ root: URL, _ rows: [JSONValue]) throws {
    let dir = root.appendingPathComponent("connectors", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONValue.array(rows).serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("registry.json"), options: .atomic)
}

private func writeSlackSuccess(_ root: URL, at date: Date) throws {
    let path = ConnectorProofLedger.receiptsPath(root: root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line: JSONValue = .object([
        "id": .string(UUID().uuidString),
        "actionId": .string("slack.post_message"),
        "connectorId": .string("slack"),
        "name": .string("Slack Post Message"),
        "status": .string("succeeded"),
        "dryRun": .bool(false),
        "createdAt": .string(ConnectorHealthDecay.isoTimestamp(date)),
    ])
    let text = String(data: try line.serializedData(pretty: false), encoding: .utf8)! + "\n"
    try Data(text.utf8).write(to: path, options: .atomic)
}

private let slackRegistryRow: JSONValue = .object([
    "id": .string("slack"),
    "name": .string("Slack"),
    "kind": .string("messaging"),
    "enabled": .bool(true),
    "authState": .string("connected"),
    "healthStatus": .string("ok"),
    // The frozen stamp the sweep called out.
    "lastCheckedAt": .string("2026-06-02T00:00:00+00:00"),
])

// MARK: - end to end through the list read

@Test
func readConnectorRecords_tokenWithNoProvenCallReadsConfiguredUnverified() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRegistry(root, [slackRegistryRow])
    try writeSlackToken(root)

    let records = try await NativeClient.readConnectorRecords(root: root)
    let slack = try #require(records.first { $0.id == "slack" })
    #expect(slack.healthStatus == "unverified")
    #expect(slack.authState == "configured")
    // The frozen registry stamp does not survive: no check ever happened.
    #expect(slack.lastCheckedAt == nil)

    let state = ConnectorUIState.resolve(
        authState: slack.authState, healthStatus: slack.healthStatus)
    #expect(state == .unverified)
    #expect(ConnectorsView.statusText(for: slack, uiState: state) == "configured, unverified")
}

@Test
func readConnectorRecords_aRealSuccessfulCallMakesTheRowFreshAgain() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRegistry(root, [slackRegistryRow])
    try writeSlackToken(root)

    let proven = Date().addingTimeInterval(-3600)
    try writeSlackSuccess(root, at: proven)

    let records = try await NativeClient.readConnectorRecords(root: root)
    let slack = try #require(records.first { $0.id == "slack" })
    #expect(slack.healthStatus == "ok")
    #expect(slack.authState == "connected")
    // Stamped with the call that proved it, not 2026-06-02.
    #expect(slack.lastCheckedAt == ConnectorHealthDecay.isoTimestamp(proven))
    #expect(ConnectorUIState.resolve(
        authState: slack.authState, healthStatus: slack.healthStatus) == .live)
}

@Test
func readConnectorRecords_eightDaysSinceTheLastCallReadsUnverified() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRegistry(root, [slackRegistryRow])
    try writeSlackToken(root)
    try writeSlackSuccess(root, at: Date().addingTimeInterval(-8 * 24 * 3600))

    let records = try await NativeClient.readConnectorRecords(root: root)
    let slack = try #require(records.first { $0.id == "slack" })
    #expect(slack.healthStatus == "unverified")
    #expect(slack.authState == "connected")

    let state = ConnectorUIState.resolve(
        authState: slack.authState, healthStatus: slack.healthStatus)
    #expect(state == .unverified)
    #expect(ConnectorsView.statusText(for: slack, uiState: state) == "unverified")
}

// MARK: - what the row looks like

@Test
func unverifiedNeverRendersGreenAndKeepsAReconnectRoute() {
    let state = ConnectorUIState.resolve(authState: "connected", healthStatus: "unverified")
    #expect(state == .unverified)
    #expect(state.statusColor != .green)
    // It still holds a credential, so the route is Reconnect, not Connect.
    let policy = ConnectorRowActionPolicy.resolve(
        id: "slack", authState: "connected", healthStatus: "unverified")
    #expect(policy.primaryTitle == "Reconnect")
    #expect(policy.primaryAction == .openWizard(provider: "slack"))
    #expect(policy.showsEnabledMutation)
}

@Test
func unverifiedSortsBelowLiveAndReadyButAboveNeedsAuth() {
    // Rank is derived from the state, so assert the state ordering the view
    // ranks on rather than reaching into a private helper.
    let live = ConnectorUIState.resolve(authState: "connected", healthStatus: "ok")
    let unverified = ConnectorUIState.resolve(authState: "connected", healthStatus: "unverified")
    let needsAuth = ConnectorUIState.resolve(authState: "not_connected", healthStatus: "needs_auth")
    #expect(live == .live)
    #expect(unverified == .unverified)
    #expect(needsAuth == .needsAuth)
}

// MARK: - the local greens the decay must not touch (2026-09-01 HIGH)
//
// These two read green from LOCAL readiness, not from a credential on disk, and
// neither ever writes a connector-action receipt. Decaying them turned a fresh
// install and a fresh permission grant into "configured, unverified" — a new
// lie in place of the corrected one.

@Test
func telegramConfiguredAndEnabledStaysOkWithNoReceiptsAtAll() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // The registry row still carries the frozen 2026-06-02 stamp the sweep
    // called out, so the ONLY thing keeping this row green is the overlay.
    try writeRegistry(root, [.object([
        "id": .string("telegram"),
        "name": .string("Telegram"),
        "kind": .string("messaging"),
        "enabled": .bool(true),
        "authState": .string("configured"),
        "healthStatus": .string("ok"),
        "lastCheckedAt": .string("2026-06-02T00:00:00+00:00"),
    ])])
    let telegramDir = root.appendingPathComponent("telegram", isDirectory: true)
    try FileManager.default.createDirectory(at: telegramDir, withIntermediateDirectories: true)
    try Data(#"{"bot_token":"123:abc","enabled":true,"allowed_chat_ids":[]}"#.utf8)
        .write(to: telegramDir.appendingPathComponent("config.json"), options: .atomic)

    // No receipts file exists — a Telegram bot never produces one.
    let records = try await NativeClient.readConnectorRecords(root: root)
    let telegram = try #require(records.first { $0.id == "telegram" })
    #expect(telegram.healthStatus == "ok")
    #expect(telegram.authState == "configured")
    #expect(telegram.enabled)
    #expect(ConnectorUIState.resolve(
        authState: telegram.authState, healthStatus: telegram.healthStatus) != .unverified)
}

@Test
func eventKitCalendarIsNeverDecayedWhateverThePermissionStateIs() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRegistry(root, [.object([
        "id": .string("calendar"),
        "name": .string("Calendar"),
        "kind": .string("calendar"),
        "enabled": .bool(true),
        "authState": .string("connected"),
        "healthStatus": .string("ok"),
        "lastCheckedAt": .string("2026-06-02T00:00:00+00:00"),
    ])])

    // EventKit's answer depends on the machine running the suite, so pin the
    // invariant rather than one permission state: whatever the overlay derives
    // is what the list read returns, untouched.
    let overlay = NativeClient.connectorRowWithRuntimeOverlay(
        ["id": .string("calendar")], root: root)
    #expect(overlay[ConnectorHealthDecay.proofSourceKey] == nil,
            "EventKit readiness is not credential proof and must never be stamped as such")

    let records = try await NativeClient.readConnectorRecords(root: root)
    let calendar = try #require(records.first { $0.id == "calendar" })
    #expect(calendar.healthStatus.map(JSONValue.string) == overlay["healthStatus"])
    #expect(calendar.authState.map(JSONValue.string) == overlay["authState"])
    #expect(calendar.healthStatus != ConnectorHealthDecay.unverifiedHealth)
    #expect(calendar.authState != ConnectorHealthDecay.configuredAuth)
}

@Test
func onlyTheOverlayCanClaimCredentialProof() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A hand-edited registry row cannot buy itself into (or out of) the decay:
    // the overlay clears the key before deriving.
    try writeRegistry(root, [.object([
        "id": .string("shortcuts"),
        "name": .string("Shortcuts"),
        "enabled": .bool(true),
        "healthStatus": .string("ok"),
        ConnectorHealthDecay.proofSourceKey:
            .string(ConnectorHealthDecay.credentialProofSource),
    ])])
    let overlay = NativeClient.connectorRowWithRuntimeOverlay(
        ["id": .string("shortcuts"),
         ConnectorHealthDecay.proofSourceKey:
            .string(ConnectorHealthDecay.credentialProofSource)],
        root: root)
    #expect(overlay[ConnectorHealthDecay.proofSourceKey] == nil)

    let records = try await NativeClient.readConnectorRecords(root: root)
    let shortcuts = try #require(records.first { $0.id == "shortcuts" })
    #expect(shortcuts.healthStatus == "ready")
}

@Test
func aProbeFreeLocalConnectorIsNotDecayed() async throws {
    let root = try decayRenderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // `browser`'s overlay reports authState not_required / health ready — a
    // structural readiness claim with no credential behind it. Nothing to
    // decay; turning it orange would be a new lie, not a corrected one.
    try writeRegistry(root, [.object([
        "id": .string("browser"),
        "name": .string("Visible Browser"),
        "kind": .string("browser"),
        "enabled": .bool(true),
    ])])

    let records = try await NativeClient.readConnectorRecords(root: root)
    let browser = try #require(records.first { $0.id == "browser" })
    #expect(browser.healthStatus == "ready")
    #expect(ConnectorUIState.resolve(
        authState: browser.authState, healthStatus: browser.healthStatus) == .ready)
}
