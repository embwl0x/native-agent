import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.trustCenter.hasExplicitBlockOverride
//   • core.trust.trustCenter.userConfiguredAutonomyLevel
//   • core.trust.trustCenter.normalizeBrowserAutonomy
//   • core.trust.securityCenter.trustedOriginCount
//
// The user-authored half of the trust store: the one override that outranks
// yolo, the read half of the promotion reconciler's compare-and-set, the
// unconditional browser coercion, and the number the Origin Trust panel prints.

private func overrideTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("UserAutonomyOverride-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let yoloPolicyBase: [String: JSONValue] = [
    "permissionLevel": .string("full_mac_os"),
    "developerMode": .bool(false),
    "fullMacNeverExpires": .bool(true),
    "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
]

/// A deliberate user-set "blocked" is the ONE override that outranks an active
/// Full Mac (yolo) window. It must be read from the RAW user file: consulting
/// the merged view makes every catalogued tool look explicitly configured and
/// disables the posture entirely — an inversion that already shipped once.
@Test func UserAutonomy_explicitBlockOutranksAnActiveYoloWindow() async throws {
    let root = try overrideTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var policy = yoloPolicyBase
    policy["toolAutonomy"] = .object([
        "mac_shell": .string("blocked"),
        "default": .string("send_approval"),
    ])
    try await seedHermeticTrustPolicy(policy, at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let blocked = await center.evaluateTool(
        tool: "mac_shell",
        input: ["command": .string("true")],
        origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
    )
    #expect(blocked.autonomyLevel == "blocked",
            "yolo flattened a user-set 'never fire' to \(blocked.autonomyLevel)")
    #expect(blocked.decision == .block)
    #expect(blocked.reasons.contains { $0.contains("tool autonomy blocks this tool") })

    // A sibling with NO user entry still rides the yolo posture — this is the
    // half that breaks if the resolver is handed the merged policy instead of
    // the raw user overrides.
    let sibling = await center.evaluateTool(
        tool: "restart_app", input: [:],
        origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
    )
    #expect(sibling.autonomyLevel == "auto",
            "an unconfigured sibling lost the yolo posture (\(sibling.autonomyLevel)) — the block check is probably reading the merged policy")
    #expect(sibling.decision == .allow)
}

/// The override is glob-aware, and only "blocked" counts — confirm /
/// send_approval stay flattened by yolo on purpose.
@Test func UserAutonomy_hasExplicitBlockOverride_matchesExactAndGlobButOnlyForBlocked() {
    let overrides: [String: JSONValue] = [
        "mac_shell": .string("blocked"),
        "browser.*": .string("blocked"),
        "email.send": .string("confirm"),
        "default": .string("blocked"),
    ]
    #expect(SwiftNativeTrustCenter.hasExplicitBlockOverride("mac_shell", overrides: overrides))
    #expect(SwiftNativeTrustCenter.hasExplicitBlockOverride("browser.navigate", overrides: overrides))
    #expect(!SwiftNativeTrustCenter.hasExplicitBlockOverride("email.send", overrides: overrides),
            "a 'confirm' entry was treated as an explicit block")
    #expect(!SwiftNativeTrustCenter.hasExplicitBlockOverride("shell", overrides: overrides),
            "the catch-all 'default' key was treated as naming this tool")
    #expect(!SwiftNativeTrustCenter.hasExplicitBlockOverride("", overrides: overrides))
    #expect(!SwiftNativeTrustCenter.hasExplicitBlockOverride("mac_shell", overrides: [:]))
}

/// `userConfiguredAutonomyLevel` is the read half of the promotion reconciler's
/// compare-and-set and is called with `try?`. Corrupt authority must THROW —
/// if it returned nil, `try?` would turn corruption into "no explicit override"
/// and the promotion loop would silently skip every tool.
@Test func UserAutonomy_userConfiguredAutonomyLevel_returnsSavedTierAndThrowsOnCorruption() async throws {
    let root = try overrideTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object([
            "mac_shell": .string("blocked"),
            "restart_app": .string("confirm"),
            "default": .string("send_approval"),
        ]),
    ], at: root)
    let center = SwiftNativeTrustCenter(dataRoot: root)

    #expect(try await center.userConfiguredAutonomyLevel(for: "mac_shell") == "blocked")
    #expect(try await center.userConfiguredAutonomyLevel(for: "restart_app") == "confirm")
    // A tool the user never configured is nil — NOT the merged/default tier.
    #expect(try await center.userConfiguredAutonomyLevel(for: "tool_catalog") == nil)

    let corruptRoot = try overrideTempRoot()
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let policyPath = corruptRoot
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json")
    try FileManager.default.createDirectory(
        at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not-json".utf8).write(to: policyPath)
    let corruptCenter = SwiftNativeTrustCenter(dataRoot: corruptRoot)

    await #expect(throws: (any Error).self) {
        _ = try await corruptCenter.userConfiguredAutonomyLevel(for: "mac_shell")
    }
}

/// `normalizeBrowserAutonomy` UNCONDITIONALLY rewrites the browser navigation
/// tiers to "auto" on every read. A user who sets browser navigation to
/// "confirm" in Trust Center sees it accepted and persisted, then silently
/// ignored. Only an explicit "blocked" survives.
///
/// Pinned in both directions: the coercion set is exact (a NEW tool joining the
/// silent-coercion list fails here), and "blocked" must survive.
@Test func UserAutonomy_browserAutonomyCoercion_isExactAndSparesBlocked() async throws {
    let coercedTools = ["browser.open_url", "browser_open_url", "browser.navigate", "browser_navigate"]
    let coercedTiers = ["draft_auto", "send_approval", "confirm", "destructive_strong"]

    for tier in coercedTiers {
        let root = try overrideTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved: [String: JSONValue] = ["permissionLevel": .string("balanced")]
        var autonomy: [String: JSONValue] = ["default": .string("send_approval")]
        for tool in coercedTools { autonomy[tool] = .string(tier) }
        // A control tool outside the coercion list, set to the same tier.
        autonomy["read_file"] = .string(tier)
        saved["toolAutonomy"] = .object(autonomy)
        try await seedHermeticTrustPolicy(saved, at: root)

        let normalized = try await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicyChecked()
        guard case .object(let readBack)? = normalized["toolAutonomy"] else {
            Issue.record("toolAutonomy missing from the normalized policy")
            return
        }
        for tool in coercedTools {
            #expect(readBack[tool] == .string("auto"),
                    "\(tool) at '\(tier)' normalized to \(String(describing: readBack[tool])) — the browser coercion changed shape")
        }
        #expect(readBack["read_file"] == .string(tier),
                "the coercion leaked outside the browser tool list onto read_file")
    }

    // "blocked" is the one tier that survives — the user's hard no is honoured.
    let blockedRoot = try overrideTempRoot()
    defer { try? FileManager.default.removeItem(at: blockedRoot) }
    var autonomy: [String: JSONValue] = ["default": .string("send_approval")]
    for tool in coercedTools { autonomy[tool] = .string("blocked") }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(autonomy),
    ], at: blockedRoot)
    let normalized = try await SwiftNativeTrustCenter(dataRoot: blockedRoot).loadTrustPolicyChecked()
    guard case .object(let readBack)? = normalized["toolAutonomy"] else {
        Issue.record("toolAutonomy missing from the normalized policy")
        return
    }
    for tool in coercedTools {
        #expect(readBack[tool] == .string("blocked"),
                "a user's explicit 'blocked' on \(tool) was coerced away — the last surviving browser override is gone")
    }
}

/// The Origin Trust panel prints "N device(s) you have approved" from
/// `trustedOriginCount()`, which counts the TELEGRAM allowlist only. Slack
/// allowlist entries and paired-iOS trust are real trust roots `assessOrigin`
/// honours, and they never reach the count — so the flag reads "limited" on an
/// install that has trusted Slack/iOS origins.
///
/// Pinned as an observable undercount (ledger row
/// core.trust.securityCenter.trustedOriginCount). If the count starts including
/// the other roots, that is the fix: update this expectation and flip the row.
@Test func SecurityCenter_trustedOriginCount_countsOnlyTelegramWhileOtherRootsAreHonoured() async throws {
    let root = try overrideTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()

    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(["default": .string("auto")]),
        "iosRemotePolicy": .object(["remote_from_ios_allowed": .bool(true)]),
    ], at: root, persistence: persistence)
    // Telegram deliberately EMPTY.
    try await persistence.writeJSON(
        .object(["bot_token": .string("redacted")]),
        to: root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json"))
    // Slack allowlist populated — a real trust root.
    try await persistence.writeJSON(
        .object(["allowed_channel_ids": .array([.string("C123")])]),
        to: root.appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("auth.json"))

    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let status = await center.status()

    // Both non-telegram roots ARE honoured by the gate.
    let slack = await center.evaluateTool(
        tool: "read_file", input: [:],
        origin: SecurityOriginContext(surface: "slack", chatId: "C123", isRemote: true))
    #expect(slack.originTrusted, "the slack allowlist root was not honoured: \(slack.originTrustReason)")
    let ios = await center.evaluateTool(
        tool: "read_file", input: [:],
        origin: SecurityOriginContext(surface: "ios", isRemote: true))
    #expect(ios.originTrusted, "the paired-iOS root was not honoured: \(ios.originTrustReason)")

    // ...and neither reaches the panel's count.
    #expect(status.trustedOrigins == 0, """
        trustedOrigins now reports \(status.trustedOrigins) with an EMPTY telegram
        allowlist — the count has started including the slack / paired-iOS roots.
        That is the fix landing: update this expectation and flip ledger row
        core.trust.securityCenter.trustedOriginCount.
        """)
    #expect(status.flags.first { $0.id == "origin_trust" }?.status == "limited",
            "the Origin Trust flag stopped reflecting the (under)count")

    // Control: a telegram entry DOES move the number, so the counter is live,
    // not stuck at zero.
    try await persistence.writeJSON(
        .object(["bot_token": .string("redacted"),
                 "allowed_chat_ids": .array([.int(123), .int(456)])]),
        to: root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json"))
    let withTelegram = await SwiftNativeSecurityCenter(dataRoot: root).status()
    #expect(withTelegram.trustedOrigins >= 2,
            "the telegram allowlist no longer reaches the panel count")
}
