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

private func seedAdmittedFullMacAuthority(
    at root: URL,
    blockedTool: String? = nil
) throws {
    let trust = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
    var autonomy: [String: JSONValue] = ["default": .string("send_approval")]
    if let blockedTool { autonomy[blockedTool] = .string("blocked") }
    let policy: JSONValue = .object([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
        "toolAutonomy": .object(autonomy),
        "iosRemotePolicy": .object(["remote_from_ios_allowed": .bool(true)]),
        "connectorPolicy": .object(["sendExternalMessagesRequiresApproval": .bool(true)]),
    ])
    try policy.serializedData(pretty: false)
        .write(to: trust.appendingPathComponent("policy.json"))

    let telegram = root.appendingPathComponent("telegram", isDirectory: true)
    try FileManager.default.createDirectory(at: telegram, withIntermediateDirectories: true)
    try JSONValue.object(["allowed_chat_ids": .array([.string("tg-user")])])
        .serializedData(pretty: false)
        .write(to: telegram.appendingPathComponent("config.json"))

    let slack = root.appendingPathComponent("connectors/slack", isDirectory: true)
    try FileManager.default.createDirectory(at: slack, withIntermediateDirectories: true)
    try JSONValue.object(["allowed_channel_ids": .array([.string("slack-user")])])
        .serializedData(pretty: false)
        .write(to: slack.appendingPathComponent("auth.json"))
}

@Test func SecurityCenter_fullMacYoloAuthority_admitsEveryAuthenticatedOperatorSurface() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedAdmittedFullMacAuthority(at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let cases: [(String, SecurityOriginContext)] = [
        ("local chat", .init(surface: "chat")),
        ("Codex bridge", .init(surface: "codex-bridge")),
        ("mission", .init(surface: "mission")),
        ("Telegram", .init(surface: "telegram", chatId: "tg-user", isRemote: true)),
        ("Slack", .init(surface: "slack", chatId: "slack-user", isRemote: true)),
        ("iOS", .init(surface: "ios", deviceId: "paired-phone", isRemote: true)),
    ]
    for (label, origin) in cases {
        let authority = await center.fullMacYoloAuthority(
            tool: "approval_shaped_tool",
            origin: origin
        )
        #expect(authority.state == .admitted, "\(label): \(authority.reason)")
    }
}

@Test func SecurityCenter_fullMacYoloAuthority_failsClosedForExplicitBlockOutsiderExpiryAndCorruption() async throws {
    let blockedRoot = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: blockedRoot) }
    try seedAdmittedFullMacAuthority(at: blockedRoot, blockedTool: "never_run")
    let blockedCenter = SwiftNativeSecurityCenter(dataRoot: blockedRoot)
    #expect(await blockedCenter.fullMacYoloAuthority(
        tool: "never_run", origin: .init(surface: "chat")
    ).state == .explicitlyBlocked)
    let explicitlyBlockedEnvelope = await blockedCenter.evaluateTool(
        tool: "never_run",
        input: [:],
        origin: .init(surface: "chat"),
        enforceAutonomy: false
    )
    #expect(explicitlyBlockedEnvelope.decision == .block)
    #expect(!explicitlyBlockedEnvelope.requiresApproval)
    #expect(await blockedCenter.fullMacYoloAuthority(
        tool: "shell",
        origin: .init(surface: "telegram", chatId: "outsider", isRemote: true)
    ).state == .untrustedOrigin)

    let expiredRoot = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: expiredRoot) }
    let trust = expiredRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
    try JSONValue.object([
        "permissionLevel": .string("full_mac_os"),
        "fullMacExpiresAt": .string("2020-01-01T00:00:00Z"),
    ]).serializedData(pretty: false).write(to: trust.appendingPathComponent("policy.json"))
    #expect(await SwiftNativeSecurityCenter(dataRoot: expiredRoot).fullMacYoloAuthority(
        tool: "shell", origin: .init(surface: "chat")
    ).state == .inactive)

    let corruptRoot = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let corruptPolicy = corruptRoot.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: corruptPolicy.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{bad".utf8).write(to: corruptPolicy)
    #expect(await SwiftNativeSecurityCenter(dataRoot: corruptRoot).fullMacYoloAuthority(
        tool: "shell", origin: .init(surface: "chat")
    ).state == .unavailable)
}

@Test func SecurityCenter_directClientsNeverReceiveAskUnderAdmittedFullMacYolo() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedAdmittedFullMacAuthority(at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    for tool in [
        "self_install", "evolution_propose", "remote_node_execute",
        "gmail.send", "slack.post_message", "mac_keystroke",
    ] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: .init(surface: "chat")
        )
        #expect(envelope.decision == .allow, "\(tool): \(envelope.reasons)")
        #expect(!envelope.requiresApproval, "\(tool) must not return ask")
        #expect(envelope.fullMacYoloAuthority == .admitted)
    }

    let permissionReset = await center.evaluateTool(
        tool: "bash",
        input: ["cmd": .string("tccutil reset Accessibility")],
        origin: .init(surface: "chat")
    )
    #expect(permissionReset.decision == .block)
    #expect(!permissionReset.requiresApproval)
}

/// Delegates every read to the real persistence backend but rejects audit
/// appends, modeling disk-full/permission failure at SecurityCenter.record's
/// actual write seam.
private struct SecurityAuditAppendFailingPersistence: PersistenceCoreProtocol {
    let delegate: SwiftNativePersistenceCore
    struct WriteFailure: Error {}

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await delegate.readJSON(path, defaultValue: defaultValue)
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await delegate.writeJSON(value, to: path)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        throw WriteFailure()
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await delegate.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }

    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await delegate.readJSONL(path)
    }
}

// Eval coverage ledger — `core.trust.securityCenter.receiptSummary`.
// A malformed authority receipt must disappear as unavailable evidence; it
// must never become a fresh blank UI row on each refresh.
@Test func SecurityCenter_receiptSummary_projectsOnlyCompleteStableReceipts() {
    let valid: JSONValue = .object([
        "id": .string("receipt-42"),
        "created_at": .string("2026-08-24T12:00:00Z"),
        "tool": .string("write_file"),
        "surface": .string("chat"),
        "decision": .string("confirm"),
        "risk": .string("high"),
        "reasons": .array([.string("outside workspace")]),
    ])
    let summary = SwiftNativeSecurityCenter.receiptSummary(valid)
    #expect(summary?.id == "receipt-42")
    #expect(summary?.at == "2026-08-24T12:00:00Z")
    #expect(summary?.tool == "write_file")
    #expect(summary?.surface == "chat")
    #expect(summary?.decision == "confirm")
    #expect(summary?.risk == "high")
    #expect(summary?.reason == "outside workspace")

    // No synthetic UUID / empty-string summary may escape for damaged rows.
    for key in ["id", "created_at", "tool", "surface", "decision", "risk"] {
        guard case .object(var damaged) = valid else { Issue.record("fixture is not an object"); return }
        damaged.removeValue(forKey: key)
        #expect(SwiftNativeSecurityCenter.receiptSummary(.object(damaged)) == nil,
                "receipt missing \(key) must remain unavailable")
    }
    #expect(SwiftNativeSecurityCenter.receiptSummary(.object([
        "id": .string(" "), "created_at": .string("now"), "tool": .string("x"),
        "surface": .string("chat"), "decision": .string("allow"), "risk": .string("low"),
    ])) == nil)
}

@Test func SecurityCenter_canonicalToolRiskProjectsExistingProfileWithoutAuthority() throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(SwiftNativeSecurityCenter.canonicalToolRisk(
        tool: "read_file",
        input: ["path": .string(root.appendingPathComponent("note.txt").path)],
        dataRoot: root
    ) == .low)
    #expect(SwiftNativeSecurityCenter.canonicalToolRisk(
        tool: "write_file",
        input: ["path": .string("/tmp/outside-nativeagent.txt")],
        dataRoot: root
    ) == .high)
    #expect(SwiftNativeSecurityCenter.canonicalToolRisk(
        tool: "shell",
        input: ["command": .string("true")],
        dataRoot: root
    ) == .critical)
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

// F5 (2026-08-28): the first byte-triggered trim archives the pre-trim ledger
// to a sibling `audit-archive-<date>.jsonl` — once, ever — so lowering the
// trigger to a value that actually fires cannot silently drop the accumulated
// history. Later crossings must never mint a second archive.
@Test func SecurityCenter_archivesAuditOnceBeforeFirstByteTriggeredTrim() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let securityDir = root.appendingPathComponent("security", isDirectory: true)
    let auditPath = securityDir.appendingPathComponent("audit.jsonl")
    try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)

    // Seed past BOTH bounds (byte trigger and row cap) so the append trims.
    let pad = String(repeating: "x", count: 1_024)
    let seededRows = JSONLLineCaps.securityAudit + 1_000
    var seed = ""
    seed.reserveCapacity(seededRows * (pad.utf8.count + 24))
    for i in 0..<seededRows { seed += "{\"i\":\(i),\"pad\":\"\(pad)\"}\n" }
    #expect(seed.utf8.count >= JSONLLineCaps.securityAuditTrimTriggerBytes)
    try Data(seed.utf8).write(to: auditPath)

    let persistence = SwiftNativePersistenceCore()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let envelope = await center.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    try await center.record(envelope)

    func archiveFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: securityDir, includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("audit-archive-")
                && $0.lastPathComponent.hasSuffix(".jsonl")
        }
    }

    let archives = try archiveFiles()
    #expect(archives.count == 1, "first trigger crossing archives exactly once")
    let completionMarker = securityDir.appendingPathComponent(
        ".audit-pretrim-archive-complete-v1"
    )
    #expect(FileManager.default.fileExists(atPath: completionMarker.path))
    if let archive = archives.first {
        #expect(
            try Data(contentsOf: archive) == Data(seed.utf8),
            "archive is the verbatim pre-trim ledger"
        )
    }
    let hotLines = try String(contentsOf: auditPath, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(hotLines.count == JSONLLineCaps.securityAudit, "trim applied the row cap")
    #expect(hotLines.last?.contains("tool_catalog") == true, "newest receipt survives")

    // A later crossing (the trimmed file is still above the trigger here)
    // must trust the durable completion marker rather than enumerate archives
    // or create another. Removing the temp archive proves the marker is the
    // durable decision, not merely a cache of the directory listing.
    if let archive = archives.first { try FileManager.default.removeItem(at: archive) }
    try await center.record(envelope)
    #expect(try archiveFiles().isEmpty)
}

// F5 review fix (gpt-5.5, HIGH): stride appends enforce the ROW cap with no
// byte gate, so a compact over-cap ledger UNDER the byte trigger is trimmed
// on the first append to its path. The one-shot archive must fire on that
// path too — bytes >= trigger is not the only door rows can drop through.
@Test func SecurityCenter_archivesAuditBeforeRowCapTrimBelowByteTrigger() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let securityDir = root.appendingPathComponent("security", isDirectory: true)
    let auditPath = securityDir.appendingPathComponent("audit.jsonl")
    try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)

    // Exactly at the row cap, comfortably under the byte trigger. The pending
    // append is what crosses the boundary, so the pre-append archive guard must
    // treat equality as a potential trim rather than waiting one row too late.
    let seededRows = JSONLLineCaps.securityAudit
    let seed = (0..<seededRows).map { "{\"i\":\($0)}" }.joined(separator: "\n") + "\n"
    #expect(seed.utf8.count < JSONLLineCaps.securityAuditTrimTriggerBytes)
    try Data(seed.utf8).write(to: auditPath)

    let persistence = SwiftNativePersistenceCore()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let envelope = await center.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    // First append to this path: the stride counter forces a full line-cap
    // check, which drops rows despite the file being below the byte trigger.
    try await center.record(envelope)

    let archives = try FileManager.default.contentsOfDirectory(
        at: securityDir, includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.hasPrefix("audit-archive-")
            && $0.lastPathComponent.hasSuffix(".jsonl")
    }
    #expect(archives.count == 1, "row-cap trim below the byte trigger must archive first")
    if let archive = archives.first {
        #expect(
            try Data(contentsOf: archive) == Data(seed.utf8),
            "archive is the verbatim pre-trim ledger"
        )
    }
    let hotLines = try String(contentsOf: auditPath, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(hotLines.count == JSONLLineCaps.securityAudit, "row cap applied after archiving")
    #expect(hotLines.last?.contains("tool_catalog") == true, "newest receipt survives")
}

// MARK: - LEDGER: core.persistence.securityAuditEffectiveBound

@Test func SecurityCenter_auditRetentionReport_exposesByteBoundNotDeferredRowCap() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let auditPath = root
        .appendingPathComponent("security", isDirectory: true)
        .appendingPathComponent("audit.jsonl")
    try FileManager.default.createDirectory(
        at: auditPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let envelope = await center.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    // F2 (2026-08-28): the FIRST append to a path always evaluates the line
    // cap in full (`capCheckStride` fires on the 1st, stride+1th, … append),
    // so warm the stride counter up before seeding — the deferred-cap
    // behaviour this test pins is the steady state between stride checks.
    try await center.record(envelope)

    let seededCount = JSONLLineCaps.securityAudit + 1
    let seed = String(repeating: "{}\n", count: seededCount)
    #expect(seed.utf8.count < JSONLLineCaps.securityAuditTrimTriggerBytes)
    try Data(seed.utf8).write(to: auditPath)
    try await center.record(envelope)

    // The evaluation enters through the real SecurityCenter writer and reads
    // its locked audit path; it does not infer the policy by scraping source.
    let report = await center.auditRetentionReport()
    #expect(report.state == .belowTrimTrigger)
    #expect(report.effectiveBoundKind == .softByteTrimTrigger)
    #expect(report.effectiveBoundBytes == JSONLLineCaps.securityAuditTrimTriggerBytes)
    #expect(report.rowCapWhenTriggered == JSONLLineCaps.securityAudit)
    #expect(report.byteCount != nil)
    #expect(report.byteCount! < report.effectiveBoundBytes)
    #expect(report.physicalLineCount == seededCount + 1)
    // This over-row-cap feed is still healthy under the actual byte-triggered
    // policy. Treating `rowCapWhenTriggered` as the effective bound would make
    // this observation falsely report a violation.
    #expect(report.physicalLineCount! > report.rowCapWhenTriggered)

    let lines = try String(contentsOf: auditPath, encoding: .utf8).split(separator: "\n")
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

@Test func SecurityCenter_auditRetentionReport_marksDamagedEvidenceAndRecordFailureIsNotSuccess() async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let auditPath = root
        .appendingPathComponent("security", isDirectory: true)
        .appendingPathComponent("audit.jsonl")
    try FileManager.default.createDirectory(
        at: auditPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // A non-final malformed row is evidence damage, not an empty/healthy feed.
    try Data("{broken}\n{\"id\":\"good\"}\n".utf8).write(to: auditPath)
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let damaged = await center.auditRetentionReport()
    #expect(damaged.state == .incompleteEvidence)
    #expect(damaged.physicalLineCount == 2)
    #expect(damaged.evidenceIssue?.contains("malformed") == true)

    let failingCenter = SwiftNativeSecurityCenter(
        dataRoot: root,
        persistence: SecurityAuditAppendFailingPersistence(delegate: SwiftNativePersistenceCore())
    )
    let envelope = await failingCenter.evaluateTool(
        tool: "tool_catalog",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    await #expect(throws: (any Error).self) {
        try await failingCenter.record(envelope)
    }
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: a critical-risk process tool with Developer Mode off was
/// BLOCKED with a "Developer Mode" reason (`criticalRequiresDeveloperMode`
/// defaulted true). NEW CONTRACT: that default is false, so the classification
/// is unchanged — still critical — but it no longer blocks. Risk CLASS is what
/// this row pins now; the gates that remain are the perimeter and the Trust
/// Center categories.
@Test func SecurityCenter_shell_isCriticalButNoLongerDeveloperModeBlocked() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "mac.shell",
        input: ["command": .string("ls -la")],
        origin: SecurityOriginContext(surface: "chat")
    )

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.risk == "critical", "the risk CLASSIFICATION is unchanged")
    #expect(!envelope.reasons.contains { $0.contains("Developer Mode") })
}

@Test func SecurityCenter_classifies_swiftpm_builders_as_critical_process_tools() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): the CLASSIFICATION this row
    // is named for is unchanged — swiftpm builders are still critical process
    // tools. What moved is the consequence: `criticalRequiresDeveloperMode`
    // defaults false, so critical no longer implies block.
    for tool in ["swift_build", "swift_test"] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )

        #expect(envelope.risk == "critical", "\(tool) is still classified critical")
        #expect(envelope.allowed)
        #expect(envelope.decision == .allow)
        #expect(!envelope.reasons.contains { $0.contains("Developer Mode") })
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

@Test func SecurityCenter_chromeFormActsAndWaitHaveExactBuiltinProfiles() async throws {
    let root = try makeSecurityTempRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in [
        "browser.chrome_fill", "browser.chrome_type", "browser.chrome_select",
        "browser.chrome_keypress", "browser.chrome_set_checked", "browser.chrome_double_click",
    ] {
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.tool == tool)
        #expect(envelope.signedToolKnown)
        #expect(envelope.risk == "high")
        #expect(envelope.capabilities.contains("browser_interaction"))
    }

    for tool in ["browser.chrome_wait", "browser.chrome_renew"] {
        // Sweep item 10c: a renew touches the lease's expiry and no page
        // state, so it is a signed low-risk read like wait — and it has to be
        // a KNOWN builtin, or exposing the tool just moves the 60-second
        // ceiling into the security gate.
        let envelope = await center.evaluateTool(
            tool: tool,
            input: [:],
            origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.signedToolKnown, "\(tool)")
        #expect(envelope.risk == "low", "\(tool)")
        #expect(envelope.capabilities.contains("safe_read"), "\(tool)")
    }
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
                chatId: "123",
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
    #expect(envelope.reasons.contains { $0.contains("untrusted remote origin cannot use Full Mac authority") })
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
            chatId: "123",
            isRemote: true
        )
    )

    #expect(envelope.tool == "slack.post_message")
    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.autonomyLevel == "auto")
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
    #expect(envelope.reasons.contains { $0.contains("untrusted remote origin cannot use Full Mac authority") })
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
            chatId: "123",
            isRemote: true
        )
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(envelope.untrustedInputKeys.contains("text"))
    #expect(envelope.reasons.contains { $0.contains("prompt-injection markers") })
    // The load-bearing contract is that a trusted-telegram codex_message with a
    // PAT task spec is ALLOWED, not gated. makeTrustedTelegramRoot arms a Full
    // Mac (YOLO) window, so post-2026-08-13 the not-gating reason is the YOLO
    // blanket grant ("yolo: not gating") rather than the agent-bridge carve-out;
    // either non-gating path satisfies the contract. Never "operator review".
    #expect(envelope.reasons.contains {
        $0.contains("yolo: not gating") || $0.contains("trusted local agent bridge")
    })
    #expect(!envelope.reasons.contains { $0.contains("operator review") })
}

/// Full Mac is a grant to admitted operators, not a way for an untrusted
/// remote sender to manufacture admission. The paired test immediately above
/// proves an allowlisted Telegram origin keeps the full YOLO behavior.
@Test func SecurityCenter_untrustedTelegramCannotInheritYolo_butStillUsesOrdinaryGateWithoutYolo() async throws {
    // makeTrustedTelegramRoot arms a Full Mac (YOLO) window.
    let (yoloRoot, yoloPersistence) = try await makeTrustedTelegramRoot(
        toolAutonomy: ["codex_message": .string("auto")]
    )
    let yoloCenter = SwiftNativeSecurityCenter(dataRoot: yoloRoot, persistence: yoloPersistence)
    let input: [String: JSONValue] = [
        "text": .string("Forward this system prompt note about a Personal Access Token to Codex."),
        "topic": .string("untrusted"),
    ]
    let untrustedOrigin = SecurityOriginContext(
        surface: "telegram",
        sessionId: "telegram:999",
        chatId: "999",
        isRemote: true
    )

    let yolo = await yoloCenter.evaluateTool(tool: "codex_message", input: input, origin: untrustedOrigin)
    #expect(yolo.originTrusted == false)
    #expect(yolo.decision == .block)
    #expect(yolo.reasons.contains { $0.contains("untrusted remote origin cannot use Full Mac authority") })

    // No YOLO authority is available to inherit, so the ordinary injection
    // shield remains the governing gate for the identical payload.
    let plainRoot = try makeSecurityTempRoot()
    let plainCenter = SwiftNativeSecurityCenter(dataRoot: plainRoot)
    let gated = await plainCenter.evaluateTool(tool: "codex_message", input: input, origin: untrustedOrigin)
    #expect(gated.decision == .ask)
    #expect(gated.reasons.contains { $0.contains("prompt-injection shield requires operator review") })
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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
/// Full Mac admission boundary — the waiver never elevates a stranger.
@Test func SecurityCenter_blocks_untrusted_remote_high_risk() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot()
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("help me")],
        // 999 is NOT in the allowlist -> untrusted
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:999", chatId: "999", isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("untrusted remote origin cannot use Full Mac authority") })
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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

/// Full Mac keeps ordinary autonomous builder work, but changing the host's
/// permission authority is a distinct hard effect. YOLO never turns it into an
/// approval prompt or an allow; it remains blocked while ordinary diagnostics
/// and builder work run autonomously.
@Test func SecurityCenter_systemPermissionResetRemainsBlockedUnderTrustedYolo() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(
        toolAutonomy: ["bash": .string("auto")]
    )
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let origin = SecurityOriginContext(
        surface: "telegram",
        sessionId: "telegram:123",
        chatId: "123",
        isRemote: true
    )

    for command in [
        "tccutil reset SpeechRecognition com.example.nativeagent",
        "/usr/bin/tccutil reset Microphone com.example.app",
        "sudo tccutil reset All",
    ] {
        let envelope = await center.evaluateTool(
            tool: "bash",
            input: ["cmd": .string(command)],
            origin: origin,
            enforceAutonomy: false
        )
        #expect(envelope.originTrusted)
        #expect(envelope.decision == .block, "\(command)")
        #expect(!envelope.requiresApproval)
        #expect(!envelope.allowed)
        #expect(envelope.rollbackRequired)
        #expect(envelope.capabilities.contains("system_permission_reset"))
        #expect(envelope.capabilities.contains("destructive"))
        #expect(envelope.reasons.contains { $0.contains("system permission changes require explicit approval") })
    }

    let routine = await center.evaluateTool(
        tool: "bash",
        input: ["cmd": .string("git status --short")],
        origin: origin,
        enforceAutonomy: false
    )
    #expect(routine.decision == .allow)
    #expect(routine.allowed)
    #expect(!routine.capabilities.contains("system_permission_reset"))

    let diagnostic = await center.evaluateTool(
        tool: "bash",
        input: [
            "cmd": .string(
                "sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db "
                    + "\"SELECT client, auth_value FROM access WHERE service='kTCCServiceSpeechRecognition';\"; "
                    + "git status --short"
            )
        ],
        origin: origin,
        enforceAutonomy: false
    )
    #expect(diagnostic.decision == .allow)
    #expect(diagnostic.allowed)
    #expect(!diagnostic.requiresApproval)
    #expect(!diagnostic.capabilities.contains("system_permission_reset"))

    let directMutation = await center.evaluateTool(
        tool: "bash",
        input: [
            "cmd": .string(
                "sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db "
                    + "\"DELETE FROM access WHERE service='kTCCServiceSpeechRecognition';\""
            )
        ],
        origin: origin,
        enforceAutonomy: false
    )
    #expect(directMutation.decision == .block)
    #expect(!directMutation.requiresApproval)
    #expect(directMutation.capabilities.contains("system_permission_reset"))
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
                chatId: "123",
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
            chatId: "999",
            isRemote: true
        )
    )

    #expect(!envelope.originTrusted)
    #expect(envelope.autonomyLevel == "send_approval")
    #expect(!envelope.allowed)
    // An unadmitted remote origin stops before the autonomy approval stage.
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("untrusted remote origin cannot use Full Mac authority") })
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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

@Test(arguments: [true, false])
func SecurityCenter_signedIOSFullMacNeedsNoLegacySwitch(verified: Bool) async throws {
    let root = try makeSecurityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(.object([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["default": .string("send_approval")]),
    ]), to: root.appendingPathComponent("trust/policy.json"))
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    for surface in ["ios", "icloud", "iphone", "ipad", "mobile", "watch"] {
        for tool in ["commit_memory", "install_app"] {
            let result = await center.evaluateTool(
                tool: tool, input: [:],
                origin: SecurityOriginContext(surface: surface, isRemote: true,
                                              commandSignatureVerified: verified))
            #expect(result.originTrusted == verified)
            #expect(result.allowed == verified)
            if verified { #expect(result.decision == .allow) }
        }
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:999", chatId: "999", isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    #expect(envelope.reasons.contains { $0.contains("untrusted remote origin cannot use Full Mac authority") })
}

@Test func SecurityCenter_corruptTelegramAdmissionCannotReachYolo() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(
        toolAutonomy: ["default": .string("send_approval")]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("telegram", isDirectory: true)
        .appendingPathComponent("config.json")
    try Data("{\"allowed_chat_ids\":[123]".utf8).write(to: config, options: .atomic)
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("corrupt admission must not inherit Full Mac")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:123",
            chatId: "123",
            isRemote: true
        )
    )

    #expect(!envelope.originTrusted)
    #expect(!envelope.allowed)
    #expect(envelope.decision == .block)
    #expect(envelope.autonomyLevel != "auto")
    #expect(envelope.reasons.contains { $0.contains("allowlist not configured") })
}

@Test func SecurityCenter_remoteAdmissionNamespacesDoNotCrossUnderYolo() async throws {
    let (root, persistence) = try await makeTrustedTelegramRoot(
        toolAutonomy: ["default": .string("send_approval")]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let slackDir = root.appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("slack", isDirectory: true)
    try FileManager.default.createDirectory(at: slackDir, withIntermediateDirectories: true)
    try Data(#"{"allowed_channel_ids":["C123"]}"#.utf8)
        .write(to: slackDir.appendingPathComponent("auth.json"), options: .atomic)
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let admittedTelegram = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("admitted Telegram")],
        origin: SecurityOriginContext(surface: "telegram", chatId: "123", isRemote: true)
    )
    let admittedSlack = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("admitted Slack")],
        origin: SecurityOriginContext(surface: "slack", chatId: "C123", isRemote: true)
    )
    #expect(admittedTelegram.originTrusted)
    #expect(admittedTelegram.allowed)
    #expect(admittedTelegram.autonomyLevel == "auto")
    #expect(admittedSlack.originTrusted)
    #expect(admittedSlack.allowed)
    #expect(admittedSlack.autonomyLevel == "auto")

    let telegramUsingSlackCredential = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("cross-surface Telegram claim")],
        origin: SecurityOriginContext(surface: "telegram", chatId: "C123", isRemote: true)
    )
    let slackUsingTelegramCredential = await center.evaluateTool(
        tool: "install_app",
        input: ["reason": .string("cross-surface Slack claim")],
        origin: SecurityOriginContext(surface: "slack", chatId: "123", isRemote: true)
    )
    for envelope in [telegramUsingSlackCredential, slackUsingTelegramCredential] {
        #expect(!envelope.originTrusted)
        #expect(!envelope.allowed)
        #expect(envelope.decision == .block)
        #expect(envelope.autonomyLevel != "auto")
        #expect(envelope.reasons.contains { $0.contains("not in allowlist") })
    }
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

@Test func SecurityCenter_localYoloSuppressesExternalSendApproval() async throws {
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

    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
    #expect(!envelope.requiresApproval)
    #expect(envelope.reasons.contains { $0.contains("external send requires approval") })
    #expect(envelope.reasons.contains { $0.contains("suppresses per-call approval") })
}

/// Saved confirm defaults remain visible policy data, but admitted YOLO is the
/// effect-time operator authority and resolves them without a per-call prompt.
@Test func SecurityCenter_selfModificationHasNoPerCallPromptInLocalYolo() async throws {
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
        #expect(envelope.decision == .allow)
        #expect(envelope.autonomyLevel == "auto")
        #expect(!envelope.requiresApproval)
        #expect(
            !envelope.reasons.contains { $0.contains("Developer Mode") },
            "\(tool): SecurityCenter no longer raises a Developer Mode block"
        )
        guard case .object(let ta)? = await SwiftNativeTrustCenter(dataRoot: root)
            .loadTrustPolicy()["toolAutonomy"] else {
            Issue.record("expected toolAutonomy in the merged policy"); continue
        }
        #expect(ta[tool] == .string("confirm"),
                "saved preset remains confirm; admitted authority owns the runtime override")
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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
            chatId: "123",
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
        origin: SecurityOriginContext(surface: "telegram", sessionId: "telegram:123", chatId: "123", isRemote: true)
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
