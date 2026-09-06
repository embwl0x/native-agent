import Testing
import Foundation
import PersistenceCore
@testable import TrustCenter

// MARK: - One Thread, Many Surfaces — Phase 1 gating trust tests
//
// docs/build_plans/one-thread-many-surfaces-plan.md §7 Phase 1, tests 1 and 2:
//
//   1. `telegram:codex-probe`-shaped session id + surface "telegram" + no bound
//      chatId ⇒ UNTRUSTED, WITH A STATED REASON (not a parsed chatId).
//   2. Allowlisted chat on a bare-UUID session ⇒ TRUSTED — the regression the
//      parse fallback was papering over. This must not regress.
//
// Plan §8 R1 names the worst outcome of this phase precisely: not a block, but
// a SILENT WIDENING. These two run in opposite directions on purpose.

private func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parse-deletion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeAllowlistedRoot(
    telegramChatIds: [JSONValue] = [.int(123)],
    slackUserIds: [JSONValue]? = nil
) async throws -> (URL, SwiftNativePersistenceCore) {
    let root = try makeTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object(["invoke_claude": .string("auto")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array(telegramChatIds),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
    )
    if let slackUserIds {
        try await persistence.writeJSON(
            .object([
                "enabled": .bool(true),
                "allowed_user_ids": .array(slackUserIds),
            ]),
            to: root.appendingPathComponent("slack", isDirectory: true)
                .appendingPathComponent("config.json")
        )
    }
    return (root, persistence)
}

// MARK: Test 1 — the probe-shaped id proves nothing, and says so

/// The live index really does hold rows whose ids read `telegram:codex-probe`
/// and `telegram:codex-tool-catalog-probe` with `source: "app"`. Under the old
/// parse, a turn classified `surface == "telegram"` on one of those derived a
/// "chatId" of `codex-probe`. It failed closed only because that string is in
/// nobody's allowlist — a namespace collision waiting for a collaborator.
///
/// Now it fails closed because nothing was verified, and it SAYS SO.
@Test func ParseDeletion_probeShapedSessionId_isUntrusted_withAStatedReason() async throws {
    let (root, persistence) = try await makeAllowlistedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:codex-probe",
            chatId: nil,     // the transport bound nothing
            isRemote: true
        )
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.allowed == false)
    #expect(envelope.decision == .block)
    // The reason must name the actual defect — no verified identity — rather
    // than pretending an allowlist check happened. Sweep item 9: an
    // outcome-unknown becomes speech.
    #expect(
        envelope.originTrustReason.contains("no verified chat or user identity"),
        "expected a stated fail-closed reason, got: \(envelope.originTrustReason)"
    )
    // And it must NOT have silently manufactured "codex-probe" as an identity.
    #expect(envelope.originTrustReason.contains("codex-probe") == false)
}

/// The same shape where the parsed fragment WOULD have matched the allowlist.
/// This is the collision the plan calls "waiting for a collaborator": under the
/// old parse, anything able to choose a session id could choose its own trust.
@Test func ParseDeletion_probeShapedSessionIdMatchingTheAllowlist_stillProvesNothing() async throws {
    let (root, persistence) = try await makeAllowlistedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(
            // "123" IS the allowlisted chat. The old parse would have read it
            // straight out of this string and granted trust on a storage key.
            surface: "telegram",
            sessionId: "telegram:123",
            chatId: nil,
            isRemote: true
        )
    )

    #expect(envelope.originTrusted == false, "a session id must never confer trust")
    #expect(envelope.decision == .block)
}

// MARK: Test 2 — the regression the parse was papering over

/// `/new` mints a bare UUID session. Before the transport threaded the verified
/// chatId, that made an allowlisted chat derive `chatId == nil` in BOTH gates
/// and false-block a high-risk invoke (security/audit.jsonl 2026-06-09 19:24).
/// Deleting the parse must not bring that back — the transport binding is now
/// the ONLY path, so this is the test that proves the path works.
@Test func ParseDeletion_allowlistedChatOnBareUUIDSession_isTrusted() async throws {
    let (root, persistence) = try await makeAllowlistedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping from a /new session")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: UUID().uuidString,   // bare UUID: nothing parseable
            chatId: "123",                  // bound by the transport
            isRemote: true
        )
    )

    #expect(envelope.originTrusted)
    #expect(envelope.allowed)
    #expect(envelope.decision == .allow)
}

// MARK: The refusal is surface-generic

/// Slack reaches the same refusal by the same code path — the fail-closed
/// reason is built from the surface's own name, not from a per-surface branch.
@Test func ParseDeletion_slackWithNoVerifiedIdentity_getsTheSameStatedRefusal() async throws {
    let (root, persistence) = try await makeAllowlistedRoot(slackUserIds: [.string("U123")])
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(surface: "slack", userId: nil, chatId: nil, isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.originTrustReason.contains("no verified chat or user identity"))
    #expect(envelope.originTrustReason.contains("Slack"))
}

/// A surface NOBODY has written an adapter for yet — the "how to add a surface"
/// case. It must fail closed with a named reason and zero edits to the trust
/// center, or every future surface is a new security review.
@Test func ParseDeletion_unknownRemoteSurfaceWithNoIdentity_failsClosedInItsOwnName() async throws {
    let (root, persistence) = try await makeAllowlistedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(surface: "signal", isRemote: true)
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.originTrustReason.contains("signal"))
    #expect(envelope.originTrustReason.contains("no verified chat or user identity"))
}

/// The widening invariant, restated for a surface added tomorrow: a caller
/// passing `isRemote: false` cannot make a KNOWN remote surface local. The rule
/// reads `ConversationSurfaceProfile`, so it is generic by construction.
@Test func ParseDeletion_knownRemoteSurfaceCannotBeDowngradedToLocal() async throws {
    let (root, persistence) = try await makeAllowlistedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence)

    let envelope = await center.evaluateTool(
        tool: "invoke_claude",
        input: ["text": .string("ping")],
        origin: SecurityOriginContext(
            surface: "telegram",
            sessionId: "telegram:123",
            chatId: nil,
            isRemote: false      // forged
        )
    )

    #expect(envelope.originTrusted == false)
    #expect(envelope.originTrustReason.contains("local") == false)
}
