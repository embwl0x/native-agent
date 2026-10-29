import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Darwin
// Blueprint: | `ProcedureInvocation.swift` | ProcedureArtifactStore manual/exact invocation admission, execution/ledger/pointer locks, canonical execution, idempotent receipts and settlement |

extension ProcedureArtifactStore {
    @discardableResult
    public func invokeManual(
        artifactID: String,
        opaqueInputReference: String,
        context: ProcedureDryRunContext,
        executor: @escaping ProcedureCanonicalExecution
    ) async throws -> ProcedureInvocationReceipt {
        try await invoke(
            artifactID: artifactID,
            opaqueInputReference: opaqueInputReference,
            context: context,
            selection: .manual,
            executor: executor
        )
    }

    /// Admission for an exact typed operation after a separate immutable local
    /// activation. The active pointer and implementation identity are reread
    /// here, inside the procedure owner, immediately before canonical dispatch.
    @discardableResult
    public func invokeAutomaticExact(
        procedureID: String,
        implementationIdentity: String,
        expectedArtifactID: String,
        opaqueInputReference: String,
        context: ProcedureDryRunContext,
        executor: @escaping ProcedureCanonicalExecution
    ) async throws -> ProcedureInvocationReceipt {
        try await invoke(
            artifactID: expectedArtifactID,
            opaqueInputReference: opaqueInputReference,
            context: context,
            selection: .automaticRequest(procedureID: procedureID,
                                         implementationIdentity: implementationIdentity),
            executor: executor
        )
    }

    private enum InvocationSelection: Sendable {
        case manual
        case automaticRequest(procedureID: String, implementationIdentity: String)
        case automaticExact(ProcedureExactActivationManifest)

        var automatic: Bool {
            if case .automaticExact = self { return true }
            return false
        }

        var activationID: String? {
            if case .automaticExact(let manifest) = self { return manifest.id }
            return nil
        }

        var procedureID: String? {
            if case .automaticExact(let manifest) = self {
                return manifest.proposal.procedureID
            }
            return nil
        }

        var mode: String? { automatic ? "exact_typed" : nil }
    }

    /// Called with the reference lock held, after taking the invocation's
    /// lock. Keep the pointer lock only for admission, never for domain work.
    private func admitSelection(
        _ selection: InvocationSelection, artifactID: String
    ) async throws -> InvocationSelection {
        guard case .automaticRequest(let procedureID, let implementationIdentity) = selection else {
            return selection
        }
        return try await SwiftNativePersistenceCore.withFileLock(exactActivationPointerPath(procedureID)) { () -> InvocationSelection in
            let active = try await loadActiveExactProcedure(
                procedureID: procedureID, implementationIdentity: implementationIdentity
            )
            guard active.artifact.id == artifactID else {
                throw ProcedureExactActivationError.activationBindingMismatch
            }
            return .automaticExact(active.manifest)
        }
    }

    private func invoke(
        artifactID: String,
        opaqueInputReference: String,
        context: ProcedureDryRunContext,
        selection requestedSelection: InvocationSelection,
        executor: @escaping ProcedureCanonicalExecution
    ) async throws -> ProcedureInvocationReceipt {
        guard ProcedureTrajectoryExtractor.isOpaqueIdentity(opaqueInputReference) else {
            throw ProcedureArtifactStoreError.invalidInputReference
        }
        let artifact = try await loadForInvocation(artifactID)
        guard artifact.domain == "workshop_execution",
              artifact.authorityClass == "low_risk" else {
            throw ProcedureArtifactStoreError.invocationNotEligible
        }
        let dry = ProcedureReplayEngine.dryRun(artifact, context: context)
        let requestedAt = Self.iso8601(clock())
        // Stable across retries and store instances. A crash after dispatch but
        // before receipt persistence must replay the same domain idempotency key.
        let invocationID = CausalTransitionEvidence.opaqueIdentity(
            "\(artifactID)|\(opaqueInputReference)|\(context.nextRuleIndex)"
        )
        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        // Different inputs of the same artifact must not share a work lock.
        // The sidecar pins this artifact for retention while only identical
        // canonical invocations serialize, including across store instances.
        let invocationLockTarget = artifactPath(artifactID).appendingPathExtension(invocationID)
        return try await SwiftNativePersistenceCore.withFileLock(invocationLockTarget) {
            let admission = try await SwiftNativePersistenceCore.withFileLock(invocationPath) {
                // Re-read after exclusion is acquired: a sweep may have removed
                // the artifact while this invocation was waiting for the ledger.
                guard try await loadForInvocation(artifactID) == artifact else {
                    throw ProcedureArtifactStoreError.immutableConflict
                }
                let selection = try await admitSelection(requestedSelection, artifactID: artifactID)
                let existing = try await existingVerifiedReceipt(
                    invocationID: invocationID,
                    artifactID: artifact.id,
                    inputReference: opaqueInputReference,
                    expectedFallback: artifact.deterministicFallback
                )
                if existing != nil {
                    try FileManager.default.removeItem(
                        at: invocationLockTarget.appendingPathExtension("lock")
                    )
                }
                return (selection, existing)
            }
            let (selection, existing) = admission
            if let existing { return existing }
            var execution: ProcedureCanonicalExecutionResult?
            var dispatched = false
            var executionFailure: Error?
            var interruption: ProcedureInvocationInterruption?
            let accepted: Bool
            do {
                if (dry.status == .wouldAdvance || dry.status == .wouldComplete),
                   let rule = dry.proposedRule {
                    try Task.checkCancellation()
                    dispatched = true
                    execution = try await executor(
                        artifact, rule, opaqueInputReference, invocationID
                    )
                }
                if let execution {
                    guard execution.isValid else {
                        throw ProcedureArtifactStoreError.invalidExecutionResult
                    }
                    accepted = execution.verified
                } else {
                    accepted = false
                }
            } catch {
                executionFailure = error
                interruption = (error is CancellationError || Task.isCancelled)
                    ? .stopped
                    : (error as? ProcedureArtifactStoreError == .invalidExecutionResult
                        ? .invalidResult : .executorFailed)
                // Dispatch returned no usable verification. Preserve unknown
                // effects; a retry reobserves the same canonical execution.
                execution = dispatched ? ProcedureCanonicalExecutionResult(
                    status: .unverified, authorityRechecked: false,
                    canonicalEvidenceMatched: false, verified: false
                ) : nil
                accepted = false
            }
            let receipt = ProcedureInvocationReceipt(
                schema: ProcedureInvocationReceipt.schema,
                invocationID: invocationID,
                artifactID: artifact.id,
                opaqueInputReference: opaqueInputReference,
                requestedAt: requestedAt,
                dryRunStatus: dry.status,
                dryRunReason: dry.reason,
                executorStatus: execution?.status,
                authorityRechecked: execution?.authorityRechecked ?? false,
                canonicalEvidenceMatched: execution?.canonicalEvidenceMatched ?? false,
                verified: accepted,
                fallback: dry.fallback,
                dispatched: dispatched,
                payloadFree: true,
                permissionAuthority: false,
                automaticSelection: selection.automatic,
                activationID: selection.activationID,
                procedureID: selection.procedureID,
                selectionMode: selection.mode,
                interruption: interruption
            )
            // Enforce the newest-10_000 receipt cap on every append; a byte trigger cannot enforce this bound.
            let settlement: Result<Void, Error> = await settle {
                do {
                    try await SwiftNativePersistenceCore.withFileLock(invocationPath) {
                        try await appendJSONLCapped(
                            try JSONValue.parse(JSONEncoder().encode(receipt)),
                            to: invocationPath,
                            maxLines: 10_000,
                            logLabel: "ProcedureArtifactStore"
                        )
                        // No effects remain after publication. Retire this
                        // sidecar while its flock and the reference lock are
                        // held; withFileLock reopens any detached waiter inode.
                        try FileManager.default.removeItem(
                            at: invocationLockTarget.appendingPathExtension("lock")
                        )
                    }
                    return .success(())
                } catch { return .failure(error) }
            }
            try settlement.get()
            if let executionFailure { throw executionFailure }
            return receipt
        }
    }

    private func existingVerifiedReceipt(
        invocationID: String,
        artifactID: String,
        inputReference: String,
        expectedFallback: ProcedureFallbackRoute
    ) async throws -> ProcedureInvocationReceipt? {
        let receipts: [ProcedureInvocationReceipt]
        do { receipts = try await loadInvocationReceipts() }
        catch { throw ProcedureArtifactStoreError.corruptInvocationLedger }
        var existing: ProcedureInvocationReceipt?
        for receipt in receipts.reversed() {
            // Eligibility-only attempts are audit rows, not durable action
            // claims. They must not block a later exact retry after TrustCenter
            // or a canonical approval becomes available.
            if receipt.invocationID == invocationID, receipt.dispatched {
                guard receipt.artifactID == artifactID,
                      receipt.opaqueInputReference == inputReference,
                      receipt.fallback == expectedFallback else {
                    throw ProcedureArtifactStoreError.corruptInvocationLedger
                }
                if existing == nil { existing = receipt }
            }
        }
        // An unverified observation is evidence of this attempt, not a final
        // domain outcome. Keep the row and retry canonical verification using
        // the unchanged invocation ID. Only verified outcomes can be cached.
        guard let existing, existing.verified else { return nil }
        return existing
    }

    private static func iso8601(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}
