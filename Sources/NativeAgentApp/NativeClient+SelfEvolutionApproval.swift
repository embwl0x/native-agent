import Foundation
import PersistenceCore
import ApprovalInbox
import SelfImprovement
import SystemOps
import DoctorChecks
import TrustCenter

extension NativeClient {
    // MARK: - U2b wave 2: self-evolution approval executor
    //
    // The approval-loop wiring for the U2b evolution engine (plan:
    // docs/build_plans/u2b-self-evolution-loop.md, wave 2). Mirrors the U3w2
    // executor canon: self-defensive guard on action/status/decision, EVERY
    // terminal path annotated via annotateApprovalExecution, crash-window
    // launch reconcile keyed on "resolved + no executedAction".
    //
    // HARD RAILS (wave 2 ships INERT):
    //   • Evolution cards are NEVER auto-approved. The engine pins
    //     risk=critical + autoApprove=false on every proposal record; this
    //     executor only ever runs on records a human resolved through
    //     resolveApproval (live policy's autoApproveLowRiskImprovements has
    //     no Swift consumer, and this lane adds none).
    //   • The install leg fires ONLY through SystemOps.systemRebuild's own
    //     trust gates (enableAutonomy + Trust Center + per-action
    //     systemRebuild.enabled, default false) — and this executor
    //     preflights the SAME composite gate and STOPS at the boundary with
    //     an annotated "awaiting systemRebuild.enabled" terminal when it is
    //     closed, so with the flag off the rebuild runner is never invoked
    //     (test-pinned in SelfEvolutionWiringTests).

    static let selfEvolutionAction = "self_evolution.apply"
    /// executedAction.op for an approved install stopped at the closed
    /// systemRebuild gate (gpt-5.5 fix-round): NOT a dead-end terminal —
    /// reconcileUnappliedSelfEvolution rescans records carrying this op once
    /// the gate is open, so the approved install resumes after the flip.
    static let selfEvolutionDeferredInstallOp = "evolution_install_deferred"

    /// Test-injectable seams for the self-evolution executor. Production
    /// wiring is `.production()`; tests inject recorders + fixture roots so
    /// no real repo, policy file, bundle, or installer is ever touched.
    struct SelfEvolutionDeps: Sendable {
        var dataRoot: URL
        /// Promote the proposal's diff onto the live repo (EvolutionPromoter:
        /// green-evidence gate + expectedHead CAS + marker idempotency).
        /// (runId, proposalId, diffText, expectedHead, diffSHA256) → outcome.
        /// expectedHead is NON-OPTIONAL (gpt-5.5 fix-round): a proposal
        /// without one fails closed in the executor — promoting with no
        /// expected-head CAS is never an option.
        var promote: @Sendable (String, String, String, String, String) async -> EvolutionPromoteOutcome
        /// The systemRebuild boundary preflight. MUST mirror the composite
        /// gate inside SwiftNativeSystemRebuildClient.systemRebuild() —
        /// checked here so the executor can stop BEFORE staging install
        /// state (rollback bundle + pending_verify) when the gate is closed.
        var rebuildGate: @Sendable () async -> (allowed: Bool, reason: String)
        /// Fire the real installer (its own gates re-check — never bypassed).
        var fireRebuild: @Sendable () async throws -> String
        /// `git revert` a promoted commit (auto-revert lane). Returns new HEAD.
        var revertCommit: @Sendable (String) async throws -> String
        /// The live bundle to copy aside before an install.
        var bundleURL: URL
        /// The running bundle's stamped Resources/VERSION_SHA (nil = mismatch).
        var currentBundleSha: @Sendable () -> String?
        /// Post-restart quick health read for the verify decision.
        var doctorState: @Sendable () async -> EvolutionDoctorState

        static func production() -> SelfEvolutionDeps {
            let dataRoot = PersistenceCore.defaultDataRoot()
            let repoRoot = NativeClient.evolutionRepoRoot(dataRoot: dataRoot)
            return SelfEvolutionDeps(
                dataRoot: dataRoot,
                promote: { runId, proposalId, diffText, expectedHead, diffSha in
                    await EvolutionPromoter(repoRoot: repoRoot, dataRoot: dataRoot).promote(
                        runId: runId, proposalId: proposalId, diffText: diffText,
                        expectedHead: expectedHead, expectedDiffSHA256: diffSha)
                },
                rebuildGate: {
                    // Mirror of SwiftNativeSystemRebuildClient's gate: the
                    // factory (makeSystemRebuildClient) constructs with
                    // daemonAutonomy=false (closed-fail default), so the
                    // composite here uses the same value — if the factory is
                    // ever seeded for real, update BOTH or the preflight lies.
                    let policy = await readAutonomyTrustPolicy()
                    switch checkTrustPolicyForAction(
                        .systemRebuild, daemonAutonomy: false, policy: policy) {
                    case .allowed: return (true, "")
                    case .denied(let reason): return (false, reason)
                    }
                },
                fireRebuild: {
                    let result = try await makeSystemRebuildClient().systemRebuild()
                    guard result.ok else {
                        throw NSError(domain: "NativeAgentSelfEvolution", code: 500, userInfo: [
                            NSLocalizedDescriptionKey: result.error ?? "rebuild refused"])
                    }
                    return result.message ?? "rebuild started"
                },
                revertCommit: { sha in
                    try await SelfImprovementGitOps(repoRoot: repoRoot)
                        .revertCommit(commitSha: sha, expectedCommitSha: nil)
                },
                bundleURL: Bundle.main.bundleURL,
                currentBundleSha: {
                    Bundle.main.resourceURL.flatMap {
                        EvolutionVerifyRevert.readBundleVersionSha(resourcesDir: $0)
                    }
                },
                doctorState: {
                    // Conservative v1 mapping (NEEDS-USER #4 owns the final
                    // "Doctor-fail" definition): all-ok → green; any warn or
                    // fail → degraded (verifiedDegraded carries it to the
                    // card); a throwing doctor → unknown. NEVER critical from
                    // doctor alone — auto-revert triggers stay attempts-
                    // exceeded + post-grace sha-mismatch.
                    do {
                        let checks = try await SwiftNativeDoctorChecks()
                            .runAll(repair: false, checkLLM: false)
                        return checks.allSatisfy { $0.status == "ok" } ? .green : .degraded
                    } catch {
                        return .unknown
                    }
                }
            )
        }
    }

    /// Walk up from the data root to the repo checkout (script/install_app.sh
    /// marker — same convention as SystemOps.locateRepoRoot).
    static func evolutionRepoRoot(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        var dir = dataRoot
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("script")
                .appendingPathComponent("install_app.sh")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return dataRoot.deletingLastPathComponent()
    }

    /// Executes a resolved self_evolution.apply record. Self-defensive: acts
    /// only on resolved records of this action, switches on decision (deny
    /// and cancel ACT too — store status + annotation), and annotates EVERY
    /// terminal path so "resolved + no executedAction" stays an exact
    /// crash-window key for the launch reconcile.
    static func applyResolvedSelfEvolution(
        from rec: ApprovalRecord,
        deps: SelfEvolutionDeps
    ) async {
        guard rec.action == selfEvolutionAction,
              rec.status == "resolved",
              let decision = rec.decision else { return }
        // Payload contract (staged by BackgroundLoopsAssembly.stageEvolutionApprovals).
        guard case .object(let payload) = rec.payload,
              case .string(let proposalId)? = payload["proposalId"], !proposalId.isEmpty,
              case .string(let runId)? = payload["runId"], !runId.isEmpty else {
            NSLog("[selfEvolution] missing proposalId/runId on approval \(rec.id)")
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["error": .string("missing proposalId/runId")]),
                detail: "self-evolution \(decision) FAILED: payload carries no proposalId/runId",
                root: deps.dataRoot)
            return
        }
        let store = EvolutionProposalStore(dataRoot: deps.dataRoot)
        switch decision {
        case "approved":
            await applyApprovedSelfEvolution(
                rec: rec, proposalId: proposalId, runId: runId,
                payload: payload, store: store, deps: deps)
        case "denied":
            // Deny is terminal for the proposal: never re-proposed. The
            // annotation reflects the ACTUAL store outcome (gpt-5.5
            // fix-round: a swallowed mutation failure must not read as
            // success in the audit trail).
            var denyFailure: String?
            do {
                let t = try await store.transition(
                    id: proposalId, to: .denied,
                    require: [.staged, .candidateGreen],
                    receipt: "denied via approval \(rec.id)",
                    denyReason: "denied via approval card")
                if !(t.applied || t.proposal.status == .denied) {
                    denyFailure = "deny transition not applied — proposal in status \(t.proposal.status.rawValue)"
                }
            } catch {
                denyFailure = "proposal store mutation failed: \(error)"
            }
            if let denyFailure {
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("self_evolution_deny"),
                        "proposalId": .string(proposalId),
                        "error": .string(denyFailure),
                    ]),
                    detail: "self-evolution deny FAILED: \(denyFailure)",
                    root: deps.dataRoot)
            } else {
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("self_evolution_deny"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "self-evolution denied — proposal marked denied; will not be re-proposed",
                    root: deps.dataRoot)
            }
        default: // canceled
            // Cancel keeps the proposal staged; the launch stager re-creates
            // a fresh card (REM stamp-clear pattern, adapted: the receipt is
            // the audit trail, the absent pending approval is the re-stage key).
            // Same fix-round rule as deny: annotation reflects the actual
            // store outcome.
            var cancelFailure: String?
            do {
                try await store.appendReceipt(
                    id: proposalId, kind: "card_canceled",
                    detail: "approval \(rec.id) canceled — a fresh card re-stages at next launch")
            } catch {
                cancelFailure = "proposal store mutation failed: \(error)"
            }
            if let cancelFailure {
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("self_evolution_cancel"),
                        "proposalId": .string(proposalId),
                        "error": .string(cancelFailure),
                    ]),
                    detail: "self-evolution cancel FAILED: \(cancelFailure)",
                    root: deps.dataRoot)
            } else {
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("self_evolution_cancel"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "self-evolution canceled — proposal stays staged; next launch re-stages a fresh card",
                    root: deps.dataRoot)
            }
        }
    }

    /// The approved lane. Order (plan wave-2 spec, gpt-5.5 fix-round):
    /// green-candidate-gated promote → systemRebuild boundary preflight →
    /// [gate closed: annotated DEFERRED (op evolution_install_deferred) —
    /// no rollback bundle, no pending_verify: staging install-recovery state
    /// for an install that cannot fire would auto-revert a never-installed
    /// commit at the next launch; the launch reconcile resumes the install
    /// once the gate opens] → [gate open: pending_verify-same-run re-fire
    /// guard (heal-only) → rollback aside → pending_verify
    /// write-before-terminate → status installed → fire rebuild] → annotate.
    private static func applyApprovedSelfEvolution(
        rec: ApprovalRecord,
        proposalId: String,
        runId: String,
        payload: [String: JSONValue],
        store: EvolutionProposalStore,
        deps: SelfEvolutionDeps
    ) async {
        func fail(_ op: String, _ why: String) async {
            NSLog("[selfEvolution] \(op) failed for \(proposalId): \(why)")
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string(op),
                    "proposalId": .string(proposalId),
                    "runId": .string(runId),
                    "error": .string(why),
                ]),
                detail: "self-evolution apply FAILED: \(why)",
                root: deps.dataRoot)
        }

        let proposal: EvolutionProposal
        do {
            guard let loaded = try await store.get(id: proposalId) else {
                await fail("self_evolution_apply", "proposal not found: \(proposalId)")
                return
            }
            proposal = loaded
        } catch {
            await fail("self_evolution_apply", "proposal store read failed: \(error)")
            return
        }

        // Reconcile re-runs land here with the proposal already past staged.
        // Terminal statuses heal the annotation without side effects.
        switch proposal.status {
        case .denied, .reverted, .verified:
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("self_evolution_apply"),
                    "proposalId": .string(proposalId),
                    "healed": .string("proposal already \(proposal.status.rawValue)"),
                ]),
                detail: "self-evolution annotation healed — proposal already \(proposal.status.rawValue)",
                root: deps.dataRoot)
            return
        case .staged, .approved, .installed:
            break
        default:
            await fail("self_evolution_apply",
                       "proposal in unexpected status \(proposal.status.rawValue) — refusing")
            return
        }

        // CAS the card against the record: the diff sha and candidate run the
        // human approved must be the diff sha and run we execute.
        guard let diffText = proposal.diffText,
              let diffSha = proposal.diffSHA256,
              case .string(let approvedSha)? = payload["diffSHA256"],
              approvedSha.lowercased() == diffSha.lowercased() else {
            await fail("self_evolution_apply", "diff sha mismatch between approval card and proposal record")
            return
        }
        guard proposal.candidateRunId == runId else {
            await fail("self_evolution_apply",
                       "candidate run mismatch: card \(runId), record \(proposal.candidateRunId ?? "nil")")
            return
        }
        // Fail-closed CAS basis (gpt-5.5 fix-round): a proposal without an
        // expectedHead cannot anchor the promote's expected-head CAS —
        // refuse here rather than commit onto an unverified HEAD.
        guard let expectedHead = proposal.expectedHead,
              !expectedHead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await fail("self_evolution_promote",
                       "proposal carries no expectedHead — promote refused (no CAS basis)")
            return
        }

        // staged → approved (idempotent for re-runs already at approved/installed).
        if proposal.status == .staged {
            let t = try? await store.transition(
                id: proposalId, to: .approved, require: [.staged],
                receipt: "approved via approval \(rec.id)")
            guard let t, t.applied || t.proposal.status == .approved || t.proposal.status == .installed else {
                await fail("self_evolution_apply",
                           "could not mark approved (now \((try? await store.get(id: proposalId))?.status.rawValue ?? "?"))")
                return
            }
        }

        // Promote (green-evidence gate + expectedHead CAS + marker idempotency
        // all live inside EvolutionPromoter).
        let outcome = await deps.promote(runId, proposalId, diffText, expectedHead, diffSha)
        guard outcome.ok, let commitSha = outcome.commitSha else {
            let why = outcome.error ?? "unknown promote failure"
            try? await store.appendReceipt(id: proposalId, kind: "promote_failed", detail: why)
            await fail("self_evolution_promote", why)
            return
        }
        try? await store.appendReceipt(
            id: proposalId,
            kind: outcome.alreadyPromoted ? "promote_idempotent" : "promoted",
            detail: "commit \(commitSha)")

        // ── systemRebuild boundary ────────────────────────────────────────
        let gate = await deps.rebuildGate()
        guard gate.allowed else {
            // DEFERRED INSTALL (gpt-5.5 fix-round — not a dead-end): promoted,
            // install NOT fired, nothing staged that could trigger an
            // auto-revert. The op below — "evolution_install_deferred" — is
            // the explicit resume key: reconcileUnappliedSelfEvolution
            // rescans annotated records carrying it ONLY when the gate is
            // open, so flipping systemRebuild.enabled and relaunching
            // resumes this approved install.
            try? await store.appendReceipt(
                id: proposalId, kind: "install_deferred",
                detail: "systemRebuild gate closed: \(gate.reason)")
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string(selfEvolutionDeferredInstallOp),
                    "proposalId": .string(proposalId),
                    "runId": .string(runId),
                    "commitSha": .string(commitSha),
                    "install": .string("awaiting systemRebuild.enabled"),
                ]),
                detail: "self-evolution promoted commit \(String(commitSha.prefix(12))) — "
                    + "install NOT fired: awaiting systemRebuild.enabled (\(gate.reason)); "
                    + "resumes at launch once the gate opens",
                root: deps.dataRoot)
            return
        }

        // Install leg (gate open — first witnessed fire is the NEEDS-USER
        // close-out; workers never reach here in production because the
        // per-action flag defaults false).
        let verifier = EvolutionVerifyRevert(dataRoot: deps.dataRoot)
        // Re-fire guard (gpt-5.5 fix-round): a pending_verify for THIS run
        // already on disk means a prior (crashed) executor staged AND fired
        // this install — the rebuild lock does not survive process death, so
        // re-entering the fire path could double-install. Heal the proposal
        // status + annotation only; never fire again. Verify-at-launch owns
        // the record from here.
        do {
            if let pending = try await verifier.currentPendingVerify(), pending.runId == runId {
                _ = try? await store.transition(
                    id: proposalId, to: .installed, require: [.approved],
                    receipt: "installed (healed at reconcile — pending_verify already staged)",
                    promotedCommitSha: commitSha)
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("self_evolution_install"),
                        "proposalId": .string(proposalId),
                        "runId": .string(runId),
                        "commitSha": .string(commitSha),
                        "install": .string("already_fired_healed"),
                    ]),
                    detail: "self-evolution install already fired for commit "
                        + "\(String(commitSha.prefix(12))) (pending_verify present for this run) — "
                        + "annotation healed; verify runs at next launch",
                    root: deps.dataRoot)
                return
            }
        } catch {
            // Fail-closed: an unreadable pending_verify means we cannot prove
            // the install did NOT fire — refusing beats double-installing.
            await fail("self_evolution_install",
                       "pending_verify read failed (install refused): \(error)")
            return
        }
        do {
            _ = try await verifier.copyBundleAside(bundlePath: deps.bundleURL, runId: runId)
        } catch let e as EvolutionEngineError {
            if case .rollbackCopyFailed(let d) = e, d.contains("aside already exists") {
                // Re-run after a crash mid-leg: the aside from the first
                // attempt is the rollback artifact — keep it.
            } else {
                await fail("self_evolution_install", "rollback aside failed (install refused): \(e.errorDescription ?? "\(e)")")
                return
            }
        } catch {
            await fail("self_evolution_install", "rollback aside failed (install refused): \(error)")
            return
        }
        do {
            _ = try await verifier.stagePendingVerify(
                runId: runId, proposalId: proposalId,
                expectedSha: commitSha, revertSha: commitSha)
        } catch let e as EvolutionEngineError {
            if case .alreadyPendingVerify(let existing) = e, existing == runId {
                // Same run already staged (crash re-run) — continue.
            } else {
                await fail("self_evolution_install", "pending_verify stage refused: \(e.errorDescription ?? "\(e)")")
                return
            }
        } catch {
            await fail("self_evolution_install", "pending_verify stage failed: \(error)")
            return
        }
        _ = try? await store.transition(
            id: proposalId, to: .installed, require: [.approved],
            receipt: "install staged for approval \(rec.id)",
            promotedCommitSha: commitSha)
        do {
            let message = try await deps.fireRebuild()
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("self_evolution_install"),
                    "proposalId": .string(proposalId),
                    "runId": .string(runId),
                    "commitSha": .string(commitSha),
                    "install": .string("fired"),
                ]),
                detail: "self-evolution install fired for commit \(String(commitSha.prefix(12))) — "
                    + "\(message); post-restart verify runs at next launch",
                root: deps.dataRoot)
        } catch SystemOpsError.rebuildInProgress {
            // A prior fire's installer holds the rebuild lock — the install
            // IS running. Keep pending_verify; heal the annotation.
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("self_evolution_install"),
                    "proposalId": .string(proposalId),
                    "runId": .string(runId),
                    "commitSha": .string(commitSha),
                    "install": .string("already_in_progress"),
                ]),
                detail: "self-evolution install already in progress for commit "
                    + "\(String(commitSha.prefix(12))) — verify runs at next launch",
                root: deps.dataRoot)
        } catch {
            // Spawn failed: clear the pending record so a dead install can't
            // auto-revert a commit that never shipped. The commit stays
            // promoted; the receipt + annotation say exactly what to do.
            try? await verifier.clearPendingVerify(runId: runId)
            try? await store.appendReceipt(
                id: proposalId, kind: "install_spawn_failed",
                detail: "\(error) — pending verify cleared; commit \(commitSha) remains promoted; manual rebuild needed")
            await fail("self_evolution_install",
                       "rebuild spawn failed: \(error.localizedDescription) — pending verify cleared; "
                       + "commit \(String(commitSha.prefix(12))) remains promoted (manual rebuild needed)")
        }
    }

    /// Crash-window launch reconcile (U3w2 canon): resolved self_evolution
    /// records lacking an execution annotation get the idempotent executor
    /// re-run. ALL decisions reconcile — deny and cancel have store effects
    /// and annotate too, so an unannotated denied/canceled record is also a
    /// genuine crash window (unlike self_improvement.apply, whose deny path
    /// never annotates by design).
    ///
    /// Second lane (gpt-5.5 fix-round): DEFERRED-INSTALL RESUME. An approved
    /// install that hit the closed systemRebuild gate is annotated with
    /// op == selfEvolutionDeferredInstallOp. When the gate is OPEN at launch,
    /// those records re-enter the executor (promote is idempotent; the
    /// install leg now fires). HARD RAIL: gate closed → the deferred lane is
    /// not even scanned, so nothing can reach install while systemRebuild is
    /// off.
    static func reconcileUnappliedSelfEvolution(deps: SelfEvolutionDeps) async {
        let inbox = SwiftNativeApprovalInbox(root: deps.dataRoot)
        let resolved: [ApprovalRecord]
        do {
            resolved = try await inbox.list(
                filter: ApprovalFilter(status: "resolved", action: selfEvolutionAction))
        } catch {
            NSLog("[selfEvolution] reconciliation scan failed: \(String(describing: error))")
            return
        }
        for rec in resolved where rec.executedAction == nil {
            NSLog("[selfEvolution] reconciling unexecuted resolved \(rec.id) "
                + "(decision: \(rec.decision ?? "?"))")
            await applyResolvedSelfEvolution(from: rec, deps: deps)
        }
        // Deferred-install resume — gate checked FIRST so the lane stays
        // provably unreachable while systemRebuild is off.
        let gate = await deps.rebuildGate()
        guard gate.allowed else { return }
        for rec in resolved where isDeferredEvolutionInstall(rec) {
            NSLog("[selfEvolution] resuming deferred install \(rec.id) — gate now open")
            await applyResolvedSelfEvolution(from: rec, deps: deps)
        }
    }

    /// True for a resolved-approved record whose execution annotation is the
    /// closed-gate deferred-install marker (the resume rescan key).
    private static func isDeferredEvolutionInstall(_ rec: ApprovalRecord) -> Bool {
        guard rec.decision == "approved",
              case .object(let executed)? = rec.executedAction,
              case .string(let op)? = executed["op"] else { return false }
        return op == selfEvolutionDeferredInstallOp
    }

    /// Launch-side post-install verify (plan design #4): consult the
    /// EvolutionVerifyRevert state machine and execute its decision.
    /// verified/verifiedDegraded → proposal verified + success card (the
    /// "app updated itself" surface, P1 fold-in). revert → git revert the
    /// promoted commit, clear pending, proposal reverted, card with reason,
    /// then reinstall-of-reverted-source through the SAME rebuild gate.
    /// waitRetry → installer may still be running, do nothing. corrupt →
    /// surfaced for a human, never deleted.
    static func runEvolutionVerifyAtLaunch(deps: SelfEvolutionDeps) async {
        let verifier = EvolutionVerifyRevert(dataRoot: deps.dataRoot)
        let store = EvolutionProposalStore(dataRoot: deps.dataRoot)
        let decision: EvolutionVerifyDecision
        do {
            decision = try await verifier.checkAtLaunch(
                currentBundleSha: deps.currentBundleSha(),
                doctor: deps.doctorState)
        } catch {
            NSLog("[selfEvolution] verify-at-launch failed: \(String(describing: error))")
            return
        }
        switch decision {
        case .noPending, .waitRetry:
            return
        case .corrupt(let detail):
            await appendEvolutionInboxCard(
                dataRoot: deps.dataRoot,
                severity: "actionable",
                title: "Self-evolution verify record is corrupt",
                summary: "pending_verify.json could not be read — left in place for inspection.",
                detail: detail)
        case .verified(let rec), .verifiedDegraded(let rec, _):
            var doctorNote = ""
            if case .verifiedDegraded(_, let doctor) = decision {
                doctorNote = " Doctor reported \(doctor.rawValue) — worth a glance."
            }
            // approved → installed → verified (the first hop covers a crash
            // before the executor's installed transition landed).
            _ = try? await store.transition(
                id: rec.proposalId, to: .installed, require: [.approved],
                receipt: "installed (healed at verify)",
                promotedCommitSha: rec.expectedSha)
            _ = try? await store.transition(
                id: rec.proposalId, to: .verified, require: [.installed],
                receipt: "verified at launch — bundle sha \(String(rec.expectedSha.prefix(12)))")
            await appendEvolutionInboxCard(
                dataRoot: deps.dataRoot,
                severity: "info",
                title: "NativeAgent updated itself",
                summary: "Evolution run \(rec.runId) installed and verified — bundle now at "
                    + "\(String(rec.expectedSha.prefix(12))).\(doctorNote)",
                detail: "proposal \(rec.proposalId); attempts \(rec.attempts)")
        case .revert(let rec, let reason):
            do {
                let newHead = try await deps.revertCommit(rec.revertSha)
                try? await verifier.clearPendingVerify(runId: rec.runId)
                _ = try? await store.transition(
                    id: rec.proposalId, to: .installed, require: [.approved],
                    receipt: "installed (healed before revert)",
                    promotedCommitSha: rec.revertSha)
                _ = try? await store.transition(
                    id: rec.proposalId, to: .reverted, require: [.installed],
                    receipt: "auto-reverted (\(reason.rawValue)) — revert commit \(String(newHead.prefix(12)))")
                // Reinstall the reverted source through the same gate.
                var reinstallNote: String
                let gate = await deps.rebuildGate()
                if gate.allowed {
                    do {
                        let msg = try await deps.fireRebuild()
                        reinstallNote = "Reinstall of reverted source fired: \(msg)."
                    } catch {
                        reinstallNote = "Reinstall spawn FAILED (\(error.localizedDescription)) — "
                            + "rollback bundle at \(verifier.rollbackBundleDir(runId: rec.runId).path)."
                    }
                } else {
                    reinstallNote = "Reinstall awaiting systemRebuild.enabled — "
                        + "rollback bundle at \(verifier.rollbackBundleDir(runId: rec.runId).path)."
                }
                await appendEvolutionInboxCard(
                    dataRoot: deps.dataRoot,
                    severity: "actionable",
                    title: "Self-evolution auto-reverted",
                    summary: "Run \(rec.runId) failed post-install verify (\(reason.rawValue)). "
                        + "Source reverted at \(String(newHead.prefix(12))). \(reinstallNote)",
                    detail: "proposal \(rec.proposalId); expected sha \(rec.expectedSha); attempts \(rec.attempts)")
            } catch {
                // Revert refused (conflict / non-ancestor): pending_verify is
                // KEPT as the evidence record; surface for a human.
                await appendEvolutionInboxCard(
                    dataRoot: deps.dataRoot,
                    severity: "actionable",
                    title: "Self-evolution revert FAILED — manual intervention",
                    summary: "Run \(rec.runId) needs revert (\(reason.rawValue)) but git revert failed: "
                        + "\(error.localizedDescription). Rollback bundle at "
                        + "\(verifier.rollbackBundleDir(runId: rec.runId).path).",
                    detail: "revert sha \(rec.revertSha); pending_verify kept as evidence")
            }
        }
    }

    /// Info/alert card for the evolution lane in notifications/inbox.jsonl
    /// (the store the Inbox UI reads). Append-only with a fresh id —
    /// idempotency is not needed: every call site is a launch-side terminal
    /// that fires at most once per pending_verify record.
    static func appendEvolutionInboxCard(
        dataRoot: URL,
        severity: String,
        title: String,
        summary: String,
        detail: String
    ) async {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let itemId = UUID().uuidString.lowercased()
        let card: JSONValue = .object([
            "id": .string(itemId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("self_evolution"),
            "severity": .string(severity),
            "title": .string(title),
            "summary": .string(summary),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            // 2026-07-21 audit (MED): same shared capped append as the other
            // notifications/inbox.jsonl writers — the LIVE inbox must not
            // grow unbounded.
            try await appendJSONLCapped(
                card, to: inboxPath, using: persistence,
                maxLines: JSONLLineCaps.notificationInbox,
                logLabel: "SelfEvolution.inbox"
            )
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: itemId,
                title: title,
                summary: summary,
                source: "self_evolution",
                severity: severity
            )
        } catch {
            NSLog("[selfEvolution] inbox card append failed: \(String(describing: error))")
        }
    }
}
