import Testing
import Foundation
@testable import TrustCenter
import MacControl
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.securityPolicy.fullMacNeverExpires
//
// 2026-09-10 (User): Full Mac has no timer. It is on until the person turns it
// off, so `fullMacNeverExpires` / `fullMacExpiresAt` /
// `fullMacConfirmedAt` / `fullMacMaxDurationHours` are no longer read by
// anything. What this file pins now:
//   (a) expiry state left on disk by an older install is ignored — a stored
//       past expiry and a stored 4-hour window both keep Full Mac ON;
//   (b) a policy that is not Full Mac is still OFF, and still blocks an
//       outside-app-data write.

private func fullMacTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FullMacNeverExpires-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
private let pastISO = SwiftNativeManifestSigner.isoTimestamp(
    fixedNow.addingTimeInterval(-72 * 3600))

/// (a) A saved past expiry, and a saved short duration window anchored to a
///     long-gone confirmation, are BOTH inert: the grant is the saved policy.
@Test func FullMac_savedExpiryStateFromAnOlderInstallIsIgnored() async throws {
    let root = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved: [String: JSONValue] = [
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(false),
        "fullMacExpiresAt": .string(pastISO),
        "fullMacConfirmedAt": .string(pastISO),
        "fullMacMaxDurationHours": .double(4),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["default": .string("auto")]),
    ]
    try await seedHermeticTrustPolicy(saved, at: root)
    let center = SwiftNativeTrustCenter(dataRoot: root, clock: { fixedNow })
    let normalized = try await center.loadTrustPolicyChecked()

    #expect(SwiftNativeSecurityCenter.fullMacActive(policy: saved),
            "a stale stored expiry switched Full Mac off on the SAVED policy")
    #expect(SwiftNativeSecurityCenter.fullMacActive(policy: normalized),
            "a stale stored expiry switched Full Mac off on the NORMALIZED policy")
}

/// (b) A policy that is not Full Mac is OFF, whatever expiry keys it carries.
@Test func FullMac_isOffWhenTheSavedPolicyIsNotFullMac() async throws {
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

    #expect(!SwiftNativeSecurityCenter.fullMacActive(policy: saved),
            "a non-Full-Mac policy reported Full Mac on because of a saved never-expires key")
    #expect(!SwiftNativeSecurityCenter.fullMacActive(policy: normalized))
}

/// The grant is not just a flag — it changes what runs. Same tool, same input,
/// same clock; only the saved grant differs.
@Test func FullMac_grant_changesAnOutsideAppDataWriteOutcome() async throws {
    let outsidePath = "/tmp/nativeagent-fullmac-eval-probe.txt"

    let grantedRoot = try fullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: grantedRoot) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("full_mac_os"),
        // Deliberately stale expiry state: it must not close the grant.
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
            "the saved Full Mac grant did not reach the write gate: \(granted.reasons)")
    #expect(revoked.decision == .block)
    #expect(revoked.reasons.contains { $0.contains("requires Full Mac access") },
            "a non-Full-Mac policy still allowed an outside-app-data write: \(revoked.reasons)")
}
