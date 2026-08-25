import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.trustPolicy.codableExtras
//   • core.trust.trustCenter.normalizedTrustPolicy.mergeDepth
//
// `TrustPolicy` is the type `getTrust()` / `updateTrust()` hand back, and its
// hand-written `init(from:)` collects every unknown top-level key with
// `try? c.decode(JSONValue.self, forKey: key)` — a decode failure DROPS the
// key silently. `encode(to:)` then re-emits only what survived. A policy block
// that fails to round-trip (securityPolicy, macControlPolicy, filePolicy,
// toolAutonomy) therefore vanishes with no error, no audit row and no diff,
// and the next load backfills code defaults — a permissive reversion nobody
// can see.
//
// These tests round-trip the REAL production policy shapes: `defaultTrustPolicy()`
// (the literal every install is backfilled from) and a policy produced by the
// real write seam `applyPolicyPatchChecked`. No hand-built fixture stands in
// for the store — a fixture would only test the assumptions that built it.

private func roundTripTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrustPolicyRoundTrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Encode a policy dict -> decode as `TrustPolicy` -> encode again, and return
/// the resulting JSON object. Mirrors exactly what `decodePolicy` does inside
/// `getTrust()` / `updateTrust()`.
private func codableRoundTrip(_ policy: [String: JSONValue]) throws -> [String: JSONValue] {
    let data = try JSONEncoder().encode(JSONValue.object(policy))
    let decoded = try JSONDecoder().decode(TrustPolicy.self, from: data)
    let reencoded = try JSONEncoder().encode(decoded)
    let back = try JSONDecoder().decode(JSONValue.self, from: reencoded)
    guard case .object(let obj) = back else {
        Issue.record("TrustPolicy re-encoded to a non-object")
        return [:]
    }
    return obj
}

@Test func TrustPolicy_codableRoundTrip_losesNoKeyOfTheRealDefaultPolicy() async throws {
    let root = try roundTripTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeTrustCenter(dataRoot: root)
    let policy = await center.defaultTrustPolicy()

    // Vacuity guard: the real default policy is a large, deeply nested object.
    // If this ever collapses to a handful of keys the comparison below stops
    // measuring anything.
    #expect(policy.count >= 20, "defaultTrustPolicy() collapsed to \(policy.count) keys")

    let back = try codableRoundTrip(policy)

    #expect(Set(back.keys) == Set(policy.keys),
            "keys lost on round-trip: \(Set(policy.keys).subtracting(back.keys).sorted()); keys invented: \(Set(back.keys).subtracting(policy.keys).sorted())")
    for (key, value) in policy {
        #expect(back[key] == value, "value changed on round-trip for key \(key)")
    }
}

@Test func TrustPolicy_codableRoundTrip_losesNoKeyOfAPolicyWrittenByTheRealWriteSeam() async throws {
    let root = try roundTripTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeTrustCenter(dataRoot: root)

    // Drive the canonical checked mutation owner, not a hand-built dict: this
    // is the exact generation shape the app persists and re-reads.
    let written = try await center.applyPolicyPatchChecked([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["mac_shell": .string("blocked")]),
        "securityPolicy": .object(["killSwitchEnabled": .bool(true)]),
    ])
    #expect(written.count >= 20)

    let back = try codableRoundTrip(written)
    #expect(Set(back.keys) == Set(written.keys),
            "keys lost: \(Set(written.keys).subtracting(back.keys).sorted())")
    for (key, value) in written {
        #expect(back[key] == value, "value changed on round-trip for key \(key)")
    }

    // The security-relevant sub-values must survive intact, not just the block.
    if case .object(let security)? = back["securityPolicy"] {
        #expect(security["killSwitchEnabled"] == .bool(true))
        #expect(security.count >= 14, "securityPolicy sub-keys lost: \(security.count)")
    } else {
        Issue.record("securityPolicy block vanished on round-trip")
    }
}

/// The documented ASYMMETRY: `permissionLevel` is decoded with
/// `decodeIfPresent(String.self)`, so a non-string value THROWS and kills the
/// whole decode where the raw (`loadRawPolicyChecked`) path coerces. Pinned so
/// the failure mode stays a loud throw rather than becoming a silent key drop.
@Test func TrustPolicy_codableRoundTrip_nonStringPermissionLevelThrowsRatherThanDropping() throws {
    let data = try JSONEncoder().encode(JSONValue.object([
        "permissionLevel": .int(3),
        "toolAutonomy": .object(["default": .string("blocked")]),
    ]))
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(TrustPolicy.self, from: data)
    }
}

/// READ merge vs WRITE merge on the same file.
///
/// `applyPolicyPatchChecked` merges a patch onto the saved generation with a
/// RECURSIVE deepMerge. `normalizedTrustPolicy(saved:)` merges saved-over-default
/// exactly ONE level deep. So a level-3 block — `macControlPolicy.riskGatePolicy`
/// is the one that ships in `defaultTrustPolicy()` — is written key-wise by the
/// writer and read back as a WHOLESALE REPLACEMENT of the default sub-object,
/// dropping every default sibling at that depth.
///
/// This test pins the divergence as an observable fact (ledger row
/// core.trust.trustCenter.normalizedTrustPolicy.mergeDepth). If it goes RED
/// because the read merge became recursive, that is the fix landing: update
/// this expectation and flip the ledger row in the same change.
@Test func TrustPolicy_readMergeIsOneLevel_whileWriteMergeIsRecursive() async throws {
    let root = try roundTripTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeTrustCenter(dataRoot: root)

    let defaults = await center.defaultTrustPolicy()
    guard case .object(let defaultMac)? = defaults["macControlPolicy"],
          case .object(let defaultRiskGate)? = defaultMac["riskGatePolicy"] else {
        Issue.record("defaultTrustPolicy() no longer carries macControlPolicy.riskGatePolicy — this test needs a live 3-level default block")
        return
    }
    #expect(defaultRiskGate.count >= 4,
            "riskGatePolicy lost its tiers: \(defaultRiskGate.keys.sorted())")

    // WRITE seam: patch exactly one level-3 leaf.
    let normalized = try await center.applyPolicyPatchChecked([
        "macControlPolicy": .object(["riskGatePolicy": .object(["low": .string("approve_each")])]),
    ])

    guard case .object(let readMac)? = normalized["macControlPolicy"] else {
        Issue.record("macControlPolicy missing from the normalized read")
        return
    }
    // Level-2 siblings survive — the one-level merge preserves them.
    #expect(readMac["shortcuts_allowed"] == defaultMac["shortcuts_allowed"],
            "level-2 default sibling was dropped; the read merge is shallower than one level")

    guard case .object(let readRiskGate)? = readMac["riskGatePolicy"] else {
        Issue.record("riskGatePolicy missing from the normalized read")
        return
    }
    #expect(readRiskGate["low"] == .string("approve_each"),
            "the written leaf did not survive the read")
    let droppedSiblings = Set(defaultRiskGate.keys).subtracting(readRiskGate.keys)
    #expect(!droppedSiblings.isEmpty,
            "the read merge now preserves level-3 default siblings — the READ/WRITE merge asymmetry is fixed; update ledger row core.trust.trustCenter.normalizedTrustPolicy.mergeDepth")
    // `critical` is the one sibling that survives, and only by accident: the
    // not-developer-mode hardening pass re-inserts it (as "deny", NOT its
    // default "approve_each"). `medium` and `high` are simply gone — the gate
    // reads a riskGatePolicy with two tiers missing and no diff to show for it.
    #expect(droppedSiblings == ["medium", "high"],
            "the level-3 drop set changed: dropped=\(droppedSiblings.sorted()) survivors=\(readRiskGate.keys.sorted())")
    #expect(readRiskGate["critical"] == .string("deny"),
            "critical is no longer rescued by the developer-mode hardening pass")

    // The WRITE seam, by contrast, keeps the whole sub-object it merged onto:
    // patch a second leaf and the first one is still there.
    let second = try await center.applyPolicyPatchChecked([
        "macControlPolicy": .object(["riskGatePolicy": .object(["medium": .string("auto")])]),
    ])
    guard case .object(let secondMac)? = second["macControlPolicy"],
          case .object(let secondRiskGate)? = secondMac["riskGatePolicy"] else {
        Issue.record("riskGatePolicy missing after the second patch")
        return
    }
    #expect(secondRiskGate["low"] == .string("approve_each"),
            "the write merge is no longer recursive — the earlier leaf was clobbered")
    #expect(secondRiskGate["medium"] == .string("auto"))
}
