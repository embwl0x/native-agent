import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - U2b wave 2: evolution promote seam
//
// The wave-2 executor's promote step. The orchestrator's `promote(runId:)`
// only serves its OWN ledger/pending runs (improvements/runs.json +
// pending_actions.json); evolution proposals live in the EvolutionProposalStore
// and their build evidence in `<dataRoot>/evolution/candidates/<runId>/result.json`.
// This promoter replays a proposal's diff onto the LIVE repo via the existing
// `SelfImprovementGitOps.applyDiffAndCommit` (clean-tree precondition,
// expectedHead CAS, 3-way apply, identity-pinned commit) with the validation
// callback upgraded per plan design #2: instead of the NativeAgentCore-only
// inline build, the gate is a PRIOR GREEN candidate result.json for the SAME
// diff sha — the full-app worktree build+test is the real evidence.
//
// SAFETY: nothing here installs, restarts, or touches policy files. The
// output is exactly one git commit on the live repo (or a typed refusal).
public struct EvolutionPromoteOutcome: Sendable, Equatable {
    public var ok: Bool
    public var commitSha: String?
    /// True when the promotion commit for this runId already existed —
    /// the crash-window idempotency path (executor re-run after a crash
    /// between commit and annotation). No second commit is made.
    public var alreadyPromoted: Bool
    public var error: String?

    public init(ok: Bool, commitSha: String? = nil, alreadyPromoted: Bool = false, error: String? = nil) {
        self.ok = ok
        self.commitSha = commitSha
        self.alreadyPromoted = alreadyPromoted
        self.error = error
    }
}

public struct EvolutionPromoter: Sendable {
    private let repoRoot: URL
    private let dataRoot: URL

    public init(repoRoot: URL, dataRoot: URL = defaultDataRoot()) {
        self.repoRoot = repoRoot
        self.dataRoot = dataRoot
    }

    /// The commit-message marker line the idempotency preflight greps for.
    /// runId is validated as a safe path component, and the git-log lookup
    /// uses --fixed-strings, so the marker is collision- and injection-safe.
    public static func commitMarker(runId: String) -> String {
        "evolution-run: \(runId)"
    }

    /// Promote an evolution candidate's diff onto the live repo.
    ///
    /// Fail-closed gates, in order:
    ///   1. availability — `.git` must exist (public-release no-repo stub);
    ///   2. runId path-component validation;
    ///   3. diff text sha must equal `expectedDiffSHA256`;
    ///   4. GREEN candidate evidence — result.json for runId must exist,
    ///      decode, carry ok == true, the SAME runId (a copied/stale result
    ///      for another run must not satisfy this run — gpt-5.5 fix-round),
    ///      the SAME diff sha, the SAME proposal, and a matching expectedHead;
    ///   5. idempotency preflight — a commit already carrying this runId's
    ///      marker returns `alreadyPromoted` instead of double-committing;
    ///   6. `applyDiffAndCommit` (clean tree, expectedHead CAS, 3-way apply,
    ///      validation callback re-reads result.json and revalidates runId +
    ///      proposalId + diff sha + expectedHead — design #2).
    ///
    /// `expectedHead` is NON-OPTIONAL on purpose (gpt-5.5 fix-round): a nil
    /// here used to skip the expected-head CAS entirely and commit onto
    /// whatever HEAD happened to be. Callers without a head fail closed
    /// upstream instead of reaching this seam.
    /// Never throws: every outcome is a typed `EvolutionPromoteOutcome`.
    public func promote(
        runId: String,
        proposalId: String,
        diffText: String,
        expectedHead: String,
        expectedDiffSHA256: String
    ) async -> EvolutionPromoteOutcome {
        // 1. Availability (mirror of SelfImprovementOrchestrator's gate).
        let gitDir = repoRoot.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else {
            return EvolutionPromoteOutcome(ok: false, error: "self_improvement_unavailable: no .git at \(repoRoot.path)")
        }
        // 2. runId hygiene.
        guard EvolutionSupport.isSafePathComponent(runId) else {
            return EvolutionPromoteOutcome(ok: false, error: "invalid_run_id: \(runId)")
        }
        // 3. Diff sha CAS.
        let actualSha = EvolutionSupport.sha256Hex(diffText)
        guard actualSha.lowercased() == expectedDiffSHA256.lowercased() else {
            return EvolutionPromoteOutcome(
                ok: false,
                error: "diff_sha_mismatch: expected \(expectedDiffSHA256), actual \(actualSha)")
        }
        // 4. Green candidate evidence (the load-bearing gate).
        switch loadGreenEvidence(
            runId: runId, proposalId: proposalId,
            expectedHead: expectedHead, expectedDiffSHA256: expectedDiffSHA256
        ) {
        case .failure(let reason):
            return EvolutionPromoteOutcome(ok: false, error: reason)
        case .success:
            break
        }
        // 5. Idempotency preflight: did a prior (crashed) run already land
        //    this promotion commit?
        do {
            if let existing = try await findPromotionCommit(runId: runId) {
                return EvolutionPromoteOutcome(ok: true, commitSha: existing, alreadyPromoted: true)
            }
        } catch {
            // Fail-closed: if we cannot read history we cannot prove the
            // commit is absent, and committing blind risks a duplicate.
            return EvolutionPromoteOutcome(ok: false, error: "history_preflight_failed: \(error)")
        }
        // 6. Apply + commit. The validation callback re-reads result.json
        //    from disk (design #2 — the green evidence IS the gate); a
        //    throw rolls the apply back (`git apply -R`) and the repo comes
        //    back clean.
        let git = SelfImprovementGitOps(repoRoot: repoRoot)
        let message = """
        feat(evolution): \(proposalId)

        \(Self.commitMarker(runId: runId))
        evolution-diff-sha256: \(expectedDiffSHA256)
        """
        let resultPath = EvolutionCandidateBuilder(repoRoot: repoRoot, dataRoot: dataRoot)
            .resultPath(runId: runId)
        let pinnedSha = expectedDiffSHA256
        let pinnedRun = runId
        let pinnedProposal = proposalId
        let pinnedHead = expectedHead
        do {
            let commit = try await git.applyDiffAndCommit(
                diffText: diffText,
                message: message,
                expectedHead: expectedHead,
                validateAppliedDiff: {
                    // Sync re-read on purpose (callback is sync): the file is
                    // immutable evidence written once by the claim winner.
                    // Full revalidation (gpt-5.5 fix-round): ok + runId +
                    // proposalId + diff sha + expectedHead — a stale/copied
                    // result for another run, proposal, or head must not
                    // satisfy the commit gate.
                    let data = try Data(contentsOf: resultPath)
                    let result = try JSONDecoder().decode(EvolutionCandidateResult.self, from: data)
                    guard result.ok,
                          result.runId == pinnedRun,
                          result.proposalId == pinnedProposal,
                          result.diffSHA256.lowercased() == pinnedSha.lowercased(),
                          EvolutionSupport.shaMatches(result.expectedHead, pinnedHead) else {
                        throw EvolutionEngineError.underlying(
                            "green_evidence_revoked: result.json no longer green for run \(pinnedRun), "
                            + "proposal \(pinnedProposal), sha \(pinnedSha), head \(pinnedHead)")
                    }
                }
            )
            return EvolutionPromoteOutcome(ok: true, commitSha: commit, alreadyPromoted: false)
        } catch let error as SelfImprovementGitError {
            return EvolutionPromoteOutcome(ok: false, error: "git: \(error.errorDescription ?? "\(error)")")
        } catch {
            return EvolutionPromoteOutcome(ok: false, error: "\(error)")
        }
    }

    // MARK: - Internals

    private enum EvidenceCheck {
        case success
        case failure(String)
    }

    private func loadGreenEvidence(
        runId: String,
        proposalId: String,
        expectedHead: String,
        expectedDiffSHA256: String
    ) -> EvidenceCheck {
        let path = EvolutionCandidateBuilder(repoRoot: repoRoot, dataRoot: dataRoot)
            .resultPath(runId: runId)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .failure("no_candidate_result: \(path.path)")
        }
        let result: EvolutionCandidateResult
        do {
            let data = try Data(contentsOf: path)
            result = try JSONDecoder().decode(EvolutionCandidateResult.self, from: data)
        } catch {
            return .failure("candidate_result_corrupt: \(error)")
        }
        guard result.ok else {
            return .failure("candidate_not_green: phase \(result.phase.rawValue), error \(result.error ?? "-")")
        }
        // runId is part of the evidence identity (gpt-5.5 fix-round): the
        // file lives at a runId-keyed path, but a copied/foreign result must
        // not pass on path placement alone.
        guard result.runId == runId else {
            return .failure("candidate_run_mismatch: result \(result.runId), expected \(runId)")
        }
        guard result.diffSHA256.lowercased() == expectedDiffSHA256.lowercased() else {
            return .failure("candidate_diff_sha_mismatch: result \(result.diffSHA256), expected \(expectedDiffSHA256)")
        }
        guard result.proposalId == proposalId else {
            return .failure("candidate_proposal_mismatch: result \(result.proposalId), expected \(proposalId)")
        }
        guard EvolutionSupport.shaMatches(result.expectedHead, expectedHead) else {
            return .failure("candidate_head_mismatch: result \(result.expectedHead), expected \(expectedHead)")
        }
        return .success
    }

    /// Look up an existing promotion commit by its runId marker.
    /// --fixed-strings: the marker is matched literally, never as a regex.
    private func findPromotionCommit(runId: String) async throws -> String? {
        let result = try await EvolutionSupport.run(
            ["git", "log", "--fixed-strings", "--grep", Self.commitMarker(runId: runId),
             "--format=%H", "-n", "1"],
            cwd: repoRoot,
            environment: EvolutionSupport.scrubbedEnvironment(),
            timeout: 30)
        guard result.exit == 0, !result.timedOut else {
            throw EvolutionEngineError.underlying(
                "git log failed: exit \(result.exit) timedOut \(result.timedOut) \(result.stderr)")
        }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize to the GitOps short-12 convention (applyDiffAndCommit
        // returns currentHead --short=12) so first-promote and idempotent
        // re-promote hand back byte-identical shas.
        return sha.isEmpty ? nil : String(sha.prefix(12))
    }
}
