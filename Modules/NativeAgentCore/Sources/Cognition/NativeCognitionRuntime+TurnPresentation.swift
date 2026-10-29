import Foundation
import ChatTurnRuntime
import CognitiveSubstrate
import NativeAgentCore
import ApprovalInbox
import ChatToolRuntime
import AgentConversations
import Context
import ContextFlow
import MemoryV2
import PersonaEngine
import PersistenceCore
import Desk
import Experiences
import AuthoredCapabilities
import NativeAgentShared
import Studio
import Transcripts
// Blueprint: | `NativeCognitionRuntime+TurnPresentation.swift` | `NativeCognitionRuntime` fixed-time turn preparation and committed capsule/body-line presentation |

extension NativeCognitionRuntime {
    private static let bodyLineRefreshInterval: TimeInterval = 20 * 60

    /// The live turn seam is an actor-free read of the projection already
    /// published by CognitiveSubstrate, OrganismKernel, and the Desk pursuit
    /// projection. Bootstrap and owner I/O happen off this path; an early cold
    /// turn may receive nil, but can never wait for those owners.
    public nonisolated func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? {
        let trace = CognitiveAttentionTraceContext.recorder
        trace?.recordAdmission()
        guard !Task.isCancelled else {
            trace?.markCancellationObserved()
            return nil
        }
        return attentionProjection.read(at: date)
    }


    /// Ordinary chat reads cognition and organism at one fixed time after one
    /// body refresh. It does not consume the surfaced-state window; the caller
    /// commits that only at confirmed provider delivery.
    public func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitionAtTurn {
        await bootstrap()
        let fixedAt = now()
        let bodySample = await organismBodySample(at: fixedAt)
        let canonicalAffect = await substrate.canonicalAffectProjection(at: fixedAt)
        let organism = await organismKernel.refreshBodySchemaAndFrozenRead(
            bodySample,
            integratesChemistry: false,
            canonicalAffect: canonicalAffect,
            fixedAt: fixedAt
        )
        let capsuleRequest = requestWithOrganismProjection(
            request,
            projection: organism.projection,
            toward: organism.toward,
            at: fixedAt
        )
        let preparedCapsule = await substrate.prepareFrozenCapsulePresentation(
            capsuleRequest,
            at: fixedAt
        )
        return CognitionAtTurn(
            fixedAt: fixedAt,
            capsule: preparedCapsule?.nonEmptyCapsule,
            posture: organism.posture,
            capsulePresentationCommit: preparedCapsule?.presentationCommit,
            why: preparedCapsule?.why
        )
    }

    public func commitTurnProjection(
        _ projection: CognitionAtTurn,
        request: CognitiveCapsuleRequest
    ) async {
        guard request.resolvedTurnKind == .live else { return }
        if let capsule = projection.capsule {
            // Mirror live capsules; only populated injections consume the body-line window.
            lastInjectedCapsule = (capsule, request.userMessage)
            if request.mode == .inject,
               let line = Self.bodyLine(inCapsuleDynamicContext: capsule.dynamicContext) {
                lastInjectedBodyLine = line
                lastInjectedBodyLineAt = projection.fixedAt
            }
        }
        guard request.mode == .inject else { return }
        if let presentationCommit = projection.capsulePresentationCommit {
            _ = await substrate.applyCapsulePresentationCommit(presentationCommit)
        }
        // Empty delivered turns advance cadence with a token; populated ones flush even without one.
        if projection.capsule != nil || projection.capsulePresentationCommit != nil {
            await substrate.flushCommittedCapsulePresentation(at: projection.fixedAt)
        }
    }

    func requestWithOrganismProjection(
        _ request: CognitiveCapsuleRequest,
        projection initialProjection: OrganismReadout,
        toward: OrganismTowardRead? = nil,
        at fixedAt: Date
    ) -> CognitiveCapsuleRequest {
        var projection = initialProjection
        // The horizon rides BEFORE the neutral-projection early return: it
        // comes from the prediction ledger, not from chemistry, so a body with
        // nothing to say is no reason for her to stop looking forward to
        // Friday.
        var request = request
        request.toward = toward
        guard !projection.isNeutral else { return request }
        // Suppress-when-unchanged: only for REAL injections (.inject). If the same
        // line is still fresh, drop it so a held mood goes quiet instead of
        // repeating for hours. Observatory/preview (.inspectOnly) always sees the
        // true line and never touches the window. The surfaced-marker is set
        // at delivery in commitTurnProjection, so a preview OR a nil capsule can't consume
        // the window.
        if request.mode == .inject,
           let line = projection.bodyLine,
           line == lastInjectedBodyLine,
           let last = lastInjectedBodyLineAt,
           fixedAt.timeIntervalSince(last) < Self.bodyLineRefreshInterval {
            projection.bodyLine = nil
        }
        var copy = request
        copy.organismProjection = projection
        return copy
    }

    public nonisolated static func bodyLine(inCapsuleDynamicContext dynamicContext: String) -> String? {
        dynamicContext
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("- Body:") }
    }
}
