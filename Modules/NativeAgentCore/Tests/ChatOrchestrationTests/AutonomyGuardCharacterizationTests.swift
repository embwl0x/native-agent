import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter

// =============================================================================
// AUTONOMY-GUARD CHARACTERIZATION NET  (U4 Wave A)
// =============================================================================
//
// This is the Swift rebuild of the daemon-era 39-test guard net
// (tests/test_autonomy_guard_characterization.py). It PINS the CURRENT
// behavior of the 4-layer tool-gate stack so any future security refactor
// that silently changes a gate DECISION turns one of these RED on purpose.
//
// THE LOAD-BEARING RULE: the EXPECTED decision in each #expect was traced
// from the live gate source. If a test goes red, do NOT "fix" the assertion
// to match — a red row means reality diverged from the pinned expectation,
// which is a security-relevant signal for the orchestrator to resolve.
//
// All tests are tagged with the `.autonomyGuard` suite prefix in their names
// so the whole net runs with:
//   swift test --filter AutonomyGuardCharacterization
//
// Layer map (outer → inner on the production chat chain,
// ChatOrchestrationClient.swift:1252):
//   AutonomyGatedDispatcher( FileAccessGatedDispatcher( SwiftToolDispatcher ) )
//   - AutonomyGatedDispatcher: SecurityCenter.evaluateTool(enforceAutonomy:false)
//     THEN gate.autonomyLevel → AutonomyGate.map. hasFiler:false ⇒ honest throw.
//   - FileAccessGatedDispatcher: per-mode (none/read_only/allow) name block list.
//   - SwiftToolDispatcher: catalog/visibility (includeFullMacFileTools).
//
// =============================================================================

// MARK: - Fixtures

/// A fresh temp dataRoot for one scenario.
private func agcTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutonomyGuard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writePolicy(_ policy: JSONValue, to root: URL, _ persistence: SwiftNativePersistenceCore) async throws {
    try await persistence.writeJSON(
        policy,
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
}

private func writeTelegramConfig(_ config: JSONValue, to root: URL, _ persistence: SwiftNativePersistenceCore) async throws {
    try await persistence.writeJSON(
        config,
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )
}

/// PERSONAL fixture — mirrors the user's live machine: Full Mac never-expiring,
/// Developer Mode on, outside-workspace writes allowed, everything auto.
private func personalPolicy() -> JSONValue {
    .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object([
            "default": .string("auto"),
            "restart_app": .string("auto"),
            "install_app": .string("auto"),
        ]),
    ])
}

/// SHELL_CONFIRM_NO_WINDOW — a NON-Full-Mac policy (balanced permission,
/// outside-workspace writes denied) with Developer Mode on (so the critical-tool
/// security gate still passes for `shell`) and shell pinned to confirm.
/// Exercises the confirm/no-filer honest-throw path.
///
/// NOTE (2026-06-13): this fixture must NOT be Full-Mac. Under an active yolo
/// window a confirm-pinned BUILDER tool (shell) auto-elevates to `auto` on the
/// local "chat" surface (the U4 "yolo unlocks builder tools" feature, ab57ab2d),
/// which overrides the confirm pin BEFORE the per-tool autonomy is consulted —
/// so the row would never reach the no-filer throw it is named for. (The earlier
/// `full_mac_os` + outside-allow form counted as an active window even without
/// explicit expiry keys, which is what regressed this test when yolo shipped.)
/// The yolo-elevation path itself is covered by BuilderToolYoloAutonomyTests.
private func personalShellConfirmPolicy() -> JSONValue {
    .object([
        "permissionLevel": .string("balanced"),
        "developerMode": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")]),
        "toolAutonomy": .object([
            "default": .string("auto"),
            "restart_app": .string("auto"),
            "install_app": .string("auto"),
            "shell": .string("confirm"),
        ]),
    ])
}
// LOCKED is "no policy.json written at all" — represented by simply not calling
// writePolicy on the root.

// MARK: - SC suite — SecurityCenter.evaluateTool(enforceAutonomy:false), local "chat"
//
// enforceAutonomy:false matches how AutonomyGatedDispatcher calls evaluateTool —
// the autonomy decision is taken SEPARATELY (gate.autonomyLevel). So these rows
// isolate the SecurityCenter security gates, independent of autonomy level.

private func scCenter(personal: Bool) async throws -> SwiftNativeSecurityCenter {
    let root = try agcTempRoot()
    let persistence = SwiftNativePersistenceCore()
    if personal {
        try await writePolicy(personalPolicy(), to: root, persistence)
    }
    return SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
}

private func scEvaluate(_ center: SwiftNativeSecurityCenter, _ tool: String) async -> SecurityToolEnvelope {
    await center.evaluateTool(
        tool: tool,
        input: [:],
        origin: SecurityOriginContext(surface: "chat"),
        enforceAutonomy: false
    )
}

@Test func AutonomyGuardCharacterization_SC_personal_low_and_memory_tools_allow() async throws {
    let center = try await scCenter(personal: true)
    for tool in ["read_file", "recall_memory", "commit_memory", "workshop_status", "workshop_submit"] {
        let env = await scEvaluate(center, tool)
        #expect(env.decision == .allow, "SC PERSONAL \(tool) expected allow, got \(env.decision.rawValue) — \(env.reasons)")
        #expect(env.allowed, "SC PERSONAL \(tool) expected allowed=true")
    }
}

@Test func AutonomyGuardCharacterization_SC_personal_shell_class_allow() async throws {
    let center = try await scCenter(personal: true)
    // devMode true ⇒ critical gate passes; all signed/local. SHELL ALLOWS here.
    for tool in ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test", "restart_app", "install_app", "invoke_claude"] {
        let env = await scEvaluate(center, tool)
        #expect(env.decision == .allow, "SC PERSONAL \(tool) expected allow, got \(env.decision.rawValue) — \(env.reasons)")
        #expect(env.allowed, "SC PERSONAL \(tool) expected allowed=true")
    }
}

@Test func AutonomyGuardCharacterization_SC_locked_read_file_allow() async throws {
    let center = try await scCenter(personal: false)
    let env = await scEvaluate(center, "read_file")
    #expect(env.decision == .allow, "SC LOCKED read_file expected allow, got \(env.decision.rawValue) — \(env.reasons)")
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: with no policy.json at all (LOCKED), the shell class was
/// BLOCKED by SecurityCenter's `criticalRequiresDeveloperMode` gate, with a
/// "Developer Mode" reason. NEW CONTRACT: that default flipped to `false`
/// (84fb8201, item 6) along with `toolSigningRequired` (item 5), so a LOCKED
/// local caller is ALLOWED — Developer Mode is no longer a wall in front of
/// execution. What still gates is the perimeter: a caller that never passed
/// the local window / bridge token / Telegram allowlist never reaches here.
@Test func AutonomyGuardCharacterization_SC_locked_shell_class_allows_noDeveloperModeBlock() async throws {
    let center = try await scCenter(personal: false)
    for tool in ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test", "restart_app", "install_app"] {
        let env = await scEvaluate(center, tool)
        #expect(env.decision == .allow, "SC LOCKED \(tool) expected allow, got \(env.decision.rawValue) — \(env.reasons)")
        #expect(env.allowed, "SC LOCKED \(tool) expected allowed=true")
        #expect(!env.reasons.contains { $0.contains("Developer Mode") },
                "SC LOCKED \(tool) must carry no Developer Mode block reason, got \(env.reasons)")
    }
}

/// PINNED, real, and non-obvious: invoke_claude under LOCKED still ALLOWS.
/// It is HIGH risk (not critical), signed (built-in), and local — so no
/// SecurityCenter gate blocks it. (Gate 1/2 need remote; critical-devMode gate
/// needs risk==critical; unsigned gate needs unsigned.) If this ever flips to
/// block, a refactor changed invoke_claude's risk class or signing — a real
/// security signal, NOT a test to "fix".
@Test func AutonomyGuardCharacterization_SC_locked_invoke_claude_allow() async throws {
    let center = try await scCenter(personal: false)
    let env = await scEvaluate(center, "invoke_claude")
    #expect(env.risk == "high", "SC LOCKED invoke_claude expected high risk, got \(env.risk)")
    #expect(env.decision == .allow,
            "SC LOCKED invoke_claude expected ALLOW (high, not critical, signed, local), got \(env.decision.rawValue) — \(env.reasons)")
    #expect(env.allowed, "SC LOCKED invoke_claude expected allowed=true")
}

// MARK: - SC_REMOTE suite — evaluateTool(enforceAutonomy:false), remote surfaces
//
// PERSONAL policy so Developer Mode is not the blocker; the remote trust gates
// (Gate 1 origin trust, Gate 2 signed-command waiver) are the subject.

private func remoteCenter(
    telegramConfig: JSONValue? = nil,
    extraPolicy: [String: JSONValue] = [:]
) async throws -> SwiftNativeSecurityCenter {
    let root = try agcTempRoot()
    let persistence = SwiftNativePersistenceCore()
    var policy = personalPolicy()
    if case .object(var obj) = policy {
        for (k, v) in extraPolicy { obj[k] = v }
        policy = .object(obj)
    }
    try await writePolicy(policy, to: root, persistence)
    if let telegramConfig {
        try await writeTelegramConfig(telegramConfig, to: root, persistence)
    }
    return SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
}

@Test func AutonomyGuardCharacterization_SCRemote_telegram_untrusted() async throws {
    // No telegram/config.json => allowlist empty => untrusted origin.
    let center = try await remoteCenter()
    let untrusted = SecurityOriginContext(surface: "telegram", chatId: "999", isRemote: true)

    let shell = await center.evaluateTool(tool: "shell", input: [:], origin: untrusted, enforceAutonomy: false)
    #expect(shell.decision == .block, "SC_REMOTE telegram-untrusted shell expected block, got \(shell.decision.rawValue) — \(shell.reasons)")
    #expect(shell.reasons.contains { $0.contains("remote high-risk origin is not trusted") },
            "SC_REMOTE telegram-untrusted shell expected Gate1 reason, got \(shell.reasons)")

    let invoke = await center.evaluateTool(tool: "invoke_claude", input: [:], origin: untrusted, enforceAutonomy: false)
    #expect(invoke.decision == .block, "SC_REMOTE telegram-untrusted invoke_claude expected block, got \(invoke.decision.rawValue) — \(invoke.reasons)")
    #expect(invoke.reasons.contains { $0.contains("remote high-risk origin is not trusted") },
            "SC_REMOTE telegram-untrusted invoke_claude expected Gate1 reason, got \(invoke.reasons)")

    // read_file is low risk — Gate 1 needs >= high, so it ALLOWS even untrusted.
    let read = await center.evaluateTool(tool: "read_file", input: [:], origin: untrusted, enforceAutonomy: false)
    #expect(read.decision == .allow, "SC_REMOTE telegram-untrusted read_file expected allow, got \(read.decision.rawValue) — \(read.reasons)")
}

@Test func AutonomyGuardCharacterization_SCRemote_telegram_trusted() async throws {
    let center = try await remoteCenter(telegramConfig: .object([
        "allowed_chat_ids": .array([.string("12345")]),
    ]))
    let trusted = SecurityOriginContext(surface: "telegram", chatId: "12345", isRemote: true)

    // invoke_claude (high): Gate1 passes (trusted), Gate2 waived by
    // trustedRemoteHighRiskAllowed default true.
    let invoke = await center.evaluateTool(tool: "invoke_claude", input: [:], origin: trusted, enforceAutonomy: false)
    #expect(invoke.originTrusted, "SC_REMOTE telegram-trusted invoke_claude expected originTrusted")
    #expect(invoke.decision == .allow, "SC_REMOTE telegram-trusted invoke_claude expected allow, got \(invoke.decision.rawValue) — \(invoke.reasons)")

    // shell (critical): trusted remote + devMode on ⇒ passes the critical-devMode gate too.
    let shell = await center.evaluateTool(tool: "shell", input: [:], origin: trusted, enforceAutonomy: false)
    #expect(shell.originTrusted, "SC_REMOTE telegram-trusted shell expected originTrusted")
    #expect(shell.decision == .allow, "SC_REMOTE telegram-trusted shell expected allow, got \(shell.decision.rawValue) — \(shell.reasons)")
}

@Test func AutonomyGuardCharacterization_SCRemote_ios_unpaired_blocks_invoke() async throws {
    // PERSONAL policy has no iosRemotePolicy.remote_from_ios_allowed => untrusted iOS.
    let center = try await remoteCenter()
    let ios = SecurityOriginContext(surface: "ios", isRemote: true)
    let invoke = await center.evaluateTool(tool: "invoke_claude", input: [:], origin: ios, enforceAutonomy: false)
    #expect(invoke.originTrusted == false, "SC_REMOTE ios-unpaired invoke_claude expected untrusted")
    #expect(invoke.decision == .block, "SC_REMOTE ios-unpaired invoke_claude expected block, got \(invoke.decision.rawValue) — \(invoke.reasons)")
    // gpt-5.5 review fix: pin the Gate-1 reason so a removed origin-trust gate
    // can't be masked by Gate-2 (unsigned) also blocking.
    #expect(invoke.reasons.contains { $0.contains("remote high-risk origin is not trusted") },
            "SC_REMOTE ios-unpaired invoke_claude expected Gate1 reason, got \(invoke.reasons)")
}

@Test func AutonomyGuardCharacterization_SCRemote_ios_paired_allows_invoke() async throws {
    let center = try await remoteCenter(extraPolicy: [
        "iosRemotePolicy": .object(["remote_from_ios_allowed": .bool(true)]),
    ])
    let ios = SecurityOriginContext(surface: "ios", isRemote: true)
    let invoke = await center.evaluateTool(tool: "invoke_claude", input: [:], origin: ios, enforceAutonomy: false)
    #expect(invoke.originTrusted, "SC_REMOTE ios-paired invoke_claude expected originTrusted")
    #expect(invoke.decision == .allow, "SC_REMOTE ios-paired invoke_claude expected allow, got \(invoke.decision.rawValue) — \(invoke.reasons)")
}

/// Gate-2 (signed-remote) EXISTENCE pin (gpt-5.5 review gap). A TRUSTED telegram
/// origin normally has Gate-2 WAIVED (trustedRemoteHighRiskAllowed default true).
/// With the waiver explicitly OFF and no command signature, Gate-2 must block.
/// This proves the signed-remote gate is real, not dead code masked by the waiver.
@Test func AutonomyGuardCharacterization_SCRemote_telegram_trusted_waiverOff_unsigned_blocks() async throws {
    let center = try await remoteCenter(
        telegramConfig: .object(["allowed_chat_ids": .array([.string("12345")])]),
        extraPolicy: ["securityPolicy": .object(["trustedRemoteHighRiskAllowed": .bool(false)])]
    )
    let trusted = SecurityOriginContext(surface: "telegram", chatId: "12345", isRemote: true)
    // No commandSignatureVerified → Gate 2 fires (waiver off).
    let unsigned = await center.evaluateTool(tool: "invoke_claude", input: [:], origin: trusted, enforceAutonomy: false)
    #expect(unsigned.originTrusted, "waiverOff invoke_claude still originTrusted (Gate1 passes)")
    #expect(unsigned.decision == .block, "waiverOff unsigned invoke_claude expected block, got \(unsigned.decision.rawValue) — \(unsigned.reasons)")
    #expect(unsigned.reasons.contains { $0.contains("remote high-risk command is unsigned") },
            "waiverOff unsigned invoke_claude expected Gate2 reason, got \(unsigned.reasons)")

    // WITH a verified command signature → Gate 2 passes → allow (proves the
    // signature is the actual gate, not the surface).
    let signed = SecurityOriginContext(surface: "telegram", chatId: "12345", isRemote: true, commandSignatureVerified: true)
    let signedEnv = await center.evaluateTool(tool: "invoke_claude", input: [:], origin: signed, enforceAutonomy: false)
    #expect(signedEnv.decision == .allow, "waiverOff SIGNED invoke_claude expected allow, got \(signedEnv.decision.rawValue) — \(signedEnv.reasons)")
}

/// Forge-prevention pin (gpt-5.5 review gap). A KNOWN remote surface (telegram)
/// must STAY remote even when a caller forges `isRemote:false` — remoteSurfaces
/// membership forces remoteness; isRemote can only ADD it, never subtract it.
/// If this flips to allow, the `remote = remoteSurfaces.contains || isRemote`
/// rule was weakened to let a stranger pass as local.
@Test func AutonomyGuardCharacterization_SCRemote_forged_local_still_blocks() async throws {
    let center = try await remoteCenter()  // no allowlist → untrusted
    let forged = SecurityOriginContext(surface: "telegram", chatId: "999", isRemote: false)
    let env = await center.evaluateTool(tool: "shell", input: [:], origin: forged, enforceAutonomy: false)
    #expect(env.decision == .block, "forged-local telegram shell expected block, got \(env.decision.rawValue) — \(env.reasons)")
    #expect(env.reasons.contains { $0.contains("remote high-risk origin is not trusted") },
            "forged-local telegram shell expected Gate1 reason (still remote), got \(env.reasons)")
}

// MARK: - SC_GATES suite — isolated security-gate pins (kill switch, secret firewall)
//
// gpt-5.5 review gap: the headline SC rows don't exercise the kill switch or the
// secret firewall. Both are default-on protections a refactor could silently drop.

/// Kill switch ON blocks a non-catalog tool even under PERSONAL (all other gates
/// would pass). Pins killSwitchEnabled as a real global stop.
@Test func AutonomyGuardCharacterization_SCGATES_kill_switch_blocks() async throws {
    let root = try agcTempRoot()
    let persistence = SwiftNativePersistenceCore()
    var policy = personalPolicy()
    if case .object(var obj) = policy {
        obj["securityPolicy"] = .object(["killSwitchEnabled": .bool(true)])
        policy = .object(obj)
    }
    try await writePolicy(policy, to: root, persistence)
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)
    let env = await center.evaluateTool(
        tool: "read_file", input: [:],
        origin: SecurityOriginContext(surface: "chat"), enforceAutonomy: false
    )
    #expect(env.decision == .block, "kill switch ON expected block even for read_file, got \(env.decision.rawValue) — \(env.reasons)")
    #expect(env.reasons.contains { $0.contains("kill switch") },
            "kill switch block expected a kill-switch reason, got \(env.reasons)")
}

/// Secret firewall blocks a shell-capability tool when secret-shaped input is
/// present (secrets + shell/external_send/network_write → block). Pins the
/// firewall against a refactor that drops it.
@Test func AutonomyGuardCharacterization_SCGATES_secret_firewall_blocks_shell_with_secret() async throws {
    let center = try await scCenter(personal: true)
    let env = await center.evaluateTool(
        tool: "shell",
        input: ["api_key": .string("sk-live-abcdef0123456789abcdef0123456789")],
        origin: SecurityOriginContext(surface: "chat"), enforceAutonomy: false
    )
    #expect(env.decision == .block, "shell + secret input expected block, got \(env.decision.rawValue) — \(env.reasons)")
    #expect(env.reasons.contains { $0.contains("secret firewall") },
            "shell + secret input expected a secret-firewall reason, got \(env.reasons)")
}

// MARK: - COMPOSED suite — full chat chain, surface="chat", permissive fileAccess, hasFiler:false
//
// AutonomyGatedDispatcher( FileAccessGatedDispatcher(StubInner, "auto"),
//                          gate: AutonomyGate(trust: real TrustCenter, filer: nil),
//                          securityCenter: SwiftNativeSecurityCenter(dataRoot:) )
// "Dispatched" == no throw and status reached_inner. "Throws" == AutonomyGateError.
//
// NOTE ON THE FILEACCESS TOKEN: FileAccessGatedDispatcher's PERMISSIVE modes are
// "workspace" / "auto" / "full" / "" — NOT the string "allow" (which maps to the
// default → .none branch and blocks everything). The production chat path passes
// "auto"/"workspace"; this suite uses "auto" so the file-access layer is open and
// the decision is driven by SecurityCenter + autonomy. The "allow"→.none landmine
// is pinned explicitly in the FAG suite below.

private final class ReachInnerStub: ToolDispatchClient, @unchecked Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object(["status": .string("reached_inner")])
    }
    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

/// Build the production-shaped composed chain pointed at a temp dataRoot.
/// `policy == nil` means LOCKED (no policy.json written).
private func composedChain(
    policy: JSONValue?,
    telegramConfig: JSONValue? = nil,
    verifiedSessionId: String? = nil,
    approvedReplay: ApprovedChatToolReplay? = nil
) async throws -> any ToolDispatchClient {
    let root = try agcTempRoot()
    let persistence = SwiftNativePersistenceCore()
    if let policy {
        try await writePolicy(policy, to: root, persistence)
    }
    if let telegramConfig {
        try await writeTelegramConfig(telegramConfig, to: root, persistence)
    }
    let trust = SwiftNativeTrustCenter(dataRoot: root, persistence: persistence)
    let gate = AutonomyGate(trust: trust, approvalFiler: nil)
    let fileAccessGated = FileAccessGatedDispatcher(inner: ReachInnerStub(), fileAccess: "auto")
    return AutonomyGatedDispatcher(
        inner: fileAccessGated,
        gate: gate,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence),
        hasFiler: false,
        verifiedSessionId: verifiedSessionId,
        approvedReplay: approvedReplay
    )
}

private func dispatched(
    _ chain: any ToolDispatchClient,
    _ tool: String,
    input: [String: JSONValue] = [:],
    surface: String = "chat"
) async -> Bool {
    do {
        let out = try await chain.dispatch(tool: tool, input: input, surface: surface)
        if case .object(let o) = out, case .string(let s)? = o["status"], s == "reached_inner" {
            return true
        }
        return false
    } catch {
        return false
    }
}

private func yoloInstallConfirmPolicy(developerMode: Bool = false) -> JSONValue {
    .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(developerMode),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "iosRemotePolicy": .object(["remote_from_ios_allowed": .bool(true)]),
        "toolAutonomy": .object([
            "default": .string("send_approval"),
            "install_app": .string("confirm"),
            "restart_app": .string("confirm"),
        ]),
    ])
}

@Test func AutonomyGuardCharacterization_COMPOSED_exactApprovedPersonaReplay_reachesInner() async throws {
    let input: [String: JSONValue] = [
        "kind": .string("soul"),
        "title": .string("Bounded note"),
        "content": .string("An exact user-approved persona addition."),
    ]
    let replay = ApprovedChatToolReplay(
        approvalID: "approval-exact",
        tool: "persona_append_section",
        surface: "chat",
        input: input,
        verifiedSessionID: "session-exact",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    let chain = try await composedChain(
        policy: personalPolicy(),
        verifiedSessionId: "session-exact",
        approvedReplay: replay
    )

    #expect(await dispatched(chain, "persona_append_section", input: input))
}

@Test func AutonomyGuardCharacterization_COMPOSED_changedPersonaReplay_failsClosed() async throws {
    let approvedInput: [String: JSONValue] = [
        "kind": .string("soul"),
        "title": .string("Bounded note"),
        "content": .string("The approved content."),
    ]
    let replay = ApprovedChatToolReplay(
        approvalID: "approval-mismatch",
        tool: "persona_append_section",
        surface: "chat",
        input: approvedInput,
        verifiedSessionID: "session-mismatch",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    let chain = try await composedChain(
        policy: personalPolicy(),
        verifiedSessionId: "session-mismatch",
        approvedReplay: replay
    )
    var changedInput = approvedInput
    changedInput["content"] = .string("Different content must require a fresh approval.")

    #expect(!(await dispatched(chain, "persona_append_section", input: changedInput)))
    let changedOriginDispatched = await ChatToolSessionContext.$verifiedUserId.withValue("different-user") {
        await dispatched(chain, "persona_append_section", input: approvedInput)
    }
    #expect(!changedOriginDispatched)
}

@Test func AutonomyGuardCharacterization_COMPOSED_approvedPersonaReplay_doesNotBypassSecurityBlock() async throws {
    let input: [String: JSONValue] = [
        "kind": .string("soul"),
        "title": .string("Bounded note"),
        "content": .string("This exact content was approved."),
    ]
    let replay = ApprovedChatToolReplay(
        approvalID: "approval-security-block",
        tool: "persona_append_section",
        surface: "chat",
        input: input,
        verifiedSessionID: "session-security-block",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    var blockedPolicy = personalPolicy()
    if case .object(var policy) = blockedPolicy {
        policy["securityPolicy"] = .object(["killSwitchEnabled": .bool(true)])
        blockedPolicy = .object(policy)
    }
    let chain = try await composedChain(
        policy: blockedPolicy,
        verifiedSessionId: "session-security-block",
        approvedReplay: replay
    )

    #expect(!(await dispatched(chain, "persona_append_section", input: input)))
}

@Test func AutonomyGuardCharacterization_GitHub_mutation_fails_closed_without_filer_even_in_yolo() async throws {
    let chain = try await composedChain(policy: yoloInstallConfirmPolicy(developerMode: true))
    #expect(await dispatched(chain, "github_status"), "GitHub safe read should reach the native connector")
    #expect(
        !(await dispatched(
            chain,
            "github_mutate",
            input: [
                "operation": .string("comment_issue"),
                "repo": .string("owner/repo"),
                "number": .int(1),
                "body": .string("must never reach inner without approval"),
            ],
            surface: "codex-bridge"
        )),
        "GitHub external writes must fail closed when the bridge has no approval filer"
    )
}

@Test func AutonomyGuardCharacterization_COMPOSED_personal_dispatches_all() async throws {
    let chain = try await composedChain(policy: personalPolicy())
    // read_file always dispatches; the KEY FINDING is the WHOLE shell-class set
    // auto-dispatching with NO approval under PERSONAL (default auto + devMode +
    // Full Mac). All builder tools, app lifecycle tools, and invoke_claude likewise.
    // (gpt-5.5 review fix: the composed proof must cover bash/git/apply_patch/
    // run_tests too, not just shell — the KEY FINDING is the whole set.)
    for tool in ["read_file", "shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test", "restart_app", "install_app", "invoke_claude"] {
        let ok = await dispatched(chain, tool)
        #expect(ok, "COMPOSED PERSONAL \(tool) expected DISPATCHED (reached_inner), but it did not")
    }
}

/// THE KEY FINDING, pinned on its own: under PERSONAL the full production chat
/// chain auto-dispatches `shell` with NO approval round-trip. If this ever
/// starts throwing, a refactor added an approval/gate to the shell path — verify
/// that was intended; do not silence this test.
@Test func AutonomyGuardCharacterization_COMPOSED_personal_shell_auto_dispatches_no_approval() async throws {
    let chain = try await composedChain(policy: personalPolicy())
    let ok = await dispatched(chain, "shell")
    #expect(ok, "KEY FINDING: COMPOSED PERSONAL shell must auto-dispatch with NO approval (reached_inner). It did not.")
}

@Test func AutonomyGuardCharacterization_COMPOSED_trustedTelegram_yoloInstall_dispatchesNoApproval() async throws {
    let chain = try await composedChain(
        policy: yoloInstallConfirmPolicy(),
        telegramConfig: .object(["allowed_chat_ids": .array([.string("12345")])]),
        verifiedSessionId: "telegram:12345"
    )

    let ok = await dispatched(
        chain,
        "install_app",
        input: ["reason": .string("apply tested Swift build")],
        surface: "telegram"
    )

    #expect(ok, "COMPOSED trusted Telegram install_app must reach inner without confirm/no-filer under active yolo")
}

@Test func AutonomyGuardCharacterization_COMPOSED_allowedTelegramUser_yoloDispatchesNoApproval() async throws {
    let chain = try await composedChain(
        policy: yoloInstallConfirmPolicy(),
        telegramConfig: .object(["allowed_user_ids": .array([.string("67890")])]),
        // A UUID-like session intentionally supplies no chat-id proof. The
        // transport-verified sender identity must independently satisfy the
        // exact allowed_user_ids trust root.
        verifiedSessionId: "telegram-session-uuid"
    )

    let ok = await ChatToolSessionContext.$verifiedUserId.withValue("67890") {
        await dispatched(
            chain,
            "install_app",
            input: ["reason": .string("apply tested Swift build")],
            surface: "telegram"
        )
    }

    #expect(ok, "COMPOSED allowed Telegram user must inherit active yolo without an approval loop")
}

@Test func AutonomyGuardCharacterization_COMPOSED_pairedIOSChatSurfaces_yoloInstall_dispatchesNoApproval() async throws {
    for surface in ["ios", "icloud", "iphone", "ipad", "mobile", "watch"] {
        let chain = try await composedChain(policy: yoloInstallConfirmPolicy())

        let ok = await dispatched(
            chain,
            "install_app",
            input: ["reason": .string("apply tested Swift build")],
            surface: surface
        )

        #expect(ok, "COMPOSED paired \(surface) install_app must reach inner without confirm/no-filer under active yolo")
    }
}

@Test func AutonomyGuardCharacterization_COMPOSED_untrustedTelegram_yoloInstall_blocks() async throws {
    let chain = try await composedChain(
        policy: yoloInstallConfirmPolicy(),
        telegramConfig: .object(["allowed_chat_ids": .array([.string("12345")])]),
        verifiedSessionId: "telegram:99999"
    )

    let ok = await dispatched(
        chain,
        "install_app",
        input: ["reason": .string("untrusted install attempt")],
        surface: "telegram"
    )

    #expect(!ok, "COMPOSED untrusted Telegram install_app must block before autonomy/yolo can elevate it")
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: through the full composed chain, LOCKED `shell` threw a
/// SecurityCenter "security block … Developer Mode". NEW CONTRACT: with
/// `criticalRequiresDeveloperMode` and `toolSigningRequired` both defaulting
/// false, and the autonomy catch-all at `auto`, a LOCKED local `shell` runs all
/// the way to the inner dispatcher — no security block, no autonomy clamp, no
/// approval filed.
@Test func AutonomyGuardCharacterization_COMPOSED_locked_shell_and_read_both_dispatch() async throws {
    let chain = try await composedChain(policy: nil)  // LOCKED
    let shellOk = await dispatched(chain, "shell", input: ["command": .string("echo hi")])
    #expect(shellOk, "COMPOSED LOCKED shell expected DISPATCHED post-cutover (reached_inner)")
    let readOk = await dispatched(chain, "read_file")
    #expect(readOk, "COMPOSED LOCKED read_file expected DISPATCHED (reached_inner)")
    // TEETH: the chain is NOT a pass-through. The perimeter-shaped block — an
    // unverified remote origin — still stops a call dead in the same chain, so
    // this test cannot pass on a chain that lost its gates entirely. (The
    // dedicated row for that case is
    // AutonomyGuardCharacterization_COMPOSED_untrustedTelegram_yoloInstall_blocks.)
    let remoteOk = await dispatched(chain, "install_app", surface: "telegram")
    #expect(!remoteOk, "COMPOSED LOCKED install_app from an unverified telegram origin must still block")
}

@Test func AutonomyGuardCharacterization_COMPOSED_locked_codexMessage_dispatches_with_secret_shaped_text() async throws {
    let chain = try await composedChain(policy: nil)
    let ok = await dispatched(
        chain,
        "codex_message",
        input: [
            "text": .string("diagnostic output mentions sk-test-secret-secret-secret-secret"),
            "topic": .string("policy-debug"),
        ]
    )
    #expect(ok, "COMPOSED LOCKED codex_message should dispatch as an auto local bridge ping, even when audit redaction detects secret-shaped diagnostic text")
}

@Test func AutonomyGuardCharacterization_COMPOSED_shellConfirm_throws_no_filer() async throws {
    let chain = try await composedChain(policy: personalShellConfirmPolicy())
    // shell autonomy=confirm + no filer ⇒ honest throw with the no-filer reason.
    do {
        _ = try await chain.dispatch(tool: "shell", input: [:], surface: "chat")
        Issue.record("COMPOSED SHELL_CONFIRM shell expected to throw, but dispatched")
    } catch {
        let desc = String(describing: error)
        #expect(desc.contains("approval required, no filer"),
                "COMPOSED SHELL_CONFIRM shell expected 'approval required, no filer' reason, got: \(desc)")
    }
    // read_file is still auto under this policy ⇒ dispatches.
    let readOk = await dispatched(chain, "read_file")
    #expect(readOk, "COMPOSED SHELL_CONFIRM read_file expected DISPATCHED (still auto)")
}

// MARK: - FAG suite — FileAccessGatedDispatcher per mode (layer-isolated)

private func fagThrows(mode: String, tool: String) async -> Bool {
    let gated = FileAccessGatedDispatcher(inner: ReachInnerStub(), fileAccess: mode)
    do {
        _ = try await gated.dispatch(tool: tool, input: [:], surface: "chat")
        return false
    } catch {
        return true
    }
}

@Test func AutonomyGuardCharacterization_FAG_none_blocks_all() async throws {
    for tool in ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test", "restart_app", "install_app", "read_file", "write_file"] {
        let threw = await fagThrows(mode: "none", tool: tool)
        #expect(threw, "FAG none \(tool) expected throw (blocked), but it passed")
    }
}

@Test func AutonomyGuardCharacterization_FAG_readOnly_blocks_writers_passes_read() async throws {
    for tool in ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test", "restart_app", "install_app", "write_file"] {
        let threw = await fagThrows(mode: "read_only", tool: tool)
        #expect(threw, "FAG read_only \(tool) expected throw (blocked), but it passed")
    }
    // read_file is NOT in readOnlyBlockedExact ⇒ reaches inner.
    let readThrew = await fagThrows(mode: "read_only", tool: "read_file")
    #expect(readThrew == false, "FAG read_only read_file expected to PASS (reach inner), but it threw")
}

/// 2026-07-31 audit fix — the six Full-Mac file/git READ tools
/// (SwiftToolDispatcher.fullMacFileToolNames minus write_file, plus the git
/// group) matched neither blockedExact nor any blockedPrefix, so
/// fileAccess=none let real filesystem/repo readers through.
/// .none must block them; .readOnly must keep PERMITTING them (they are
/// reads — that is what read_only is for).
private let fagFullMacReadTools = [
    "file_excerpt", "grep",
    "git_status", "git_diff", "git_log", "repo_dirty_summary",
]

@Test func AutonomyGuardCharacterization_FAG_none_blocks_fullMac_read_tools() async throws {
    for tool in fagFullMacReadTools {
        let threw = await fagThrows(mode: "none", tool: tool)
        #expect(threw, "FAG none \(tool) expected throw (blocked), but it passed")
    }
    // The catalog surface must agree with the dispatch gate.
    let gated = FileAccessGatedDispatcher(inner: FagCatalogStub(), fileAccess: "none")
    let listed = try await gated.listAvailableTools()
    for tool in fagFullMacReadTools {
        #expect(listed.contains(tool) == false,
                "FAG none listAvailableTools must not advertise \(tool)")
    }
}

@Test func AutonomyGuardCharacterization_FAG_readOnly_still_permits_fullMac_read_tools() async throws {
    for tool in fagFullMacReadTools {
        let threw = await fagThrows(mode: "read_only", tool: tool)
        #expect(threw == false,
                "FAG read_only \(tool) is a READ and must reach inner, but it threw")
    }
    let gated = FileAccessGatedDispatcher(inner: FagCatalogStub(), fileAccess: "read_only")
    let listed = try await gated.listAvailableTools()
    for tool in fagFullMacReadTools {
        #expect(listed.contains(tool), "FAG read_only must still advertise \(tool)")
    }
}

/// Inner stub that reports the Full-Mac read tools so the per-mode catalog
/// filtering is observable.
private final class FagCatalogStub: ToolDispatchClient, @unchecked Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object(["status": .string("reached_inner")])
    }
    func listAvailableTools() async throws -> [String] {
        ["file_excerpt", "grep", "git_status", "git_diff", "git_log",
         "repo_dirty_summary", "read_file", "write_file"]
    }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Test func AutonomyGuardCharacterization_FAG_permissive_passes_all() async throws {
    // The PERMISSIVE modes are "workspace"/"auto"/"full" — these never block.
    // 2026-07-21 audit: "" was REMOVED from the permissive set — an unset/
    // empty config value silently opened the file gate for any caller
    // forwarding it. Verified: no production call site passes "" (auto ×6,
    // background ×1, read_only ×2), so empty now fails closed with every
    // other unrecognized value.
    for mode in ["workspace", "auto", "full"] {
        for tool in ["shell", "read_file", "write_file"] {
            let threw = await fagThrows(mode: mode, tool: tool)
            #expect(threw == false, "FAG permissive(\(mode)) \(tool) expected to PASS, but it threw")
        }
    }
    // "" now FAILS CLOSED (the 2026-07-21 audit fix: empty must not open the
    // gate). If this ever passes again, a permissive empty-alias was
    // reintroduced — verify that loosening was intended.
    for tool in ["shell", "write_file"] {
        let threw = await fagThrows(mode: "", tool: tool)
        #expect(threw, "FAG empty-mode \(tool) must FAIL CLOSED after the 2026-07-21 audit fix, but it passed")
    }
}

/// LANDMINE PIN: the literal string "allow" is NOT a permissive token — it falls
/// to FileAccessGatedDispatcher's `default` → `.none` branch and BLOCKS shell.
/// Pinned because the name is a trap (a refactor "helpfully" adding an "allow"
/// case would silently OPEN file access on any caller passing "allow" today,
/// which currently fails closed). If this ever stops throwing, a permissive
/// "allow" alias was added — verify that loosening was intended.
@Test func AutonomyGuardCharacterization_FAG_string_allow_is_NOT_permissive_blocks_shell() async throws {
    let threw = await fagThrows(mode: "allow", tool: "shell")
    #expect(threw, "FAG fileAccess=\"allow\" must currently FAIL CLOSED (maps to .none, blocks shell). It did not.")
    // read_file too — "allow" maps to .none, which blocks read_file via blockedExact.
    let readThrew = await fagThrows(mode: "allow", tool: "read_file")
    #expect(readThrew, "FAG fileAccess=\"allow\" must currently block read_file (maps to .none). It did not.")
}

// MARK: - CATALOG suite — includeFullMacFileTools visibility (layer 1)
//
// builtInToolSchemas(includeFullMacFileTools:) is the catalog source for the
// Full-Mac-gated builder tools. With the flag off, shell/bash/git/apply_patch/
// run_tests MUST NOT appear; with it on, they MUST appear.

private func catalogNames(includeFullMacFileTools: Bool) -> Set<String> {
    let root = (try? agcTempRoot()) ?? FileManager.default.temporaryDirectory
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let schemas = dispatcher.builtInToolSchemas(includeFullMacFileTools: includeFullMacFileTools)
    return Set(schemas.map(\.name))
}

@Test func AutonomyGuardCharacterization_CATALOG_excludes_builder_tools_when_off() async throws {
    let names = catalogNames(includeFullMacFileTools: false)
    for tool in ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test"] {
        #expect(!names.contains(tool),
                "CATALOG includeFullMacFileTools:false must EXCLUDE \(tool), but it was present")
    }
}

@Test func AutonomyGuardCharacterization_CATALOG_includes_builder_tools_when_on() async throws {
    let names = catalogNames(includeFullMacFileTools: true)
    for tool in ["shell", "bash", "git", "apply_patch", "run_tests", "swift_build", "swift_test"] {
        #expect(names.contains(tool),
                "CATALOG includeFullMacFileTools:true must INCLUDE \(tool), but it was absent")
    }
}
