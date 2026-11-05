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
// Blueprint: | `NativeCognitionRuntime+TurnPresentation.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    private static let bodyLineRefreshInterval: TimeInterval = 20 * 60

    /// Read only published owner projections on the live turn path; cold turns may receive nil but never wait for bootstrap or I/O.
    public nonisolated func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? {
        let trace = CognitiveAttentionTraceContext.recorder
        trace?.recordAdmission()
        guard !Task.isCancelled else {
            trace?.markCancellationObserved()
            return nil
        }
        return attentionProjection.read(at: date)
    }


    /// Use one fixed-time body refresh without consuming cadence until confirmed provider delivery.
    public func prepareTurnProjection(_ request: CognitiveCapsuleRequest, turn: Turn) async -> CognitionAtTurn {
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
            at: fixedAt,
            turn: turn
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
        request: CognitiveCapsuleRequest,
        turn: Turn
    ) async {
        guard request.resolvedTurnKind == .live else { return }
        // Clear owns the same door and must clear capsule/body-line mirrors too.
        await enterDoor()
        defer { leaveDoor() }
        if request.mode == .inject, let presentationCommit = projection.capsulePresentationCommit {
            guard await substrate.applyCapsulePresentationCommit(presentationCommit, turn: turn) else { return }
        }
        if let capsule = projection.capsule {
            // Only populated injections consume the body-line window; mirror live capsules independently.
            lastInjectedCapsule = (capsule, request.userMessage)
            if request.mode == .inject,
               let line = Self.bodyLine(inCapsuleDynamicContext: capsule.dynamicContext) {
                lastInjectedBodyLine = line
                lastInjectedBodyLineAt = projection.fixedAt
            }
        }
        guard request.mode == .inject else { return }
        // Empty delivered turns advance cadence with a token; populated injections flush even without one.
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
        // Render horizon before neutral-body early return because prediction-ledger anticipation is independent of chemistry.
        var request = request
        request.toward = toward
        guard !projection.isNeutral else { return request }
        // Suppress unchanged lines only for real injections; inspections must show state without consuming cadence.
        // Set the surfaced marker at confirmed delivery so previews or absent capsules cannot consume the window.
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
