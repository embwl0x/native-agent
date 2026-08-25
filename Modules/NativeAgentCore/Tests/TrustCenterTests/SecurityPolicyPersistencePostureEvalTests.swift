import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.securityPolicy.blockIsUnpersisted
//
// SecurityCenter reads the normalized policy, while policy.json records only
// operator-authored deltas. That distinction is safety-significant: a missing
// or partial `securityPolicy` block must regain every default at the canonical
// authorization read, without making those defaults look like user choices.
// These probes use the checked production reader and mutation owner; they do
// not hand-build a normalized envelope.

private func securityPolicyPostureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecurityPolicyPosture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func securityBlock(
    _ policy: [String: JSONValue],
    note: String
) throws -> [String: JSONValue] {
    guard case .object(let security)? = policy["securityPolicy"] else {
        throw NSError(
            domain: "SecurityPolicyPersistencePostureEval",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(note): missing securityPolicy block"]
        )
    }
    return security
}

/// Missing storage is the only bootstrap state. The checked read must project
/// the complete default block, while the raw file remains genuinely absent so
/// no caller can mistake source defaults for user-configured authority.
@Test func SecurityPolicy_missingStoreProjectsDefaultsWithoutInventingRawOverrides() async throws {
    let root = try securityPolicyPostureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeTrustCenter(dataRoot: root)
    let policyPath = root.appendingPathComponent("trust/policy.json")

    let defaults = await center.defaultTrustPolicy()
    let snapshot = try await center.loadAuthorizationSnapshotChecked()
    let defaultSecurity = try securityBlock(defaults, note: "defaults")
    let effectiveSecurity = try securityBlock(snapshot.policy, note: "effective snapshot")

    #expect(!FileManager.default.fileExists(atPath: policyPath.path),
            "a read-only bootstrap projection must not materialize policy.json")
    #expect(try SwiftNativeTrustCenter.loadRawPolicyChecked(at: policyPath).isEmpty,
            "missing policy must have no raw user overrides")
    #expect(snapshot.userConfiguredAutonomyOverrides.isEmpty,
            "default tool tiers are not user-authored overrides")
    #expect(snapshot.securityPolicyProvenance.count == defaultSecurity.count,
            "every effective default security key must carry its source provenance")
    for key in defaultSecurity.keys {
        #expect(snapshot.securityPolicyProvenance[key] == .defaultSourceAbsent,
                "missing policy source mislabeled \(key) as operator intent")
    }
    #expect(effectiveSecurity == defaultSecurity,
            "checked authorization stopped projecting the complete default security posture")
    #expect(effectiveSecurity.count >= 14,
            "securityPolicy lost keys during missing-store normalization")
}

/// An adversarial partial mutation is persisted as exactly that user intent,
/// then a fresh production reader must backfill its untouched siblings. This
/// catches both dangerous directions: treating a partial block as complete,
/// and silently writing source defaults back as though the operator chose them.
@Test func SecurityPolicy_partialCheckedMutationPreservesRawIntentAndBackfillsEffectiveSiblings() async throws {
    let root = try securityPolicyPostureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = SwiftNativeTrustCenter(dataRoot: root)
    let defaults = await writer.defaultTrustPolicy()
    let defaultSecurity = try securityBlock(defaults, note: "defaults")

    _ = try await writer.applyPolicyPatchChecked([
        "securityPolicy": .object(["killSwitchEnabled": .bool(true)]),
    ])

    let policyPath = root.appendingPathComponent("trust/policy.json")
    let raw = try SwiftNativeTrustCenter.loadRawPolicyChecked(at: policyPath)
    let rawSecurity = try securityBlock(raw, note: "raw policy")
    #expect(rawSecurity == ["killSwitchEnabled": .bool(true)],
            "checked mutation persisted more than the operator's explicit security delta")

    // Reopen through a new owner: do not accidentally assert the writer's
    // in-memory result instead of the durable policy route SecurityCenter uses.
    let freshSnapshot = try await SwiftNativeTrustCenter(dataRoot: root)
        .loadAuthorizationSnapshotChecked()
    let effectiveSecurity = try securityBlock(freshSnapshot.policy, note: "fresh effective snapshot")
    #expect(effectiveSecurity["killSwitchEnabled"] == .bool(true),
            "the saved kill-switch intent did not survive the checked reread")
    #expect(freshSnapshot.securityPolicyProvenance["killSwitchEnabled"] == .explicit,
            "the persisted kill-switch choice was not labeled explicit")
    #expect(effectiveSecurity.count == defaultSecurity.count,
            "partial saved securityPolicy replaced default siblings")
    for (key, value) in defaultSecurity where key != "killSwitchEnabled" {
        #expect(effectiveSecurity[key] == value,
                "default security sibling \(key) was not backfilled after a partial saved block")
        #expect(freshSnapshot.securityPolicyProvenance[key] == .defaultMissingKey,
                "backfilled security sibling \(key) was not labeled default-missing-key")
    }
}

@Test func SecurityPolicy_presentPolicyWithoutSecurityBlockLabelsEveryDefaultAsMissingBlock() async throws {
    let root = try securityPolicyPostureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let policyPath = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"permissionLevel":"balanced"}"#.utf8).write(to: policyPath)

    let center = SwiftNativeTrustCenter(dataRoot: root)
    let snapshot = try await center.loadAuthorizationSnapshotChecked()
    let security = try securityBlock(snapshot.policy, note: "missing-block effective snapshot")
    for key in security.keys {
        #expect(snapshot.securityPolicyProvenance[key] == .defaultMissingBlock,
                "present source without securityPolicy block mislabeled \(key)")
    }
}

@Test func SecurityPolicy_malformedCanonicalAuthorityPreservesBytesAndProjectsUnreadableFailClosedSnapshot() async throws {
    let root = try securityPolicyPostureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let policyPath = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    let damaged = Data(#"{"securityPolicy":{"killSwitchEnabled":"true"}}"#.utf8)
    try damaged.write(to: policyPath)
    let center = SwiftNativeTrustCenter(dataRoot: root)

    await #expect(throws: (any Error).self) {
        _ = try await center.loadAuthorizationSnapshotChecked()
    }
    #expect(try Data(contentsOf: policyPath) == damaged,
            "a checked rejection must not repair, rotate, or rewrite damaged authority bytes")

    let projected = await center.loadAuthorizationSnapshot()
    let closedSecurity = try securityBlock(projected.policy, note: "unreadable fail-closed snapshot")
    #expect(closedSecurity["killSwitchEnabled"] == .bool(true),
            "unreadable authority did not project the closed kill switch")
    #expect(!projected.securityPolicyProvenance.isEmpty,
            "unreadable authority omitted the per-key provenance contract")
    for (key, provenance) in projected.securityPolicyProvenance {
        #expect(provenance == .unreadable,
                "unreadable authority mislabeled \(key) as a usable default or explicit value")
    }
    #expect(try Data(contentsOf: policyPath) == damaged,
            "nonthrowing fail-closed projection must preserve damaged authority bytes")
}
