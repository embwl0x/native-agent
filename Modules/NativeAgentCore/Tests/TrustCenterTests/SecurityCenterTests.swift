import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

private func makeSecurityTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecurityCenter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func SecurityCenter_blocksEveryToolWhenSavedAuthorityIsCorrupt() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let policyPath = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let damaged = Data("{not-json".utf8)
    try damaged.write(to: policyPath)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in ["tool_catalog", "browser_status", "memory_search"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.decision == .block, "\(tool) must fail closed")
        #expect(!envelope.allowed)
        #expect(envelope.reasons.contains { $0.contains("trust policy is unavailable") })
    }
    let status = await center.status()
    #expect(status.status == "blocked")
    #expect(status.mode == "unavailable")
    #expect(status.flags.first?.id == "trust_policy_unavailable")
    #expect(try Data(contentsOf: policyPath) == damaged)
}

@Test func SecurityCenter_blocksEveryToolWhenSavedAuthorityBlockHasWrongShape() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let policyPath = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let damaged = Data(#"{"securityPolicy":"damaged"}"#.utf8)
    try damaged.write(to: policyPath)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in ["tool_catalog", "browser_status", "memory_search"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.decision == .block, "\(tool) must fail closed")
        #expect(!envelope.allowed)
        #expect(envelope.reasons.contains { $0.contains("trust policy is unavailable") })
    }
    let status = await center.status()
    #expect(status.status == "blocked")
    #expect(status.mode == "unavailable")
    #expect(try Data(contentsOf: policyPath) == damaged)
}

@Test func SecurityCenter_blocksEveryToolWhenKnownAuthorityFieldHasWrongType() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let policyPath = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let damaged = Data(#"{"securityPolicy":{"killSwitchEnabled":"false"}}"#.utf8)
    try damaged.write(to: policyPath)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in ["tool_catalog", "browser_status", "memory_search"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.decision == .block, "\(tool) must fail closed")
        #expect(!envelope.allowed)
        #expect(envelope.reasons.contains { $0.contains("trust policy is unavailable") })
    }
    #expect(try Data(contentsOf: policyPath) == damaged)
}

@Test func SecurityCenter_allows_catalog_and_records_receipt() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "low")

    try await center.record(envelope)
    let receipts = try await persistence.readJSONL(
        root.appendingPathComponent("security", isDirectory: true).appendingPathComponent("audit.jsonl")
    )
    #expect(receipts.count == 1)
}

@Test func SecurityCenter_auditAppendUsesSoftByteTriggerBeforeRotation() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let auditPath = root
        .appendingPathComponent("security", isDirectory: true)
        .appendingPathComponent("audit.jsonl")
    try FileManager.default.createDirectory(
        at: auditPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let seededCount = JSONLLineCaps.securityAudit + 1
    let seed = String(repeating: "{}\n", count: seededCount)
    #expect(seed.utf8.count < JSONLLineCaps.securityAuditTrimTriggerBytes)
    try Data(seed.utf8).write(to: auditPath)

    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let envelope = await center.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    try await center.record(envelope)

    let lines = try String(contentsOf: auditPath, encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == seededCount + 1)
    guard let lastLine = lines.last else {
        Issue.record("security audit append produced no rows")
        return
    }
    let last = try JSONValue.parse(Data(lastLine.utf8))
    guard case .object(let object) = last else {
        Issue.record("appended audit receipt was not an object")
        return
    }
    #expect(object["id"] == .string(envelope.id))
}

@Test func SecurityCenter_blocks_shell_without_developer_mode() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "mac.shell",
        input: ["command": .string("ls -la")],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.risk == "critical")
    #expect(envelope.reasons.contains { $0.contains("Developer Mode") })
}

@Test func SecurityCenter_classifies_swiftpm_builders_as_critical_process_tools() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in ["swift_build", "swift_test"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )

        #expect(envelope.allowed == false)
        #expect(envelope.decision == .block)
        #expect(envelope.risk == "critical")
        #expect(envelope.reasons.contains { $0.contains("Developer Mode") })
    }
}

@Test func SecurityCenter_browserNavigate_isMediumAutoNetworkReadBuiltin() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "browser.navigate",
        input: ["url": .string("https://example.com")],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "medium")
    #expect(envelope.autonomyLevel == "auto")
    #expect(envelope.signedToolKnown)
    #expect(envelope.capabilities.contains("network_read"))
    #expect(!envelope.capabilities.contains("approval_stage"))
}

@Test func SecurityCenter_browserStatus_isLowRiskReadBuiltin() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "browser_status",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.tool == "browser.status")
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "low")
    #expect(envelope.autonomyLevel == "auto")
    #expect(envelope.signedToolKnown)
    #expect(envelope.capabilities.contains("safe_read"))
}

@Test func SecurityCenter_healthStatusToolsAreLowRiskReadBuiltins() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in ["doctor_status", "telegram_status"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "telegram", isRemote: true)
        )

        #expect(envelope.allowed)
        #expect(envelope.decision == .allow)
        #expect(envelope.risk == "low")
        #expect(envelope.autonomyLevel == "auto")
        #expect(envelope.signedToolKnown)
        #expect(envelope.capabilities.contains("safe_read"))
    }
}

@Test func SecurityCenter_chatHistoryAliasesAreAutomaticSignedReadsFromTrustedTelegram() async throws {
    // Reproduce an existing install whose saved policy predates the canonical
    // search_chat_history entry. Normalization must backfill both names over a
    // send_approval default so a routine transcript read never opens an
    // approval loop merely because Telegram used the canonical spelling.
    let (root, persistence) = try await makeTrustedTelegramRoot(toolAutonomy: [
        "default": .string("send_approval"),
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    for tool in ["search_chat_history", "session_search"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: ["query": .string("earlier Mac chat")],
            origin: SecurityOriginContext(
                surface: "telegram",
                sessionId: "telegram:123",
                isRemote: true
            )
        )

        #expect(envelope.originTrusted, "\(tool) must retain Telegram allowlist trust")
        #expect(envelope.allowed, "\(tool) should be an automatic read")
        #expect(envelope.decision == .allow)
        #expect(envelope.autonomyLevel == "auto")
        #expect(envelope.risk == "low")
        #expect(envelope.signedToolKnown, "\(tool) must be recognized as built-in")
        #expect(envelope.capabilities.contains("safe_read"))
        #expect(!envelope.requiresApproval)
    }
}

@Test func SecurityCenter_slackAndAgentMailReadAliasesRemainAutomatic() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let tools = [
        "slack.status", "slack_status",
        "slack.list_channels", "slack_list_channels",
        "slack.search_messages", "slack_search_messages",
        "agentmail_list", "agentmail_read",
    ]

    for tool in tools {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.allowed, "\(tool) should remain an automatic read")
        #expect(envelope.decision == .allow)
        #expect(envelope.autonomyLevel == "auto")
        #expect(envelope.risk == "low")
        #expect(envelope.capabilities.contains("safe_read"))
        #expect(!envelope.capabilities.contains("external_send"))
        #expect(!envelope.capabilities.contains("approval_stage"))
    }
}

@Test func SecurityCenter_allowsAgentMailApprovalStagingFromLocalChat() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "agentmail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("Direct AgentMail"),
            "body": .string("Send from Agent's own address."),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.tool == "agentmail.send")
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "high")
    #expect(envelope.autonomyLevel == "send_approval")
    #expect(envelope.signedToolKnown)
    #expect(envelope.capabilities.contains("external_send"))
    #expect(!envelope.capabilities.contains("network_write"))
    #expect(envelope.capabilities.contains("approval_stage"))
    #expect(!envelope.requiresApproval)
    #expect(!envelope.reasons.contains { $0.contains("external send requires approval") })
    #expect(!envelope.reasons.contains { $0.contains("tool autonomy requires approval") })
}

@Test func SecurityCenter_blocksAgentMailSendFromUntrustedTelegram() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "agentmail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("Remote AgentMail"),
            "body": .string("Untrusted Telegram should not send this."),
        ],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:999",
            chatId: "999",
            isRemote: true
        )
    )

    #expect(envelope.tool == "agentmail.send")
    #expect(!envelope.originTrusted)
    #expect(!envelope.allowed)
    #expect(envelope.decision == .block)
    #expect(envelope.capabilities.contains("external_send"))
    #expect(envelope.reasons.contains { $0.contains("remote high-risk origin is not trusted") })
}

@Test func SecurityCenter_canonicalizesXChatReadToolsToSignedConnectorActions() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let cases: [(tool: String, canonical: String)] = [
        ("x_status", "x.status"),
        ("x_me", "x.me"),
        ("x_search", "x.search_recent"),
        ("x_timeline", "x.timeline_home"),
        ("x_user_tweets", "x.user_tweets"),
    ]

    for item in cases {
        let envelope = await center.evaluateTool(
            tool: item.tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )

        #expect(envelope.tool == item.canonical)
        #expect(envelope.allowed)
        #expect(envelope.decision == .allow)
        #expect(envelope.risk == "low")
        #expect(envelope.signedToolKnown)
        #expect(envelope.capabilities.contains("safe_read"))
        #expect(!envelope.capabilities.contains("external_send"))
        #expect(!envelope.reasons.contains { $0.contains("tool signature not known") })
    }
}

@Test func SecurityCenter_allowsSlackApprovalStagingFromLocalChat() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("hello from Agent"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.tool == "slack.post_message")
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "high")
    #expect(envelope.autonomyLevel == "send_approval")
    #expect(envelope.signedToolKnown)
    #expect(envelope.capabilities.contains("external_send"))
    #expect(!envelope.capabilities.contains("network_write"))
    #expect(envelope.capabilities.contains("approval_stage"))
    #expect(!envelope.requiresApproval)
    #expect(!envelope.reasons.contains { $0.contains("requires approval") })
    #expect(!envelope.reasons.contains { $0.contains("tool signature not known") })
}

@Test func SecurityCenter_allowsSlackApprovalStagingFromTrustedTelegram() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(toolAutonomy: [
        "slack.post_message": .string("send_approval"),
        "slack_post_message": .string("send_approval"),
    ])
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("hello from Agent"),
        ],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:123",
            isRemote: true
        )
    )

    #expect(envelope.tool == "slack.post_message")
    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.autonomyLevel == "send_approval")
    #expect(!envelope.requiresApproval)
    #expect(!envelope.reasons.contains { $0.contains("tool autonomy requires approval") })
}

@Test func SecurityCenter_allowsSlackApprovalStagingFromAllowlistedSlackSurface() async throws {
    // 2026-07-21 audit: slack trust moved from a forgeable
    // commandSignatureVerified flag (socket mode has NO signature scheme —
    // the chat handler bound it true unconditionally) to an explicit
    // allowlist mirroring telegram. This test pins the allowlist path; note
    // the origin still carries the old flag to prove it is IGNORED.
    let root = try makeSecurityTempRoot()
    let slackDir = root.appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("slack", isDirectory: true)
    try FileManager.default.createDirectory(at: slackDir, withIntermediateDirectories: true)
    try Data(#"{"allowed_channel_ids": ["C123"], "allowed_user_ids": ["U123"]}"#.utf8)
        .write(to: slackDir.appendingPathComponent("auth.json"))
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("hello from Agent"),
        ],
        origin: SecurityOriginContext(
            surface: "slack",
            sessionId: "slack:T123:C123",
            userId: "U123",
            chatId: "C123",
            isRemote: true,
            commandSignatureVerified: true
        )
    )

    #expect(envelope.tool == "slack.post_message")
    #expect(envelope.originTrusted)
    #expect(envelope.originTrustReason == "slack chat allowlist matched")
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.autonomyLevel == "send_approval")
    #expect(!envelope.requiresApproval)
    #expect(!envelope.reasons.contains { $0.contains("remote high-risk origin is not trusted") })
    #expect(!envelope.reasons.contains { $0.contains("remote high-risk command is unsigned") })
}

@Test func SecurityCenter_blocksSlackPostFromUnallowlistedSlackSurface() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    // No slack config at all → allowlist-empty honest failure.
    let unconfigured = await center.evaluateTool(
        tool: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("hello from Agent"),
        ],
        origin: SecurityOriginContext(
            surface: "slack",
            sessionId: "slack:T123:C123",
            userId: "U123",
            chatId: "C123",
            isRemote: true
        )
    )
    #expect(!unconfigured.originTrusted)
    #expect(!unconfigured.allowed)
    #expect(unconfigured.decision == .block)
    #expect(unconfigured.reasons.contains { $0.contains("slack allowlist not configured for security proof") })

    // Configured allowlist that does NOT name this channel/user → not in allowlist.
    let slackDir = root.appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("slack", isDirectory: true)
    try FileManager.default.createDirectory(at: slackDir, withIntermediateDirectories: true)
    try Data(#"{"allowed_channel_ids": ["C999"]}"#.utf8)
        .write(to: slackDir.appendingPathComponent("auth.json"))
    let notListed = await center.evaluateTool(
        tool: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("hello from Agent"),
        ],
        origin: SecurityOriginContext(
            surface: "slack",
            sessionId: "slack:T123:C123",
            userId: "U123",
            chatId: "C123",
            isRemote: true
        )
    )
    #expect(!notListed.originTrusted)
    #expect(notListed.decision == .block)
    #expect(notListed.reasons.contains { $0.contains("slack origin is not in allowlist") })
}

@Test func SecurityCenter_blocksSlackPostFromUntrustedTelegram() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("hello from Agent"),
        ],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:999",
            chatId: "999",
            isRemote: true
        )
    )

    #expect(envelope.tool == "slack.post_message")
    #expect(!envelope.originTrusted)
    #expect(!envelope.allowed)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("remote high-risk origin is not trusted") })
}

@Test func SecurityCenter_treatsMacIntegrationChatToolsAsKnownBuiltins() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let tools = [
        "mac_calendar_list_upcoming",
        "mac_calendar_create_event",
        "mac_calendar_modify_event",
        "mac_reminders_list_due_today",
        "mac_reminders_create",
        "mac_reminders_complete",
        "mail_list_recent",
        "mail_search",
        "mail_send",
        "mail_mark_read",
        "mail_archive",
        "mail_delete",
        "mail_reply",
        "messages_recent_threads",
        "messages_send",
        "notes_search",
        "notes_create",
        "notes_update",
        "contacts_search",
        "contacts_create_or_update",
        "contacts_delete",
        "music_now_playing",
        "music_search_library",
        "music_list_library",
        "music_list_playlists",
        "music_control",
        "mac_spotlight_search",
        "scheduler_list_jobs",
        "scheduler_create_job",
    ]

    for tool in tools {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )

        #expect(envelope.tool == tool)
        #expect(envelope.signedToolKnown, "\(tool) should be treated as a known NativeAgent builtin")
        #expect(!envelope.reasons.contains { $0.contains("tool signature not known") }, "\(tool) should not look unsigned")
    }
}

@Test func SecurityCenter_macIntegrationSendsStillRequireApprovalAfterBuiltinSigning() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in ["mail_send", "messages_send", "mail_reply"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )

        #expect(envelope.signedToolKnown)
        #expect(envelope.decision == .ask)
        #expect(envelope.requiresApproval)
        #expect(envelope.capabilities.contains("external_send"))
        #expect(envelope.reasons.contains { $0.contains("external send requires approval") })
        #expect(!envelope.reasons.contains { $0.contains("tool signature not known") })
    }
}

@Test func SecurityCenter_developerModeDoesNotGrantFullMacWrites() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("balanced"),
            "developerMode": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "write_file",
        input: [
            "path": .string("/tmp/nativeagent-devmode-fullmac-regression.txt"),
            "content": .string("nope"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.risk == "high")
    #expect(envelope.reasons.contains { $0.contains("Full Mac access") })
}

@Test func SecurityCenter_expiredFullMacGrantDoesNotAllowOutsideWorkspaceWrite() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    let now = ISO8601DateFormatter().date(from: "2026-06-08T12:00:00Z")!
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacExpiresAt": .string("2026-06-08T10:00:00Z"),
            "fullMacNeverExpires": .bool(false),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object([
                "default": .string("auto"),
                "write_file": .string("auto"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence, clock: { now })

    let envelope = await center.evaluateTool(
        tool: "write_file",
        input: [
            "path": .string("/tmp/nativeagent-expired-fullmac-regression.txt"),
            "content": .string("nope"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("Full Mac access") })
}

@Test func SecurityCenter_allowsTrustedWorkspaceWriteWithoutFullMac() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    let vaultRoot = root.appendingPathComponent("Obsidian Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("balanced"),
            "filePolicy": .object([
                "workspaceRoots": .array([.string(vaultRoot.path)]),
                "outsideWorkspaceDefault": .string("deny"),
            ]),
            "toolAutonomy": .object([
                "default": .string("auto"),
                "write_file": .string("auto"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "write_file",
        input: [
            "path": .string(vaultRoot.appendingPathComponent("Codex/note.md").path),
            "content": .string("ok"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "medium")
    #expect(envelope.capabilities.contains("filesystem_write"))
    #expect(!envelope.capabilities.contains("outside_app_data_write"))
    #expect(!envelope.reasons.contains { $0.contains("Full Mac access") })
}

@Test func SecurityCenter_treatsCanonicalNativeAgentWorkspaceAsTrusted() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("balanced"),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")]),
            "toolAutonomy": .object([
                "default": .string("auto"),
                "write_file": .string("auto"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let workspaceFile = root
        .appendingPathComponent("workspace", isDirectory: true)
        .appendingPathComponent("project/README.md")

    let envelope = await center.evaluateTool(
        tool: "write_file",
        input: [
            "path": .string(workspaceFile.path),
            "content": .string("ok"),
        ],
        origin: SecurityOriginContext(surface: "telegram")
    )

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(!envelope.capabilities.contains("outside_app_data_write"))
    #expect(!envelope.reasons.contains { $0.contains("Full Mac access") })
}

@Test func SecurityCenter_redacts_and_blocks_secret_egress() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "email.send",
        input: [
            "to": .string("someone@example.com"),
            "body": .string("send this key sk-test-secret-secret-secret-secret"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("secret firewall") })
    let preview = try envelope.redactedInputPreview.serialize(pretty: false)
    #expect(preview.contains("[REDACTED]"))
    #expect(!preview.contains("sk-test-secret"))
}

@Test func SecurityCenter_allowsShellCommandWithRepeatedDottedFilenames() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "toolAutonomy": .object([
                "default": .string("auto"),
                "bash": .string("auto"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let command = """
        echo '--- find Package.swift ---'
        find ~ -maxdepth 4 -name 'Package.swift' 2>/dev/null | head -10
        ls -d /Library/Frameworks/Python.framework /Applications/Xcode.app
        """

    let envelope = await center.evaluateTool(
        tool: "bash",
        input: ["cmd": .string(command)],
        origin: SecurityOriginContext(surface: "chat"),
        enforceAutonomy: false
    )

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(!envelope.reasons.contains { $0.contains("secret-shaped") })
    #expect(!envelope.reasons.contains { $0.contains("secret firewall") })
    guard case .object(let preview) = envelope.redactedInputPreview,
          case .string(let preserved)? = preview["cmd"] else {
        Issue.record("command preview lost its expected object/string shape")
        return
    }
    #expect(preserved.contains("Package.swift"))
    #expect(preserved.contains("Python.framework"))
}

@Test func SecurityCenter_stillBlocksValidJWTEmbeddedInShellCommand() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "toolAutonomy": .object([
                "default": .string("auto"),
                "bash": .string("auto"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoyMDAwMDAwMDAwfQ"
        + ".abcdefghijklmnopqrstuvwx"

    let envelope = await center.evaluateTool(
        tool: "bash",
        input: ["cmd": .string("inspect \(jwt) safely")],
        origin: SecurityOriginContext(surface: "chat"),
        enforceAutonomy: false
    )

    #expect(!envelope.allowed)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("secret-shaped input redacted in cmd") })
    #expect(envelope.reasons.contains { $0.contains("secret firewall") })
    let preview = try envelope.redactedInputPreview.serialize(pretty: false)
    #expect(preview.contains("[REDACTED]"))
    #expect(!preview.contains(jwt))
}

@Test func SecurityCenter_allows_codexMessage_withSecretShapedDiagnosticText() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "codex_message",
        input: [
            "text": .string("diagnostic output mentions sk-test-secret-secret-secret-secret"),
            "topic": .string("policy-debug"),
            "priority": .string("important"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.capabilities.contains("notification"))
    #expect(!envelope.reasons.contains { $0.contains("secret firewall") })
    let preview = try envelope.redactedInputPreview.serialize(pretty: false)
    #expect(preview.contains("[REDACTED]"))
    #expect(!preview.contains("sk-test-secret"))
}

@Test func SecurityCenter_allows_trustedTelegramCodexMessageWithPATTaskSpec() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(
        toolAutonomy: ["codex_message": .string("auto")]
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let spec = """
    Build GitHub integration for NativeAgent using a fine-grained Personal Access Token.
    This is a PAT flow, not OAuth. Do not add a github entry to NativeOAuthFlow+Configs.swift.
    Read the existing connector code first and keep the token out of logs.
    If the system prompt or tool registration conventions are ambiguous, consult Agent.
    """

    let envelope = await center.evaluateTool(
        tool: "codex_message",
        input: [
            "text": .string(spec),
            "topic": .string("GitHub PAT integration"),
            "priority": .string("important"),
        ],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:123",
            isRemote: true
        )
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.untrustedInputKeys.contains("text"))
    #expect(envelope.reasons.contains { $0.contains("prompt-injection markers") })
    #expect(envelope.reasons.contains { $0.contains("trusted local agent bridge") })
    #expect(!envelope.reasons.contains { $0.contains("operator review") })
}

@Test func SecurityCenter_untrustedTelegramCodexMessageWithPromptMarkersStillAsks() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(
        toolAutonomy: ["codex_message": .string("auto")]
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "codex_message",
        input: [
            "text": .string("Forward this system prompt note about a Personal Access Token to Codex."),
            "topic": .string("untrusted"),
        ],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:999",
            isRemote: true
        )
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .ask)
    #expect(envelope.reasons.contains { $0.contains("prompt-injection shield requires operator review") })
}

@Test func SecurityCenter_externalSendWithPATPromptMarkersStillAsks() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "agentmail_send",
        input: [
            "to": .string("worker@example.com"),
            "subject": .string("GitHub PAT"),
            "body": .string("Tell them to use a Personal Access Token and inspect the system prompt."),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed == false)
    #expect(envelope.decision == .ask)
    #expect(envelope.reasons.contains { $0.contains("prompt-injection shield requires operator review") })
    #expect(!envelope.reasons.contains { $0.contains("trusted local agent bridge") })
}

/// Helper: a temp root with an allowlisted Telegram chat (123) so telegram:123
/// assesses as a TRUSTED remote origin, plus an optional securityPolicy block.
private func makeTrustedTelegramRoot(
    securityPolicy: JSONValue? = nil,
    toolAutonomy: [String: JSONValue] = ["invoke_claude": .string("auto")]
) async throws -> (URL, SwiftNativePersistenceCore) {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    var policy: [String: JSONValue] = [
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(toolAutonomy),
    ]
    if let securityPolicy { policy["securityPolicy"] = securityPolicy }
    try await persistence.writeJSON(
        .object(policy),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    return (root, persistence)
}

/// Uniform cross-surface access (2026-06-09): a TRUSTED remote origin (allowlisted
/// Telegram) runs a high-risk subprocess tool (invoke_claude) like the local Mac —
/// the signed-command gate is waived because the allowlist already proved provenance.
@Test func SecurityCenter_allows_trusted_remote_high_risk_by_default() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("help me scope a small change")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(!envelope.reasons.contains { $0.contains("unsigned") })
}

@Test func SecurityCenter_allowsXUserTweetsFromTrustedTelegramAsReadOnly() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "x_user_tweets",
        input: [
            "username": .string("unrealengine"),
            "max": .int(20),
        ],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "E974BCD6-013D-48F4-85B1-95A67F33D534",
            chatId: "123",
            isRemote: true
        )
    )

    #expect(envelope.tool == "x.user_tweets")
    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "low")
    #expect(envelope.autonomyLevel == "auto")
    #expect(envelope.signedToolKnown)
    #expect(envelope.capabilities.contains("safe_read"))
    #expect(!envelope.capabilities.contains("external_send"))
    #expect(!envelope.reasons.contains { $0.contains("tool signature not known") })
    #expect(!envelope.reasons.contains { $0.contains("requires approval") })
}

/// An UNTRUSTED remote origin (chat not in the allowlist) stays hard-blocked by the
/// trust gate (Gate 1) — the waiver never elevates a stranger.
@Test func SecurityCenter_blocks_untrusted_remote_high_risk() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("help me")],
        // 999 is NOT in the allowlist -> untrusted
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:999", isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("not trusted") })
}

/// With trustedRemoteHighRiskAllowed=false, the user restores strict signing: even a
/// trusted remote unsigned high-risk call blocks again.
@Test func SecurityCenter_blocks_trusted_remote_high_risk_when_waiver_disabled() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(
        securityPolicy: .object(["trustedRemoteHighRiskAllowed": .bool(false)])
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("help me")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("unsigned") })
}

/// Uniform-invoke fix (2026-06-09): a `/new` Telegram session is a bare UUID, so the
/// legacy `telegram:<chatId>` parse yields chatId=nil and the allowlist can't match.
/// The transport now threads the AUTHENTICATED chatId (origin.chatId), so an
/// allowlisted chat on a UUID session is trusted and the high-risk invoke passes —
/// same as a legacy-session or Mac turn. This is the empirical proof that Telegram
/// invoke_claude works regardless of session form.
@Test func SecurityCenter_trusts_allowlisted_telegram_uuidSession_via_threaded_chatId() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping from a /new session")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "9F0C-UUID-SESSION",   // NOT telegram:<chatId>
            chatId: "123",                     // threaded by the transport fix
            isRemote: true
        )
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
}

/// The fix does NOT relax trust: a UUID session with no threaded chatId (and none
/// parseable from the session string) stays untrusted and blocks. The threaded
/// chatId is the ONLY thing that elevates trust — block is the safe default.
@Test func SecurityCenter_blocks_telegram_uuidSession_without_chatId() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "9F0C-UUID-SESSION",
            chatId: nil,
            isRemote: true
        )
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
}

/// A threaded chatId that is NOT allowlisted is still blocked — the new chatId path
/// is not a forgery vector; the allowlist remains the guard.
@Test func SecurityCenter_blocks_telegram_uuidSession_with_unallowlisted_chatId() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "9F0C-UUID-SESSION",
            chatId: "999",   // not in the allowlist
            isRemote: true
        )
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
}

/// Full Mac YOLO is the user's selected autonomy posture across authenticated
/// conversation surfaces. The Telegram allowlist proves the origin; an
/// arbitrary caller using the same surface label remains covered below.
@Test func SecurityCenter_critical_trusted_remote_yolo_satisfies_developer_mode() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),  // OFF — the point of this test
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "mac.shell",
        input: ["command": .string("whoami")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(envelope.originTrusted)
    #expect(envelope.autonomyLevel == "auto")
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(!envelope.reasons.contains { $0.contains("Developer Mode") })
}

/// the user 2026-06-13 ("yolo IS dev mode"): an ACTIVE Full Mac (yolo) window
/// satisfies the Developer-Mode requirement for a critical tool from a LOCAL
/// origin, so the dev-mode gate does NOT fire.
@Test func SecurityCenter_critical_local_yolo_satisfies_developer_mode() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),  // OFF — the yolo window must cover it
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "shell",
        input: ["command": .string("whoami")],
        origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
    )

    // The Developer-Mode block must NOT fire for a local origin in a yolo window.
    #expect(!envelope.reasons.contains { $0.contains("Developer Mode") })
}

@Test func SecurityCenter_trustedTelegramYoloAllowsRoutineMemoryAndContextTools() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "toolAutonomy": .object(["default": .string("send_approval")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    for tool in ["commit_memory", "context_expand"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(
                surface: "telegram",
                sessionId: "telegram:123",
                isRemote: true
            )
        )

        #expect(envelope.originTrusted, "\(tool) must retain canonical Telegram trust")
        #expect(envelope.autonomyLevel == "auto", "\(tool) must inherit active Full Mac YOLO")
        #expect(envelope.allowed, "\(tool) must not be stopped by a second autonomy decision")
        #expect(envelope.decision == .allow)
    }
}

@Test func SecurityCenter_untrustedTelegramLabelDoesNotInheritRoutineYolo() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "toolAutonomy": .object(["default": .string("send_approval")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "context_expand",
        input: [:],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:999",
            isRemote: true
        )
    )

    #expect(!envelope.originTrusted)
    #expect(envelope.autonomyLevel == "send_approval")
    #expect(!envelope.allowed)
    #expect(envelope.decision == .ask)
}

@Test func SecurityCenter_unifiedPolicyDecisionLabelsLocalFullMacCriticalAllow() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let decision = await center.evaluatePolicyDecision(
        tool: "shell",
        input: ["command": .string("whoami")],
        origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
    )

    #expect(decision.outcome == .allow)
    #expect(decision.policySource == "full_mac")
    #expect(decision.sideEffectLevel == "critical")
    #expect(decision.requestedCapability == "shell")
    #expect(decision.fullMacActive)
    #expect(!decision.developerMode)
    #expect(!decision.remoteSurface)
    #expect(decision.surfaceTrusted)
    #expect(decision.expiresAt == "never")
}

@Test func SecurityCenter_unifiedPolicyDecisionLabelsTrustedRemoteFullMacCriticalAllow() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let decision = await center.evaluatePolicyDecision(
        tool: "mac.shell",
        input: ["command": .string("whoami")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(decision.outcome == .allow)
    #expect(decision.policySource == "origin_trust")
    #expect(decision.reason.contains("trusted remote origin"))
    #expect(decision.sideEffectLevel == "critical")
    #expect(decision.fullMacActive)
    #expect(!decision.developerMode)
    #expect(decision.remoteSurface)
    #expect(decision.surfaceTrusted)
}

@Test func SecurityCenter_unifiedPolicyDecisionLabelsConnectorApproval() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let decision = await center.evaluatePolicyDecision(
        tool: "mail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("approval"),
            "body": .string("needs approval"),
        ],
        origin: SecurityOriginContext(surface: "chat", sessionId: "local")
    )

    #expect(decision.outcome == .confirm)
    #expect(decision.policySource == "connector_policy")
    #expect(decision.actionKind == "connector_send")
    #expect(decision.dataScope == "external_service")
    #expect(decision.requestedCapability == "external_send")
    #expect(decision.reason.contains("external send requires approval"))
}

@Test func SecurityCenter_trustedTelegramYoloAllowsInstallAppWithoutApproval() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object([
                "default": .string("send_approval"),
                "install_app": .string("confirm"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("apply tested Swift build")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(envelope.originTrusted)
    #expect(envelope.autonomyLevel == "auto")
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(!envelope.reasons.contains { $0.contains("Developer Mode") })
    #expect(!envelope.reasons.contains { $0.contains("tool autonomy requires approval") })
}

@Test func SecurityCenter_pairedIOSChatSurfacesYoloAllowInstallAppWithoutApproval() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "iosRemotePolicy": .object(["remote_from_ios_allowed": .bool(true)]),
            "toolAutonomy": .object([
                "default": .string("send_approval"),
                "install_app": .string("confirm"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    for surface in ["ios", "icloud", "iphone", "ipad", "mobile", "watch"] {
        let envelope = await center.evaluateTool(
            tool: "install_app",
            input: ["reason": .string("apply tested Swift build")],
            origin: SecurityOriginContext(surface: surface, isRemote: true)
        )

        #expect(envelope.originTrusted, "\(surface) must be trusted when paired iOS remote control is enabled")
        #expect(envelope.autonomyLevel == "auto", "\(surface) install_app must resolve auto in yolo")
        #expect(envelope.allowed, "\(surface) install_app must be allowed")
        #expect(envelope.decision == .allow, "\(surface) install_app decision must allow")
        #expect(!envelope.reasons.contains { $0.contains("Developer Mode") }, "\(surface) must not require Developer Mode for lifecycle yolo")
        #expect(!envelope.reasons.contains { $0.contains("tool autonomy requires approval") }, "\(surface) must not require approval for lifecycle yolo")
    }
}

@Test func SecurityCenter_unpairedIOSChatSurfaceYoloStillBlocksInstallApp() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "iosRemotePolicy": .object(["remote_from_ios_allowed": .bool(false)]),
            "toolAutonomy": .object([
                "default": .string("send_approval"),
                "install_app": .string("confirm"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("unpaired iCloud install attempt")],
        origin: SecurityOriginContext(surface: "icloud", isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("not trusted") })
}

@Test func SecurityCenter_untrustedTelegramYoloStillBlocksInstallApp() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object([
                "default": .string("send_approval"),
                "install_app": .string("confirm"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("untrusted install attempt")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:999", isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("not trusted") })
}

@Test func SecurityCenter_localYoloTreatsNativeToolsAsAutonomyAuto() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object([
                "restart_app": .string("confirm"),
                "install_app": .string("confirm"),
                "default": .string("send_approval"),
            ]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    for tool in ["restart_app", "install_app"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
        )

        #expect(envelope.allowed)
        #expect(envelope.decision == .allow)
        #expect(envelope.autonomyLevel == "auto")
        #expect(!envelope.reasons.contains { $0.contains("tool autonomy requires approval") })
    }
}

@Test func SecurityCenter_localYoloStillRequiresApprovalForExternalSends() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(true),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object(["default": .string("auto")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "email.send",
        input: ["to": .string("someone@example.com"), "body": .string("hello")],
        origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
    )

    #expect(envelope.allowed == false)
    #expect(envelope.decision == .ask)
    #expect(envelope.reasons.contains { $0.contains("external send requires approval") })
}

/// Self-modification (self_install / evolution_propose) keeps MAXIMUM defense:
/// a local yolo window does NOT satisfy their Developer-Mode requirement, so the
/// dev-mode block still fires even locally. Yolo never rides the self-evolution
/// surface (rampancy firewall).
@Test func SecurityCenter_selfModification_stillRequiresDeveloperMode_evenInLocalYolo() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(false),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    for tool in ["self_install", "evolution_propose"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat", sessionId: "local", isRemote: false)
        )
        // Dev-mode block MUST fire — yolo does not cover self-modification.
        #expect(
            envelope.reasons.contains { $0.contains("Developer Mode") },
            "\(tool) must still require Developer Mode in a local yolo window"
        )
    }
}

@Test func SecurityCenter_ignores_model_supplied_remote_command_signature() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    // trustedRemoteHighRiskAllowed=false keeps the signed-command gate LIVE so this
    // test exercises its real intent: a model-supplied `command_signature` in the
    // tool INPUT must never count as a real signature (only the ingress layer sets
    // origin.commandSignatureVerified). With the waiver disabled, the forged input
    // field is ignored and the unsigned remote high-risk call still blocks.
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "securityPolicy": .object(["trustedRemoteHighRiskAllowed": .bool(false)]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "mac.shell",
        input: [
            "command": .string("whoami"),
            "command_signature": .string("fake-model-supplied-signature"),
        ],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("unsigned") })
}

@Test func SecurityCenter_accepts_ingress_verified_remote_command_signature() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "mac.shell",
        input: ["command": .string("whoami")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:123",
            isRemote: true,
            commandSignatureVerified: true
        )
    )

    #expect(envelope.originTrusted)
    #expect(!envelope.reasons.contains { $0.contains("unsigned") })
}

@Test func SecurityCenter_trusts_telegram_private_chat_when_user_allowlisted() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_user_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "mobile.notify",
        input: ["message": .string("ping")],
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", isRemote: true)
    )

    #expect(envelope.originTrusted)
    #expect(envelope.originTrustReason == "telegram private user allowlist matched")
    #expect(envelope.allowed)
    #expect(!envelope.reasons.contains { $0.contains("not configured") })
}

@Test func SecurityCenter_trusts_telegram_group_origin_when_user_id_allowlisted() async throws {
    let root = try makeSecurityTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_user_ids": .array([.int(456)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(
            surface: "telegram",
            userId: "456",
            chatId: "-999",
            isRemote: true
        )
    )

    #expect(envelope.originTrusted)
    #expect(envelope.originTrustReason == "telegram user allowlist matched")
    #expect(envelope.allowed)
}

@Test func SecurityCenter_status_exposes_ten_security_flags() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let status = await center.status()

    #expect(status.status == "ready")
    #expect(status.flags.count == 10)
    #expect(Set(status.flags.map(\.id)).contains("security_center"))
    #expect(Set(status.flags.map(\.id)).contains("audit_receipts"))
}
