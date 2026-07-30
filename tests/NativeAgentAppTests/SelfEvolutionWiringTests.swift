// U2b wave 2 (2026-06-11) — self-evolution approval-loop wiring tests.
//
// Pins the four mechanisms this wave ships:
//
//   1. Executor self-guards (U3w2 canon): wrong action / unresolved status /
//      missing decision are silent no-ops; malformed payload annotates FAILED.
//
//   2. THE FAIL-CLOSED INSTALL BOUNDARY: with the systemRebuild gate closed
//      (production state — per-action flag default false AND the factory's
//      daemonAutonomy=false), an approved card promotes and then STOPS with
//      an annotated "awaiting systemRebuild.enabled" terminal. The rebuild
//      runner is NEVER invoked, and no install-recovery state (rollback
//      bundle / pending_verify) is staged for an install that cannot fire.
//      Plus the production-gate pin: even with the per-action flag flipped
//      true on disk, the factory-mirrored composite still denies (daemon
//      autonomy seed is false) — the loop ships INERT.
//
//   3. Crash-window reconcile keyed on "resolved + no executedAction", all
//      three decisions; plus the staging glue's idempotency (ensure, not
//      create; cancel → fresh card; never auto-approved, risk pinned
//      critical).
//
//   4. Verify-at-launch decisions: sha-match + green doctor → proposal
//      verified + success card + pending cleared; post-grace sha mismatch →
//      revertCommit fired, proposal reverted, card appended.
//
// All roots are tmp dirs — no production data, repo, policy, or installer
// is touched.
import Foundation
import Testing
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import SelfImprovement
import TrustCenter
@testable import NativeAgentApp

// MARK: - fixtures

private func makeEvoTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelfEvolutionWiringTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private actor EvoRecorder {
    private(set) var promoteCalls: [(runId: String, proposalId: String, diffSha: String)] = []
    private(set) var rebuildFires = 0
    private(set) var revertCalls: [String] = []
    func recordPromote(runId: String, proposalId: String, diffSha: String) {
        promoteCalls.append((runId, proposalId, diffSha))
    }
    func recordRebuild() { rebuildFires += 1 }
    func recordRevert(_ sha: String) { revertCalls.append(sha) }
}

/// Deps with everything stubbed: promote succeeds, gate injectable,
/// rebuild/revert recorded. Bundle is a tiny real directory so the
/// rollback-aside `ditto` works when the gate is open.
private func makeDeps(
    root: URL,
    recorder: EvoRecorder,
    gateAllowed: Bool,
    gateReason: String = "system_rebuild requires trust_policy.systemRebuild.enabled=true",
    promoteOK: Bool = true,
    promotedSha: String = "abc1234def5678",
    bundleSha: String? = nil,
    doctor: EvolutionDoctorState = .green,
    fireError: Error? = nil
) throws -> NativeClient.SelfEvolutionDeps {
    let bundle = root.appendingPathComponent("FakeApp.app", isDirectory: true)
    if !FileManager.default.fileExists(atPath: bundle.path) {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "binary".write(to: bundle.appendingPathComponent("bin"), atomically: true, encoding: .utf8)
    }
    return NativeClient.SelfEvolutionDeps(
        dataRoot: root,
        promote: { runId, proposalId, _, _, diffSha in
            await recorder.recordPromote(runId: runId, proposalId: proposalId, diffSha: diffSha)
            return promoteOK
                ? EvolutionPromoteOutcome(ok: true, commitSha: promotedSha)
                : EvolutionPromoteOutcome(ok: false, error: "candidate_not_green: synthetic")
        },
        rebuildGate: { (gateAllowed, gateReason) },
        fireRebuild: {
            if let fireError { throw fireError }
            await recorder.recordRebuild()
            return "rebuild started (test stub)"
        },
        revertCommit: { sha in
            await recorder.recordRevert(sha)
            return "revert9999000"
        },
        bundleURL: bundle,
        currentBundleSha: { bundleSha },
        doctorState: { doctor }
    )
}

/// File a diff-carrying proposal and walk it to `staged` with a candidate
/// run attached (the shape the stager hands to the approval card).
@discardableResult
private func makeStagedProposal(
    root: URL, runId: String, diff: String = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
) async throws -> EvolutionProposal {
    let store = EvolutionProposalStore(dataRoot: root)
    let p = try await store.propose(
        source: .external, title: "test change", evidence: "synthetic evidence",
        diffText: diff, expectedHead: "headsha123456")
    _ = try await store.transition(id: p.id, to: .building, candidateRunId: runId)
    _ = try await store.transition(id: p.id, to: .candidateGreen)
    _ = try await store.transition(id: p.id, to: .staged)
    return try #require(try await store.get(id: p.id))
}

private func makeResolvedEvolutionApproval(
    root: URL, proposal: EvolutionProposal, runId: String, decision: ApprovalDecision
) async throws -> ApprovalRecord {
    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("Self-evolution install: test"),
        "action": .string(NativeClient.selfEvolutionAction),
        "risk": .string("critical"),
        "reason": .string("test"),
        "payload": .object([
            "kind": .string("self_evolution"),
            "proposalId": .string(proposal.id),
            "runId": .string(runId),
            "diffSHA256": .string(proposal.diffSHA256 ?? ""),
            "expectedHead": .string(proposal.expectedHead ?? ""),
        ]),
    ]))
    return try await inbox.resolve(created.id, decision: decision, decidedBy: "test")
}

private func approvalRow(root: URL, id: String) throws -> [String: Any]? {
    let path = root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
        .appendingPathComponent("requests.json")
    let data = try Data(contentsOf: path)
    let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    return rows?.first { ($0["id"] as? String) == id }
}

private func pendingVerifyPath(root: URL) -> URL {
    root.appendingPathComponent("evolution", isDirectory: true)
        .appendingPathComponent("pending_verify.json")
}

private func inboxCards(root: URL) throws -> [[String: Any]] {
    let path = root
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
        guard let d = $0.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

// MARK: - 1. self-guards

@Test
func evolutionExecutor_ignoresWrongActionAndUnresolved() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let inbox = SwiftNativeApprovalInbox(root: root)

    // Wrong action, resolved.
    let other = try await inbox.create(.object([
        "title": .string("x"), "action": .string("browser.open_url"),
        "risk": .string("low"), "reason": .string("x"), "payload": .object([:]),
    ]))
    let resolvedOther = try await inbox.resolve(other.id, decision: .approved, decidedBy: "test")
    await NativeClient.applyResolvedSelfEvolution(from: resolvedOther, deps: deps)

    // Right action, still pending.
    let pending = try await inbox.create(.object([
        "title": .string("x"), "action": .string(NativeClient.selfEvolutionAction),
        "risk": .string("critical"), "reason": .string("x"),
        "payload": .object(["proposalId": .string("p"), "runId": .string("r")]),
    ]))
    await NativeClient.applyResolvedSelfEvolution(from: pending, deps: deps)

    let calls = await recorder.promoteCalls
    #expect(calls.isEmpty)
    #expect(try approvalRow(root: root, id: pending.id)?["executedAction"] == nil)
}

@Test
func evolutionExecutor_malformedPayload_annotatesFailed() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("x"), "action": .string(NativeClient.selfEvolutionAction),
        "risk": .string("critical"), "reason": .string("x"),
        "payload": .object([:]), // no proposalId/runId
    ]))
    let resolved = try await inbox.resolve(created.id, decision: .approved, decidedBy: "test")
    await NativeClient.applyResolvedSelfEvolution(from: resolved, deps: deps)
    let row = try #require(try approvalRow(root: root, id: created.id))
    #expect(row["executedAction"] != nil)
    #expect((row["detail"] as? String)?.contains("FAILED") == true)
    let calls = await recorder.promoteCalls
    #expect(calls.isEmpty)
}

// MARK: - 2. the fail-closed systemRebuild boundary

@Test
func evolutionExecutor_gateClosed_promotesThenStopsAtBoundary() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let runId = "run-gateclosed"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)

    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: deps)

    // Promote ran exactly once, for the approved diff sha.
    let calls = await recorder.promoteCalls
    #expect(calls.count == 1)
    #expect(calls.first?.diffSha == proposal.diffSHA256)

    // THE RAIL: the installer was never invoked, and no install-recovery
    // state exists for an install that cannot fire.
    let fires = await recorder.rebuildFires
    #expect(fires == 0)
    #expect(!FileManager.default.fileExists(atPath: pendingVerifyPath(root: root).path))
    let rollbackDir = root.appendingPathComponent("evolution", isDirectory: true)
        .appendingPathComponent("rollback_bundle", isDirectory: true)
        .appendingPathComponent(runId, isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: rollbackDir.path))

    // Annotated terminal names the boundary.
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("awaiting systemRebuild.enabled") == true)

    // Proposal advanced to approved with the deferred-install receipt.
    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .approved)
    #expect(after.receipts.contains { $0.kind == "install_deferred" })
}

@Test
func productionRebuildGate_deniesEvenWithPerActionFlagOn() async throws {
    // The factory mirror: makeSystemRebuildClient() constructs with
    // daemonAutonomy=false, so the composite the production deps preflight
    // MUST deny on every policy shape this wave can meet — including the
    // per-action flag flipped true. This is the "executor cannot reach
    // SystemOps.systemRebuild() while the flag is off" proof at the gate
    // level (the executor-level proof is the test above).
    let flagOff = AutonomyTrustPolicyView.parse(.object([
        "enableAutonomy": .bool(true),
        "autoApproveLowRiskImprovements": .bool(true),
        "systemRebuild": .object(["enabled": .bool(false)]),
    ]))
    if case .allowed = checkTrustPolicyForAction(.systemRebuild, daemonAutonomy: false, policy: flagOff) {
        Issue.record("gate must deny with systemRebuild.enabled=false")
    }
    let flagOn = AutonomyTrustPolicyView.parse(.object([
        "enableAutonomy": .bool(true),
        "systemRebuild": .object(["enabled": .bool(true)]),
    ]))
    if case .allowed = checkTrustPolicyForAction(.systemRebuild, daemonAutonomy: false, policy: flagOn) {
        Issue.record("gate must deny while the factory seeds daemonAutonomy=false")
    }
    // And the per-action flag is load-bearing once daemon autonomy is real.
    if case .allowed = checkTrustPolicyForAction(.systemRebuild, daemonAutonomy: true, policy: flagOff) {
        Issue.record("gate must deny with the per-action flag off even with daemon autonomy on")
    }
}

@Test
func evolutionExecutor_gateOpen_stagesInstallInOrder() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let sha = "feedbead12345678"
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: true, promotedSha: sha)
    let runId = "run-gateopen"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)

    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: deps)

    // Rollback aside exists (the layer-2 artifact).
    let aside = root.appendingPathComponent("evolution", isDirectory: true)
        .appendingPathComponent("rollback_bundle", isDirectory: true)
        .appendingPathComponent(runId, isDirectory: true)
        .appendingPathComponent("FakeApp.app", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: aside.path))

    // pending_verify staged with the promoted sha (write-before-terminate).
    let pendingData = try Data(contentsOf: pendingVerifyPath(root: root))
    let pending = try JSONDecoder().decode(EvolutionPendingVerify.self, from: pendingData)
    #expect(pending.runId == runId)
    #expect(pending.expectedSha == sha)
    #expect(pending.revertSha == sha)

    // Installer fired exactly once; annotation says so.
    let fires = await recorder.rebuildFires
    #expect(fires == 1)
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("install fired") == true)

    // Proposal at installed with the promoted commit recorded.
    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .installed)
    #expect(after.promotedCommitSha == sha)
}

@Test
func evolutionExecutor_promoteFailure_annotatesFailedAndStops() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: true, promoteOK: false)
    let runId = "run-promotefail"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)

    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: deps)

    let fires = await recorder.rebuildFires
    #expect(fires == 0)
    #expect(!FileManager.default.fileExists(atPath: pendingVerifyPath(root: root).path))
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("FAILED") == true)
    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .approved) // not installed, not reverted — honest
    #expect(after.receipts.contains { $0.kind == "promote_failed" })
}

// MARK: - deny / cancel lanes

@Test
func evolutionExecutor_denied_marksProposalDenied() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let runId = "run-deny"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .denied)

    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: deps)

    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .denied)
    let calls = await recorder.promoteCalls
    #expect(calls.isEmpty)
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("denied") == true)
}

@Test
func evolutionExecutor_canceled_keepsStagedForRestage() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let runId = "run-cancel"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .canceled)

    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: deps)

    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .staged)
    #expect(after.receipts.contains { $0.kind == "card_canceled" })
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect(row["executedAction"] != nil)
}

// MARK: - 2b. fix-round pins (gpt-5.5 review, 2026-06-11)

@Test
func reconcile_resumesDeferredInstall_onceGateOpens() async throws {
    // Finding 1: the closed-gate terminal is a DEFERRED state, not a
    // dead-end. Closed-gate approve → flip the gate → launch reconcile →
    // the installer fires. And the rail: while the gate stays closed, the
    // deferred lane is never re-entered.
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let closedDeps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let runId = "run-deferred-resume"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)

    // Approve at closed gate → deferred annotation, no fire.
    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: closedDeps)
    var row = try #require(try approvalRow(root: root, id: rec.id))
    let deferredOp = (row["executedAction"] as? [String: Any])?["op"] as? String
    #expect(deferredOp == "evolution_install_deferred")
    #expect(await recorder.rebuildFires == 0)

    // HARD RAIL: reconcile with the gate STILL closed → no resume, no fire.
    await NativeClient.reconcileUnappliedSelfEvolution(deps: closedDeps)
    #expect(await recorder.rebuildFires == 0)
    #expect(await recorder.promoteCalls.count == 1)

    // Flip the gate (fixture deps) and relaunch-reconcile → install resumes.
    let openDeps = try makeDeps(root: root, recorder: recorder, gateAllowed: true)
    await NativeClient.reconcileUnappliedSelfEvolution(deps: openDeps)
    #expect(await recorder.rebuildFires == 1)
    let pend = try JSONDecoder().decode(
        EvolutionPendingVerify.self,
        from: Data(contentsOf: pendingVerifyPath(root: root)))
    #expect(pend.runId == runId)
    row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("install fired") == true)
    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .installed)

    // Reconcile again: annotation is now self_evolution_install — no re-fire
    // (and the pending_verify heal guard backstops it anyway).
    await NativeClient.reconcileUnappliedSelfEvolution(deps: openDeps)
    #expect(await recorder.rebuildFires == 1)
}

@Test
func reconcile_pendingVerifySameRun_healsWithoutRefire() async throws {
    // Finding 2: crash window after pending_verify was staged / the install
    // fired but BEFORE the annotation landed. Reconcile re-enters the
    // executor; pending_verify for the same run = install already fired →
    // heal-only, installer recorder NOT called.
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let sha = "abc1234def5678" // makeDeps default promotedSha
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: true)
    let runId = "run-crash-heal"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    // Crash shape: resolved approved, NO annotation, pending_verify already
    // on disk for this run (the first executor's write-before-terminate).
    _ = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)
    let verifier = EvolutionVerifyRevert(dataRoot: root)
    _ = try await verifier.stagePendingVerify(
        runId: runId, proposalId: proposal.id, expectedSha: sha, revertSha: sha)

    await NativeClient.reconcileUnappliedSelfEvolution(deps: deps)

    // Installer NOT re-fired; annotation healed; pending_verify intact;
    // proposal healed to installed.
    #expect(await recorder.rebuildFires == 0)
    let pend = try JSONDecoder().decode(
        EvolutionPendingVerify.self,
        from: Data(contentsOf: pendingVerifyPath(root: root)))
    #expect(pend.runId == runId)
    let inbox = SwiftNativeApprovalInbox(root: root)
    let resolved = try await inbox.list(
        filter: ApprovalFilter(status: "resolved", action: NativeClient.selfEvolutionAction))
    let rec = try #require(resolved.first)
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("already fired") == true)
    let after = try #require(try await EvolutionProposalStore(dataRoot: root).get(id: proposal.id))
    #expect(after.status == .installed)
}

@Test
func evolutionExecutor_denyStoreFailure_annotatesFailed() async throws {
    // NIT 3: a deny whose store mutation fails must not annotate success.
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let inbox = SwiftNativeApprovalInbox(root: root)
    // Approval names a proposal that does NOT exist in the store.
    let created = try await inbox.create(.object([
        "title": .string("x"), "action": .string(NativeClient.selfEvolutionAction),
        "risk": .string("critical"), "reason": .string("x"),
        "payload": .object([
            "kind": .string("self_evolution"),
            "proposalId": .string("evo_missing"),
            "runId": .string("run-x"),
        ]),
    ]))
    let resolved = try await inbox.resolve(created.id, decision: .denied, decidedBy: "test")
    await NativeClient.applyResolvedSelfEvolution(from: resolved, deps: deps)
    let row = try #require(try approvalRow(root: root, id: created.id))
    #expect((row["detail"] as? String)?.contains("FAILED") == true)
    let executed = try #require(row["executedAction"] as? [String: Any])
    #expect((executed["error"] as? String)?.isEmpty == false)
}

@Test
func evolutionExecutor_missingExpectedHead_failsClosed() async throws {
    // Finding 4 (executor side): a proposal with no expectedHead has no CAS
    // basis — promote must never be reached.
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: true)
    let runId = "run-nohead"
    let store = EvolutionProposalStore(dataRoot: root)
    let p = try await store.propose(
        source: .external, title: "no head", evidence: "synthetic",
        diffText: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: nil)
    _ = try await store.transition(id: p.id, to: .building, candidateRunId: runId)
    _ = try await store.transition(id: p.id, to: .candidateGreen)
    _ = try await store.transition(id: p.id, to: .staged)
    let proposal = try #require(try await store.get(id: p.id))
    let rec = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)

    await NativeClient.applyResolvedSelfEvolution(from: rec, deps: deps)

    #expect(await recorder.promoteCalls.isEmpty)
    #expect(await recorder.rebuildFires == 0)
    let row = try #require(try approvalRow(root: root, id: rec.id))
    #expect((row["detail"] as? String)?.contains("FAILED") == true)
    #expect((row["detail"] as? String)?.contains("expectedHead") == true)
}

// MARK: - 3. crash-window reconcile + staging glue

@Test
func reconcileUnappliedSelfEvolution_refiresOnlyUnannotated() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let runId = "run-reconcile"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    // Crash shape: resolved through the inbox actor directly — no executor ran.
    _ = try await makeResolvedEvolutionApproval(
        root: root, proposal: proposal, runId: runId, decision: .approved)

    await NativeClient.reconcileUnappliedSelfEvolution(deps: deps)
    let firstCalls = await recorder.promoteCalls
    #expect(firstCalls.count == 1)

    // Second reconcile: the record is annotated now — nothing re-fires.
    await NativeClient.reconcileUnappliedSelfEvolution(deps: deps)
    let secondCalls = await recorder.promoteCalls
    #expect(secondCalls.count == 1)
}

@Test
func stageEvolutionApprovals_isIdempotentAndNeverAutoApproved() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runId = "run-stager"
    let store = EvolutionProposalStore(dataRoot: root)
    let p = try await store.propose(
        source: .weekly, title: "stage me", evidence: "evidence",
        diffText: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: "headsha123456")
    _ = try await store.transition(id: p.id, to: .building, candidateRunId: runId)
    _ = try await store.transition(id: p.id, to: .candidateGreen)

    await BackgroundLoopsAssembly.stageEvolutionApprovals(dataRoot: root)

    let inbox = SwiftNativeApprovalInbox(root: root)
    let pending = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
    #expect(pending.count == 1)
    let card = try #require(pending.first)
    // Plan design #7 pins: critical risk, pending (never resolved here).
    #expect(card.risk == "critical")
    #expect(card.status == "pending")
    // The visible card exists with id == approval id.
    #expect(try inboxCards(root: root).contains { ($0["id"] as? String) == card.id })
    // Proposal advanced to staged.
    #expect(try #require(try await store.get(id: p.id)).status == .staged)

    // Re-run: no duplicates (ensure, not create).
    await BackgroundLoopsAssembly.stageEvolutionApprovals(dataRoot: root)
    let pendingAgain = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
    #expect(pendingAgain.count == 1)
    #expect(try inboxCards(root: root).count == 1)

    // The generic launch reconciles must NOT execute/resolve a pending
    // evolution card (the no-auto-approve pin).
    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root, kinds: NativeClient.productionApprovalReconcileKinds())
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: true)
    await NativeClient.reconcileUnappliedSelfEvolution(deps: deps)
    let stillPending = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
    #expect(stillPending.count == 1)
    let calls = await recorder.promoteCalls
    #expect(calls.isEmpty)
    let fires = await recorder.rebuildFires
    #expect(fires == 0)
}

@Test
func stageEvolutionApprovals_restagesAfterCancel() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let deps = try makeDeps(root: root, recorder: recorder, gateAllowed: false)
    let runId = "run-restage"
    let store = EvolutionProposalStore(dataRoot: root)
    let p = try await store.propose(
        source: .chat, title: "restage me", evidence: "evidence",
        diffText: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: "headsha123456")
    _ = try await store.transition(id: p.id, to: .building, candidateRunId: runId)
    _ = try await store.transition(id: p.id, to: .candidateGreen)

    await BackgroundLoopsAssembly.stageEvolutionApprovals(dataRoot: root)
    let inbox = SwiftNativeApprovalInbox(root: root)
    let first = try #require(try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction)).first)

    // Cancel through the executor (resolve + cancel lane).
    let resolved = try await inbox.resolve(first.id, decision: .canceled, decidedBy: "test")
    await NativeClient.applyResolvedSelfEvolution(from: resolved, deps: deps)

    // Next staging pass creates a FRESH pending card.
    await BackgroundLoopsAssembly.stageEvolutionApprovals(dataRoot: root)
    let pending = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
    #expect(pending.count == 1)
    #expect(pending.first?.id != first.id)
}

// MARK: - 4. verify-at-launch

@Test
func verifyAtLaunch_shaMatchGreenDoctor_marksVerifiedAndCards() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let sha = "cafef00d12345678"
    let runId = "run-verify"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let store = EvolutionProposalStore(dataRoot: root)
    _ = try await store.transition(id: proposal.id, to: .approved)
    _ = try await store.transition(id: proposal.id, to: .installed, promotedCommitSha: sha)
    let verifier = EvolutionVerifyRevert(dataRoot: root)
    _ = try await verifier.stagePendingVerify(
        runId: runId, proposalId: proposal.id, expectedSha: sha, revertSha: sha)

    let deps = try makeDeps(
        root: root, recorder: recorder, gateAllowed: false, bundleSha: sha, doctor: .green)
    await NativeClient.runEvolutionVerifyAtLaunch(deps: deps)

    #expect(!FileManager.default.fileExists(atPath: pendingVerifyPath(root: root).path))
    let after = try #require(try await store.get(id: proposal.id))
    #expect(after.status == .verified)
    let cards = try inboxCards(root: root)
    #expect(cards.contains { ($0["title"] as? String)?.contains("updated itself") == true })
    let reverts = await recorder.revertCalls
    #expect(reverts.isEmpty)
}

@Test
func verifyAtLaunch_postGraceShaMismatch_autoReverts() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = EvoRecorder()
    let sha = "deadbeef12345678"
    let runId = "run-revert"
    let proposal = try await makeStagedProposal(root: root, runId: runId)
    let store = EvolutionProposalStore(dataRoot: root)
    _ = try await store.transition(id: proposal.id, to: .approved)
    _ = try await store.transition(id: proposal.id, to: .installed, promotedCommitSha: sha)

    // Plant a pending record created well past the install grace.
    let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
    let pending = EvolutionPendingVerify(
        runId: runId, proposalId: proposal.id,
        expectedSha: sha, revertSha: sha,
        attempts: 0, createdAt: old, updatedAt: old)
    let path = pendingVerifyPath(root: root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(pending).write(to: path)

    // Bundle still on the OLD sha → revert decision.
    let deps = try makeDeps(
        root: root, recorder: recorder, gateAllowed: false,
        bundleSha: "0ldsha000000", doctor: .green)
    await NativeClient.runEvolutionVerifyAtLaunch(deps: deps)

    let reverts = await recorder.revertCalls
    #expect(reverts == [sha])
    #expect(!FileManager.default.fileExists(atPath: path.path))
    let after = try #require(try await store.get(id: proposal.id))
    #expect(after.status == .reverted)
    let cards = try inboxCards(root: root)
    #expect(cards.contains { ($0["title"] as? String)?.contains("auto-reverted") == true })
    // Gate closed → reinstall NOT fired; the card says awaiting.
    let fires = await recorder.rebuildFires
    #expect(fires == 0)
}

// MARK: - 5. scripted dry-run (plan wave-2 verification standard)

/// The full record trail with ONLY the installer stubbed: a real diff filed
/// into the real store → green candidate evidence → real staging glue →
/// real approval resolve → executor with the REAL EvolutionPromoter
/// committing to a fixture git repo → pending_verify written → annotations
/// correct. No live install fires (the stub records instead) — the first
/// live fire is the user-witnessed close-out.
@Test
func endToEnd_dryRun_proposeToStagedInstall_withRealPromoter() async throws {
    let root = try makeEvoTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Fixture repo with a real diff.
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    func git(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "e2e-git", code: Int(p.terminationStatus))
        }
    }
    func gitOut(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    try git(["init", "-q", "-b", "main"])
    try git(["config", "user.email", "test@local"])
    try git(["config", "user.name", "Test User"])
    try git(["config", "commit.gpgsign", "false"])
    try "hello\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
    try git(["add", "-A"])
    try git(["commit", "-q", "-m", "seed"])
    let head = try gitOut(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try "evolved\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
    let diff = try gitOut(["diff"])
    try "hello\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)

    // 1. Propose (real store) and walk to candidate_green.
    let runId = "run-e2e"
    let store = EvolutionProposalStore(dataRoot: root)
    let proposal = try await store.propose(
        source: .chat, title: "e2e dry-run change", evidence: "scripted dry-run",
        diffText: diff, expectedHead: head)
    _ = try await store.transition(id: proposal.id, to: .building, candidateRunId: runId)
    _ = try await store.transition(id: proposal.id, to: .candidateGreen)

    // 2. Green candidate evidence (the wave-1 builder's persisted verdict shape).
    let diffSha = try #require(proposal.diffSHA256)
    // Raw JSON on purpose: this is the on-disk contract the wave-1 builder
    // persists (the struct's memberwise init is module-internal).
    let resultJSON: [String: Any] = [
        "runId": runId, "proposalId": proposal.id, "ok": true,
        "phase": "complete", "expectedHead": head, "diffSHA256": diffSha,
        "touchedPaths": ["seed.txt"], "testFilters": ["SelfImprovementTests"],
        "escalatedFullSuite": false, "buildExit": 0, "testExit": 0,
        "startedAt": isoEvoNow(), "finishedAt": isoEvoNow(),
        "worktreeCleaned": true,
    ]
    let candDir = root.appendingPathComponent("evolution/candidates/\(runId)", isDirectory: true)
    try FileManager.default.createDirectory(at: candDir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: resultJSON)
        .write(to: candDir.appendingPathComponent("result.json"))

    // 3. Real staging glue → card.
    await BackgroundLoopsAssembly.stageEvolutionApprovals(dataRoot: root)
    let inbox = SwiftNativeApprovalInbox(root: root)
    let card = try #require(try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction)).first)
    #expect(card.risk == "critical")

    // 4. Human approve → executor with the REAL promoter, stubbed installer.
    let resolved = try await inbox.resolve(card.id, decision: .approved, decidedBy: "test")
    let recorder = EvoRecorder()
    var deps = try makeDeps(root: root, recorder: recorder, gateAllowed: true)
    deps.promote = { rid, pid, text, expHead, sha in
        await EvolutionPromoter(repoRoot: repo, dataRoot: root).promote(
            runId: rid, proposalId: pid, diffText: text,
            expectedHead: expHead, expectedDiffSHA256: sha)
    }
    await NativeClient.applyResolvedSelfEvolution(from: resolved, deps: deps)

    // 5. The trail: real commit landed with the marker…
    let seed = try String(contentsOf: repo.appendingPathComponent("seed.txt"), encoding: .utf8)
    #expect(seed == "evolved\n")
    let message = try gitOut(["log", "-1", "--format=%B"])
    #expect(message.contains(EvolutionPromoter.commitMarker(runId: runId)))
    let newHead = try gitOut(["rev-parse", "--short=12", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // …pending_verify written for that commit…
    let pend = try JSONDecoder().decode(
        EvolutionPendingVerify.self,
        from: Data(contentsOf: pendingVerifyPath(root: root)))
    #expect(pend.runId == runId)
    #expect(pend.expectedSha == newHead)
    // …installer stub fired once, annotation correct…
    let fires = await recorder.rebuildFires
    #expect(fires == 1)
    let row = try #require(try approvalRow(root: root, id: card.id))
    #expect((row["detail"] as? String)?.contains("install fired") == true)
    // …proposal at installed with the promoted commit.
    let after = try #require(try await store.get(id: proposal.id))
    #expect(after.status == .installed)
    #expect(after.promotedCommitSha == newHead)
}

private func isoEvoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}
