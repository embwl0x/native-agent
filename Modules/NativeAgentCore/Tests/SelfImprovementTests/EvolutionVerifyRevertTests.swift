import Testing
import Foundation
@testable import SelfImprovement

// MARK: - Fixtures

private func tempRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("evoverify-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

private func machine(
    dataRoot: URL,
    grace: TimeInterval = 1800,
    maxAttempts: Int = 2,
    now: Date = t0
) -> EvolutionVerifyRevert {
    EvolutionVerifyRevert(
        dataRoot: dataRoot,
        installGraceSeconds: grace,
        maxAttempts: maxAttempts,
        now: { now })
}

private func stage(_ m: EvolutionVerifyRevert) async throws -> EvolutionPendingVerify {
    try await m.stagePendingVerify(
        runId: "run-1", proposalId: "evo_1",
        expectedSha: "abc123def456", revertSha: "fedcba987654")
}

// MARK: - Stage / clear

@Test func stage_writes_record_and_refuses_double_stage() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let rec = try await stage(m)
    #expect(rec.attempts == 0)
    #expect(FileManager.default.fileExists(atPath: m.pendingVerifyPath.path))

    do {
        _ = try await m.stagePendingVerify(
            runId: "run-2", proposalId: "evo_2", expectedSha: "x1234567", revertSha: "y1234567")
        Issue.record("expected alreadyPendingVerify")
    } catch let e as EvolutionEngineError {
        if case .alreadyPendingVerify(let existing) = e {
            #expect(existing == "run-1")
        } else { Issue.record("wrong error: \(e)") }
    }
}

@Test func stage_refuses_unsafe_run_id_and_empty_shas() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await m.stagePendingVerify(
            runId: "../escape", proposalId: "p", expectedSha: "a1234567", revertSha: "b1234567")
    }
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await m.stagePendingVerify(
            runId: "run-1", proposalId: "p", expectedSha: " ", revertSha: "b1234567")
    }
}

@Test func clear_cas_on_run_id() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    _ = try await stage(m)
    do {
        try await m.clearPendingVerify(runId: "someone-else")
        Issue.record("expected pendingVerifyMismatch")
    } catch let e as EvolutionEngineError {
        if case .pendingVerifyMismatch = e {} else { Issue.record("wrong error: \(e)") }
    }
    try await m.clearPendingVerify(runId: "run-1")
    #expect(!FileManager.default.fileExists(atPath: m.pendingVerifyPath.path))
    // Idempotent once gone.
    try await m.clearPendingVerify(runId: "run-1")
}

// MARK: - checkAtLaunch decision table

@Test func check_no_pending_file() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let d = try await m.checkAtLaunch(currentBundleSha: "abc123def456", doctor: { .green })
    #expect(d == .noPending)
}

@Test func check_corrupt_file_fail_closed_not_deleted() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let garbage = "not json at all"
    try FileManager.default.createDirectory(
        at: m.pendingVerifyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try garbage.write(to: m.pendingVerifyPath, atomically: true, encoding: .utf8)

    let d = try await m.checkAtLaunch(currentBundleSha: "abc123def456", doctor: { .green })
    if case .corrupt = d {} else { Issue.record("expected .corrupt, got \(d)") }
    let after = try String(contentsOf: m.pendingVerifyPath, encoding: .utf8)
    #expect(after == garbage)
}

@Test func check_sha_match_doctor_green_verifies_and_clears() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    _ = try await stage(m)
    let d = try await m.checkAtLaunch(currentBundleSha: "abc123def456", doctor: { .green })
    guard case .verified(let rec) = d else {
        Issue.record("expected .verified, got \(d)"); return
    }
    #expect(rec.runId == "run-1")
    #expect(rec.attempts == 1)
    #expect(!FileManager.default.fileExists(atPath: m.pendingVerifyPath.path))
}

@Test func check_sha_match_short_prefix_stamp_verifies() async throws {
    // install_app.sh stamps SHORT git sha; the run records a longer one.
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    _ = try await stage(m)
    let d = try await m.checkAtLaunch(currentBundleSha: "abc123d", doctor: { .green })
    guard case .verified = d else {
        Issue.record("expected .verified, got \(d)"); return
    }
}

@Test func check_sha_match_doctor_critical_reverts_keeps_pending() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    _ = try await stage(m)
    let d = try await m.checkAtLaunch(currentBundleSha: "abc123def456", doctor: { .critical })
    guard case .revert(let rec, let reason) = d else {
        Issue.record("expected .revert, got \(d)"); return
    }
    #expect(reason == .doctorCritical)
    #expect(rec.revertSha == "fedcba987654")
    // Pending kept as the evidence record for the wave-2 revert executor.
    #expect(FileManager.default.fileExists(atPath: m.pendingVerifyPath.path))
}

@Test func check_sha_match_doctor_degraded_verifies_degraded() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    _ = try await stage(m)
    let d = try await m.checkAtLaunch(currentBundleSha: "abc123def456", doctor: { .degraded })
    guard case .verifiedDegraded(_, let doctor) = d else {
        Issue.record("expected .verifiedDegraded, got \(d)"); return
    }
    #expect(doctor == .degraded)
    #expect(!FileManager.default.fileExists(atPath: m.pendingVerifyPath.path))
}

@Test func check_mismatch_inside_grace_waits_and_counts() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = machine(dataRoot: root, now: t0)
    _ = try await stage(staging)
    // 10 minutes later, old binary still running (install still building).
    let checker = machine(dataRoot: root, now: t0.addingTimeInterval(600))
    let d = try await checker.checkAtLaunch(currentBundleSha: "0ld5ha999999", doctor: { .green })
    guard case .waitRetry(let rec) = d else {
        Issue.record("expected .waitRetry, got \(d)"); return
    }
    #expect(rec.attempts == 1)
    // Counter persisted.
    let persisted = try await checker.currentPendingVerify()
    #expect(persisted?.attempts == 1)
}

@Test func check_mismatch_past_grace_reverts() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = machine(dataRoot: root, now: t0)
    _ = try await stage(staging)
    let checker = machine(dataRoot: root, now: t0.addingTimeInterval(1801))
    let d = try await checker.checkAtLaunch(currentBundleSha: "0ld5ha999999", doctor: { .green })
    guard case .revert(_, let reason) = d else {
        Issue.record("expected .revert, got \(d)"); return
    }
    #expect(reason == .shaMismatch)
}

@Test func check_nil_bundle_sha_is_fail_closed_mismatch() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = machine(dataRoot: root, now: t0)
    _ = try await stage(staging)
    let checker = machine(dataRoot: root, now: t0.addingTimeInterval(1801))
    let d = try await checker.checkAtLaunch(currentBundleSha: nil, doctor: { .green })
    guard case .revert(_, let reason) = d else {
        Issue.record("expected .revert, got \(d)"); return
    }
    #expect(reason == .shaMismatch)
}

@Test func check_attempts_exceeded_reverts_even_inside_grace() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = machine(dataRoot: root, now: t0)
    _ = try await stage(staging)
    let checker = machine(dataRoot: root, now: t0.addingTimeInterval(60))

    let d1 = try await checker.checkAtLaunch(currentBundleSha: "0ld5ha999999", doctor: { .green })
    guard case .waitRetry = d1 else { Issue.record("check 1: expected waitRetry, got \(d1)"); return }
    let d2 = try await checker.checkAtLaunch(currentBundleSha: "0ld5ha999999", doctor: { .green })
    guard case .waitRetry = d2 else { Issue.record("check 2: expected waitRetry, got \(d2)"); return }
    // Third check: attempts (3) > maxAttempts (2) → revert regardless of grace.
    let d3 = try await checker.checkAtLaunch(currentBundleSha: "0ld5ha999999", doctor: { .green })
    guard case .revert(let rec, let reason) = d3 else {
        Issue.record("check 3: expected revert, got \(d3)"); return
    }
    #expect(reason == .attemptsExceeded)
    #expect(rec.attempts == 3)
}

// MARK: - VERSION_SHA reader

@Test func readBundleVersionSha_reads_trims_and_fails_closed() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(EvolutionVerifyRevert.readBundleVersionSha(resourcesDir: root) == nil)
    try "  abc123d\n".write(
        to: root.appendingPathComponent("VERSION_SHA"), atomically: true, encoding: .utf8)
    #expect(EvolutionVerifyRevert.readBundleVersionSha(resourcesDir: root) == "abc123d")
    try "\n".write(
        to: root.appendingPathComponent("VERSION_SHA"), atomically: true, encoding: .utf8)
    #expect(EvolutionVerifyRevert.readBundleVersionSha(resourcesDir: root) == nil)
}

// MARK: - Rollback bundle mechanics

private func makeDummyBundle(at dir: URL, marker: String) throws -> URL {
    let bundle = dir.appendingPathComponent("Dummy.app", isDirectory: true)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try marker.write(
        to: contents.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    return bundle
}

@Test func rollback_copy_restore_round_trip() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let bundle = try makeDummyBundle(at: root, marker: "v1-original")

    let aside = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")
    #expect(FileManager.default.fileExists(atPath: aside.path))
    let metaPath = m.rollbackBundleDir(runId: "run-1").appendingPathComponent("meta.json")
    #expect(FileManager.default.fileExists(atPath: metaPath.path))

    // Simulate a bad install clobbering the bundle.
    try "v2-broken".write(
        to: bundle.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)

    try await m.restoreBundle(runId: "run-1", to: bundle)
    let restored = try String(
        contentsOf: bundle.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    #expect(restored == "v1-original")
}

@Test func rollback_copy_refuses_overwrite_and_missing_source() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let bundle = try makeDummyBundle(at: root, marker: "v1")
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")
    }
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await m.copyBundleAside(
            bundlePath: root.appendingPathComponent("Nope.app"), runId: "run-2")
    }
}

@Test func restore_missing_bundle_fails_closed() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    do {
        try await m.restoreBundle(runId: "ghost", to: root.appendingPathComponent("X.app"))
        Issue.record("expected rollbackBundleMissing")
    } catch let e as EvolutionEngineError {
        if case .rollbackBundleMissing = e {} else { Issue.record("wrong error: \(e)") }
    }
}

@Test func restore_corrupt_meta_fails_distinctly_and_preserves_evidence() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let bundle = try makeDummyBundle(at: root, marker: "v1")
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")
    let metaPath = m.rollbackBundleDir(runId: "run-1").appendingPathComponent("meta.json")
    try "not json".write(to: metaPath, atomically: true, encoding: .utf8)

    do {
        try await m.restoreBundle(runId: "run-1", to: bundle)
        Issue.record("expected rollbackMetaCorrupt")
    } catch let e as EvolutionEngineError {
        // DISTINCT from missing — corrupt meta is its own failure.
        if case .rollbackMetaCorrupt = e {} else { Issue.record("wrong error: \(e)") }
    }
    // Corrupt file left in place for a human, never deleted or defaulted.
    #expect(try String(contentsOf: metaPath, encoding: .utf8) == "not json")
}

@Test func restore_unsafe_bundle_name_refused() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let dir = m.rollbackBundleDir(runId: "run-evil")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"runId":"run-evil","sourcePath":"/tmp/x","bundleName":"../escape","createdAt":"2026-06-10T00:00:00Z"}"#
        .write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

    do {
        try await m.restoreBundle(runId: "run-evil", to: root.appendingPathComponent("Out.app"))
        Issue.record("expected rollbackBundleNameInvalid")
    } catch let e as EvolutionEngineError {
        if case .rollbackBundleNameInvalid(let n) = e {
            #expect(n == "../escape")
        } else { Issue.record("wrong error: \(e)") }
    }
}

@Test func rollback_ops_serialize_under_lock() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let bundle = try makeDummyBundle(at: root, marker: "v1")
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")

    // Hold the rollback ops flock directly (what a sibling process holds
    // mid-restore), then ask for a sweep: it must not delete anything until
    // the lock is released.
    let lockPath = m.rollbackOpsLockPath.path + ".lock"
    let fd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
    #expect(fd >= 0)
    #expect(flock(fd, LOCK_EX) == 0)

    let sweepTask = Task { await m.sweepRollbackBundles(keepLatest: 0) }
    try await Task.sleep(nanoseconds: 400_000_000)
    // Bundle still present: sweep is blocked on the ops lock.
    #expect(FileManager.default.fileExists(atPath: m.rollbackBundleDir(runId: "run-1").path))

    _ = flock(fd, LOCK_UN)
    close(fd)
    let removed = await sweepTask.value
    #expect(removed == ["run-1"])
    #expect(!FileManager.default.fileExists(atPath: m.rollbackBundleDir(runId: "run-1").path))
}

@Test func delete_rollback_bundle_remove_path() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let bundle = try makeDummyBundle(at: root, marker: "v1")
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")
    #expect(try await m.deleteRollbackBundle(runId: "run-1") == true)
    #expect(!FileManager.default.fileExists(atPath: m.rollbackBundleDir(runId: "run-1").path))
    // Idempotent once gone; unsafe ids refused.
    #expect(try await m.deleteRollbackBundle(runId: "run-1") == false)
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await m.deleteRollbackBundle(runId: "../escape")
    }
}

@Test func verified_decision_deletes_rollback_bundle() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    _ = try await stage(m) // runId "run-1"
    let bundle = try makeDummyBundle(at: root, marker: "v1")
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-1")

    let d = try await m.checkAtLaunch(currentBundleSha: "abc123def456", doctor: { .green })
    guard case .verified = d else {
        Issue.record("expected .verified, got \(d)"); return
    }
    // Delete-after-verify: the aside bundle goes with the pending record.
    #expect(!FileManager.default.fileExists(atPath: m.rollbackBundleDir(runId: "run-1").path))
}

@Test func sweep_rollback_bundles_keeps_latest() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = machine(dataRoot: root)
    let bundle = try makeDummyBundle(at: root, marker: "v1")
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-old")
    // Ensure distinct mtimes for deterministic ordering.
    try await Task.sleep(nanoseconds: 1_100_000_000)
    _ = try await m.copyBundleAside(bundlePath: bundle, runId: "run-new")

    let removed = await m.sweepRollbackBundles(keepLatest: 1)
    #expect(removed == ["run-old"])
    #expect(FileManager.default.fileExists(atPath: m.rollbackBundleDir(runId: "run-new").path))
    #expect(!FileManager.default.fileExists(atPath: m.rollbackBundleDir(runId: "run-old").path))
}
