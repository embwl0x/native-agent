// U4 Wave C — INTEGRATION proof of the autonomy-promotion APPLY path.
//
// The module-side AutonomyPromotionLoopTests pin the DECISION logic with fake
// IO closures. This file pins the REAL security mutation end-to-end: it builds
// the production loop via BackgroundLoopsAssembly.makeAutonomyPromotionLoop
// (the real SwiftNativeApprovalInbox adapter + the real currentTier read + the
// real applyPromotion raw-policy WRITE), stages a genuine approved card through
// the real inbox, runs tick(), and asserts against the on-disk policy.json.
//
// Why this exists: applyPromotion flips a live trust-policy key (a security
// LOOSENING). "Build-green + unit-green with fakes" is not close-out for a
// policy mutation — the changed path must actually run. These tests prove:
//   1. a human-APPROVED card flips ONLY the target key; every other top-level
//      key and every other toolAutonomy entry is preserved byte-for-value;
//   2. the apply is idempotent (a second tick does not re-write);
//   3. a DENIED card never flips;
//   4. enableAutonomy=false is fail-safe (an approved card is NOT applied).

import Foundation
import Testing
import BackgroundLoops
import ApprovalInbox
import PersistenceCore
import NativeAgentCore
@testable import NativeAgentApp

private struct APITestBed {
    let root: URL
    let policyPath: URL
    let persistence = SwiftNativePersistenceCore()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutonomyPromotionIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        policyPath = root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// A realistic saved policy: enableAutonomy on, a confirm-tier candidate,
    /// an unrelated auto tool, an external send_approval tool, and a couple of
    /// non-toolAutonomy top-level keys that MUST survive the write.
    func writePolicy(enableAutonomy: Bool, candidateTier: String) async throws {
        let policy: JSONValue = .object([
            "enableAutonomy": .bool(enableAutonomy),
            "autonomyDefault": .string("supervised"),
            "sentinelTopLevel": .string("preserve_me"),
            "providerPolicy": .object(["default": .string("anthropic_oauth_direct")]),
            "toolAutonomy": .object([
                "candidate_tool": .string(candidateTier),
                "other_tool": .string("auto"),
                "gmail.send": .string("send_approval"),
            ]),
        ])
        try await persistence.writeJSON(policy, to: policyPath)
    }

    func readPolicy() async -> [String: JSONValue] {
        let raw = await persistence.readJSON(policyPath, defaultValue: .object([:]))
        if case .object(let o) = raw { return o }
        return [:]
    }

    func tier(_ obj: [String: JSONValue], _ tool: String) -> String? {
        guard case .object(let ta)? = obj["toolAutonomy"], case .string(let t)? = ta[tool] else { return nil }
        return t
    }

    /// Stage a genuine autonomy.promote card via the REAL inbox, then resolve
    /// it with `decision`. Returns the card id.
    @discardableResult
    func stageResolvedPromotion(tool: String, decision: ApprovalDecision) async throws -> String {
        let inbox = SwiftNativeApprovalInbox(root: root)
        let body: JSONValue = .object([
            "title": .string("Promote \(tool) to auto?"),
            "action": .string("autonomy.promote"),
            "risk": .string("high"),
            "payload": .object([
                "tool": .string(tool),
                "fromTier": .string("confirm"),
                "toTier": .string("auto"),
            ]),
            "payloadPreview": .string("[promote \(tool): confirm→auto]"),
        ])
        let created = try await inbox.create(body)
        _ = try await inbox.resolve(created.id, decision: decision, decidedBy: "integration-test")
        return created.id
    }

    func cardExecutedActionStatus(id: String) async -> String? {
        let inbox = SwiftNativeApprovalInbox(root: root)
        guard let rec = try? await inbox.get(id) else { return nil }
        guard case .object(let ea)? = rec.executedAction, case .string(let s)? = ea["status"] else { return nil }
        return s
    }

    func cardFlags(id: String) async -> (remoteResolvable: Bool, localOnly: Bool)? {
        let inbox = SwiftNativeApprovalInbox(root: root)
        guard let rec = try? await inbox.get(id) else { return nil }
        return (rec.remoteResolvable, rec.localOnly)
    }
}

// MARK: - 0. The localOnlyActions edit actually makes the card local-only.

/// Invariant (a): a confirm→auto promotion is a SECURITY loosening that a
/// remote/chat surface must NEVER be able to approve. The guard is that
/// `autonomy.promote` is in ApprovalInbox.localOnlyActions, which forces
/// remoteResolvable=false / localOnly=true at create time. Pin it against the
/// REAL inbox (the staging body sets no remoteResolvable key, so the default
/// branch must derive it from localOnlyActions).
@Test func autonomyPromotion_card_is_local_only_not_remote_resolvable() async throws {
    let bed = try APITestBed()
    defer { try? FileManager.default.removeItem(at: bed.root) }
    let id = try await bed.stageResolvedPromotion(tool: "candidate_tool", decision: .approved)
    let flags = await bed.cardFlags(id: id)
    #expect(flags?.remoteResolvable == false, "autonomy.promote must NOT be remote-resolvable")
    #expect(flags?.localOnly == true, "autonomy.promote must be local-only")
}

// MARK: - 1. Approved card flips ONLY the target key; siblings preserved; idempotent.

@Test func autonomyPromotion_approved_card_flips_target_preserves_siblings_idempotent() async throws {
    let bed = try APITestBed()
    defer { try? FileManager.default.removeItem(at: bed.root) }
    try await bed.writePolicy(enableAutonomy: true, candidateTier: "confirm")
    let cardId = try await bed.stageResolvedPromotion(tool: "candidate_tool", decision: .approved)

    let loop = BackgroundLoopsAssembly.makeAutonomyPromotionLoop(dataRoot: bed.root)
    await loop.tick()

    let after = await bed.readPolicy()
    // Target flipped…
    #expect(bed.tier(after, "candidate_tool") == "auto", "approved promotion must flip candidate_tool→auto")
    // …every sibling preserved.
    #expect(bed.tier(after, "other_tool") == "auto", "unrelated tool must be untouched")
    #expect(bed.tier(after, "gmail.send") == "send_approval",
            "external send_approval tool must NOT be loosened by an unrelated promotion")
    #expect({ if case .string(let s)? = after["sentinelTopLevel"] { return s == "preserve_me" }; return false }(),
            "non-toolAutonomy top-level key must survive the raw write")
    #expect({ if case .bool(let b)? = after["enableAutonomy"] { return b }; return false }(),
            "enableAutonomy must survive the raw write")
    // Saved file must NOT have ballooned with the default tool catalog (raw-save,
    // not normalized): exactly the three tools we wrote remain.
    if case .object(let ta)? = after["toolAutonomy"] {
        #expect(ta.count == 3, "raw write must not bake in the default catalog (got \(ta.count) entries)")
    } else { Issue.record("toolAutonomy missing after write") }
    // Card stamped applied.
    #expect(await bed.cardExecutedActionStatus(id: cardId) == "applied")

    // No-replay: revert the tier to confirm WITHOUT touching the (now stamped)
    // card, tick again — an already-executed card must never re-fire, so the
    // tool must STAY at confirm. This is the real idempotency guard (the
    // executedAction stamp), not a same-state coincidence.
    try await bed.writePolicy(enableAutonomy: true, candidateTier: "confirm")
    await loop.tick()
    let after2 = await bed.readPolicy()
    #expect(bed.tier(after2, "candidate_tool") == "confirm",
            "a stamped (already-executed) card must NOT re-apply even after the tier reverts")
}

// MARK: - 2. Denied card never flips.

@Test func autonomyPromotion_denied_card_does_not_flip() async throws {
    let bed = try APITestBed()
    defer { try? FileManager.default.removeItem(at: bed.root) }
    try await bed.writePolicy(enableAutonomy: true, candidateTier: "confirm")
    _ = try await bed.stageResolvedPromotion(tool: "candidate_tool", decision: .denied)

    let loop = BackgroundLoopsAssembly.makeAutonomyPromotionLoop(dataRoot: bed.root)
    await loop.tick()

    let after = await bed.readPolicy()
    #expect(bed.tier(after, "candidate_tool") == "confirm",
            "a DENIED promotion must never flip the tool — it stays at confirm")
}

// MARK: - 2b. Apply path re-validates eligibility: an approved card for a
// hard-excluded tool must NOT flip real policy (gpt-5.5 defense-in-depth).

@Test func autonomyPromotion_approved_card_for_excluded_tool_does_not_flip() async throws {
    let bed = try APITestBed()
    defer { try? FileManager.default.removeItem(at: bed.root) }
    // Hypothetically mis-tier a builder to confirm + approve a promote card for
    // it. The apply path (reconcile guard + the inside-lock re-check) must
    // refuse — payload.tool is attacker-controllable and must not be trusted.
    let policy: JSONValue = .object([
        "enableAutonomy": .bool(true),
        "toolAutonomy": .object(["shell": .string("confirm")]),
    ])
    try await bed.persistence.writeJSON(policy, to: bed.policyPath)
    _ = try await bed.stageResolvedPromotion(tool: "shell", decision: .approved)

    let loop = BackgroundLoopsAssembly.makeAutonomyPromotionLoop(dataRoot: bed.root)
    await loop.tick()

    let after = await bed.readPolicy()
    #expect(bed.tier(after, "shell") == "confirm",
            "a hard-excluded builder must never be promoted, even from an approved card")
}

// MARK: - 2c. The localOnlyActions hardening ignores a caller's remote override
// (gpt-5.5 B2): even if a body sets remoteResolvable=true, an autonomy.promote
// card is forced local-only by ApprovalInbox.

@Test func autonomyPromotion_card_forced_local_only_despite_caller_override() async throws {
    let bed = try APITestBed()
    defer { try? FileManager.default.removeItem(at: bed.root) }
    let inbox = SwiftNativeApprovalInbox(root: bed.root)
    let body: JSONValue = .object([
        "title": .string("Promote x to auto?"),
        "action": .string("autonomy.promote"),
        // Hostile override attempt — must be ignored for a hardcoded local-only action.
        "remoteResolvable": .bool(true),
        "localOnly": .bool(false),
        "payload": .object(["tool": .string("x"), "toTier": .string("auto")]),
    ])
    let created = try await inbox.create(body)
    #expect(created.remoteResolvable == false, "caller's remoteResolvable=true must be overridden to false")
    #expect(created.localOnly == true, "caller's localOnly=false must be overridden to true")
}

// MARK: - 3. Fail-safe: enableAutonomy=false ⇒ approved card NOT applied.

@Test func autonomyPromotion_disabled_autonomy_does_not_apply_even_approved() async throws {
    let bed = try APITestBed()
    defer { try? FileManager.default.removeItem(at: bed.root) }
    try await bed.writePolicy(enableAutonomy: false, candidateTier: "confirm")
    _ = try await bed.stageResolvedPromotion(tool: "candidate_tool", decision: .approved)

    let loop = BackgroundLoopsAssembly.makeAutonomyPromotionLoop(dataRoot: bed.root)
    await loop.tick()

    let after = await bed.readPolicy()
    #expect(bed.tier(after, "candidate_tool") == "confirm",
            "autonomy OFF must be fail-safe: even an approved card is not applied")
}
