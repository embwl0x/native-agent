import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.autonomyGates.readAutonomyTrustPolicy
//   • core.trust.autonomyGates.RebuildLock
//
// `readAutonomyTrustPolicy` is the default policyProvider for the SystemOps
// rebuild and git-stash-recover gates. It reads trust/policy.json through
// `persistence.readJSON(..., defaultValue: .object([:]))`, deliberately
// SKIPPING loadRawPolicyChecked / validateAuthorityPolicyShape — so a
// malformed policy fails closed (good) but is INDISTINGUISHABLE from a policy
// that legitimately has autonomy off (the silent half).
//
// `RebuildLock` is the cross-process rebuild mutex. `acquire()` returns false
// both on contention and on an open(2) failure, and the happy path leaks the
// fd on purpose. Nothing drove contention or release before this.

private func gatesTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutonomyGates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func AutonomyGates_readAutonomyTrustPolicy_missingFileFailsClosed() async throws {
    let root = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let view = await readAutonomyTrustPolicy(dataRoot: root)
    #expect(view.enableAutonomy == false)
    #expect(view.systemRebuildEnabled == false)
    #expect(view.gitStashRecoverEnabled == false)
}

@Test func AutonomyGates_readAutonomyTrustPolicy_validPolicyOpensExactlyTheEnabledGates() async throws {
    let root = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "enableAutonomy": .bool(true),
        "systemRebuild": .object(["enabled": .bool(true)]),
        // gitStashRecover deliberately left absent — a missing per-action block
        // must stay closed while the global switch is on.
    ], at: root)

    let view = await readAutonomyTrustPolicy(dataRoot: root)
    #expect(view.enableAutonomy)
    #expect(view.systemRebuildEnabled)
    #expect(view.gitStashRecoverEnabled == false,
            "an absent per-action block opened its gate")

    // The gates the reader feeds must agree with the view it produced.
    #expect(try await autonomyApprovalGate(
        action: .systemRebuild, daemonAutonomy: true, policy: view).isAllowed)
    #expect(!(try await autonomyApprovalGate(
        action: .gitStashRecover, daemonAutonomy: true, policy: view).isAllowed))
    #expect(!(try await autonomyApprovalGate(
        action: .systemRebuild, daemonAutonomy: false, policy: view).isAllowed),
            "the daemon-level switch stopped being a required conjunct")
}

/// Corrupt authority reads as denyAll — fails CLOSED, which is right — but it
/// produces a view byte-identical to "no policy at all". The caller cannot tell
/// a corrupt store from a fresh install, so a rebuild that silently never runs
/// looks exactly like autonomy being off on purpose.
///
/// Pinned as an observable fact (ledger row
/// core.trust.autonomyGates.readAutonomyTrustPolicy). Making the two cases
/// distinguishable needs a production seam — see the wave report.
@Test func AutonomyGates_readAutonomyTrustPolicy_corruptPolicyIsIndistinguishableFromMissing() async throws {
    let corruptRoot = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let policyPath = corruptRoot
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json")
    try FileManager.default.createDirectory(
        at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not-json".utf8).write(to: policyPath)

    let missingRoot = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: missingRoot) }

    let corrupt = await readAutonomyTrustPolicy(dataRoot: corruptRoot)
    let missing = await readAutonomyTrustPolicy(dataRoot: missingRoot)

    #expect(corrupt.enableAutonomy == false, "corrupt authority did not fail closed")
    #expect(corrupt.systemRebuildEnabled == false)
    #expect(corrupt.gitStashRecoverEnabled == false)
    #expect(corrupt == missing,
            "corrupt and missing authority are now distinguishable — that is the fix; update ledger row core.trust.autonomyGates.readAutonomyTrustPolicy")

    // The corrupt bytes must be left exactly as found: a read path may not repair
    // or truncate saved authority.
    #expect(try Data(contentsOf: policyPath) == Data("{not-json".utf8))
}

/// The reader must honour the dataRoot it is given and never fall back to the
/// process-wide default root — an audit worker pointed at a clone would
/// otherwise silently report the live machine's posture.
@Test func AutonomyGates_readAutonomyTrustPolicy_readsOnlyTheGivenDataRoot() async throws {
    let openRoot = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: openRoot) }
    try await seedHermeticTrustPolicy([
        "enableAutonomy": .bool(true),
        "systemRebuild": .object(["enabled": .bool(true)]),
    ], at: openRoot)

    let closedRoot = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: closedRoot) }
    try await seedHermeticTrustPolicy(["enableAutonomy": .bool(false)], at: closedRoot)

    #expect(await readAutonomyTrustPolicy(dataRoot: openRoot).enableAutonomy)
    #expect(await readAutonomyTrustPolicy(dataRoot: closedRoot).enableAutonomy == false)
}

@Test func AutonomyGates_rebuildLock_secondHolderIsRefusedAndReleaseRestoresIt() async throws {
    let root = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = RebuildLock(dataRoot: root)
    let second = RebuildLock(dataRoot: root)

    #expect(await first.acquire(), "first acquire failed on a writable root")
    #expect(await first.isHeld())
    #expect(await second.acquire() == false, "a second holder acquired the rebuild mutex")
    #expect(await second.isHeld() == false)

    // Re-acquiring from the holder is idempotent, not a second lock.
    #expect(await first.acquire())

    await first.release()
    #expect(await first.isHeld() == false)
    #expect(await second.acquire(), "the lock was not released")
    await second.release()

    // release() on a lock we do not hold must be a no-op, not a crash or an
    // unlock of somebody else's fd.
    await first.release()
    #expect(await first.isHeld() == false)

    let third = RebuildLock(dataRoot: root)
    #expect(await third.acquire())
    await third.release()
}

/// An unopenable lock path returns the SAME `false` as contention, so a rebuild
/// that can never start is indistinguishable from one that is already running.
/// Pinned (ledger row core.trust.autonomyGates.RebuildLock); distinguishing the
/// two needs a production seam — see the wave report.
@Test func AutonomyGates_rebuildLock_unwritablePathIsIndistinguishableFromContention() async throws {
    let root = try gatesTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // A path whose "parent directory" is actually a FILE: createDirectory fails,
    // open(2) fails, acquire() reports the contention value.
    let filePath = root.appendingPathComponent("not-a-directory")
    try Data("x".utf8).write(to: filePath)
    let broken = RebuildLock(dataRoot: filePath)

    #expect(await broken.acquire() == false,
            "acquire() succeeded on an unopenable path")
    #expect(await broken.isHeld() == false)

    let contended = RebuildLock(dataRoot: root)
    #expect(await contended.acquire())
    let loser = RebuildLock(dataRoot: root)
    let contentionResult = await loser.acquire()

    // Same observable value, two very different causes — that is the finding.
    let brokenResult = await broken.acquire()
    #expect(brokenResult == contentionResult,
            "an unopenable lock path and lock contention now report different results — that is the fix; update ledger row core.trust.autonomyGates.RebuildLock")
    #expect(contentionResult == false)

    await contended.release()
    #expect(await loser.acquire(), "the lock was still held after release")
    await loser.release()
}
