import Testing
import Foundation
@testable import TrustCenter
import MacControl
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.securityPolicy.fullMacNeverExpires
//
// `fullMacNeverExpires` is the one switch that makes the Full Mac grant never
// lapse. It is absent from `defaultTrustPolicy()` entirely — it exists only as
// a SAVED key — and on the live store it is TRUE. Nothing in the fence drove
// the never-expires branch: the existing full-Mac coverage pins an EXPIRED
// grant only, so a permanent grant had no eval at all.
//
// Three cases, and the revocation path that keeps the two spellings in sync.

private func fullMacTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FullMacNeverExpires-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
private let pastISO = SwiftNativeManifestSigner.isoTimestamp(
    fixedNow.addingTimeInterval(-72 * 3600))

/// (a) An explicitly PAST expiry must not revoke a never-expires grant:
///     `fullMacNeverExpires` is consulted BEFORE the expiry timestamp.
@Test func FullMac_neverExpires_outranksAPastExpiryTimestamp() async throws {
    let root = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved: [String: JSONValue] = [
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string(pastISO),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["default": .string("auto")]),
    ]
    try await seedHermeticTrustPolicy(saved, at: root)
    let center = SwiftNativeTrustCenter(dataRoot: root, clock: { fixedNow })
    let normalized = try await center.loadTrustPolicyChecked()

    #expect(SwiftNativeSecurityCenter.fullMacActive(policy: saved, now: fixedNow),
            "never-expires grant was revoked by a past timestamp on the SAVED policy")
    #expect(SwiftNativeSecurityCenter.fullMacActive(policy: normalized, now: fixedNow),
            "never-expires grant was revoked by a past timestamp on the NORMALIZED policy")
    // The two spellings are kept in sync by normalize's Full-Mac branch.
    #expect(normalized["fullMacNeverExpires"] == .bool(true))
    #expect(SwiftNativeSecurityCenter.fullMacExpiresAt(policy: normalized) == "never",
            "the panel's expiry line disagrees with the gate")
}

/// (b) The other spelling — `fullMacExpiresAt == "never"` with the boolean
///     absent — must resolve identically, and normalize must backfill the bool.
@Test func FullMac_expiresAtNeverSpelling_agreesWithTheBooleanSpelling() async throws {
    let root = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved: [String: JSONValue] = [
        "permissionLevel": .string("full_mac_os"),
        "fullMacExpiresAt": .string("never"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["default": .string("auto")]),
    ]
    try await seedHermeticTrustPolicy(saved, at: root)
    let center = SwiftNativeTrustCenter(dataRoot: root, clock: { fixedNow })
    let normalized = try await center.loadTrustPolicyChecked()

    #expect(SwiftNativeSecurityCenter.fullMacActive(policy: saved, now: fixedNow))
    #expect(SwiftNativeSecurityCenter.fullMacActive(policy: normalized, now: fixedNow))
    #expect(normalized["fullMacNeverExpires"] == .bool(true),
            "normalize did not keep the two never-expires spellings in sync")
    #expect(SwiftNativeSecurityCenter.fullMacExpiresAt(policy: normalized) == "never")
}

/// (c) Drift out of Full-Mac detection REVOKES the permanent grant — and the
///     normalized policy drops both keys. That is a real posture change with no
///     receipt distinguishing it from a deliberate revocation, so pin it: the
///     revocation must be complete (no half-cleared state a later read could
///     resurrect).
@Test func FullMac_neverExpires_isRevokedAndClearedWhenThePolicyDriftsOutOfFullMac() async throws {
    let root = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved: [String: JSONValue] = [
        "permissionLevel": .string("balanced"),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")]),
        "toolAutonomy": .object(["default": .string("auto")]),
    ]
    try await seedHermeticTrustPolicy(saved, at: root)
    let center = SwiftNativeTrustCenter(dataRoot: root, clock: { fixedNow })
    let normalized = try await center.loadTrustPolicyChecked()

    #expect(!SwiftNativeSecurityCenter.fullMacActive(policy: normalized, now: fixedNow),
            "a never-expires grant survived a policy that is no longer Full Mac")
    #expect(normalized["fullMacNeverExpires"] == .bool(false),
            "fullMacNeverExpires was left truthy on a revoked grant")
    #expect(normalized["fullMacExpiresAt"] == nil,
            "fullMacExpiresAt survived revocation: \(String(describing: normalized["fullMacExpiresAt"]))")
    // No half-cleared state: the saved spelling alone must not re-activate it.
    #expect(!SwiftNativeSecurityCenter.fullMacActive(
        policy: ["permissionLevel": .string("balanced"),
                 "fullMacNeverExpires": .bool(false),
                 "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")])],
        now: fixedNow))
}

/// The grant is not just a flag — it changes what runs. Same tool, same input,
/// same clock; only the grant differs.
@Test func FullMac_neverExpiresGrant_changesAnOutsideAppDataWriteOutcome() async throws {
    let outsidePath = "/tmp/nativeagent-fullmac-eval-probe.txt"

    let grantedRoot = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: grantedRoot) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string(pastISO),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["default": .string("auto")]),
    ], at: grantedRoot)
    let granted = await SwiftNativeSecurityCenter(dataRoot: grantedRoot, clock: { fixedNow })
        .evaluateTool(tool: "write_file",
                      input: ["path": .string(outsidePath), "content": .string("x")],
                      origin: SecurityOriginContext(surface: "chat"))

    let revokedRoot = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: revokedRoot) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")]),
        "toolAutonomy": .object(["default": .string("auto")]),
    ], at: revokedRoot)
    let revoked = await SwiftNativeSecurityCenter(dataRoot: revokedRoot, clock: { fixedNow })
        .evaluateTool(tool: "write_file",
                      input: ["path": .string(outsidePath), "content": .string("x")],
                      origin: SecurityOriginContext(surface: "chat"))

    #expect(!granted.reasons.contains { $0.contains("requires Full Mac access") },
            "the never-expires grant did not reach the write gate: \(granted.reasons)")
    #expect(revoked.decision == .block)
    #expect(revoked.reasons.contains { $0.contains("requires Full Mac access") },
            "a revoked grant still allowed an outside-app-data write: \(revoked.reasons)")
}
