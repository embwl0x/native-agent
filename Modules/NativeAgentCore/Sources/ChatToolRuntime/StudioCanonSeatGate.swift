import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `StudioCanonSeatGate.swift` | `StudioCanonSeatGate`: trusted live-turn identity and matching runtime surface for canon authority; production pulls share the live-turn gate and projection's taste-judgment admission |

/// Canon authority comes from a trusted live turn, its identity and matching runtime surface, never tool input.
public enum StudioCanonSeatGate {
    public enum Refusal: String, Error, Sendable, Equatable {
        /// No chat turn is running: a direct dispatch, an executor, a replay.
        case notALiveTurn = "not_a_live_turn"
        /// A peer the owner has not trusted is steering this turn.
        case untrustedPeer = "untrusted_peer"
        /// The dispatch surface and the live turn's surface disagree.
        case surfaceMismatch = "surface_mismatch"
        /// The turn has no identity to record on the row.
        case noTurnIdentity = "no_turn_identity"

        public var spoken: String {
            switch self {
            case .notALiveTurn:
                return "this did not come from a live chat turn — a bridge tool run, an "
                    + "approval replay, or a background pass cannot decide the canon"
            case .untrustedPeer:
                return "the owner must trust this peer before it can steer a canon decision"
            case .surfaceMismatch:
                return "the dispatch surface and the running turn disagree about where "
                    + "this call came from"
            case .noTurnIdentity:
                return "this turn carries no identity to record on the row"
            }
        }
    }

    public static func liveTurnProvenance(
        dispatchSurface: String
    ) -> Result<StudioCanonTurnProvenance, Refusal> {
        // A bound live turn excludes direct dispatch, approval executors and replays.
        guard let turn = ChatTurnRuntimeContext.current else { return .failure(.notALiveTurn) }
        let turnProfile = ConversationSurfaceProfile(turn.surface)
        // Both surfaces must agree on the runtime origin.
        guard turnProfile == ConversationSurfaceProfile(dispatchSurface) else {
            return .failure(.surfaceMismatch)
        }
        guard PeerDataTaint.abilityWriteCheck() == nil else {
            return .failure(.untrustedPeer)
        }
        // Identity comes from this turn's execution or verified session, never input or a pinned run.
        let turnID = [
            ChatTurnExecution.current?.historyRunID,
            ChatToolSessionContext.verifiedSessionId,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let turnID else { return .failure(.noTurnIdentity) }
        let provenance = StudioCanonTurnProvenance(surface: turnProfile.id, turnID: turnID)
        guard provenance.isComplete else { return .failure(.noTurnIdentity) }
        return .success(provenance)
    }

    /// Callers without a separate dispatch surface retain live-turn and peer-trust checks.
    /// Canon decisions also supply the dispatch surface to detect a mismatched caller.
    public static func liveTurnProvenance() -> Result<StudioCanonTurnProvenance, Refusal> {
        guard let turn = ChatTurnRuntimeContext.current else { return .failure(.notALiveTurn) }
        return liveTurnProvenance(dispatchSurface: turn.surface)
    }

    /// Production pulls use the projection's taste-judgment admission rule on the
    /// prepared need; browsing, tending and unprepared turns supply no evidence.
    public static func isProductionTasteJudgment() -> Bool {
        guard let need = FluidContextToolScope.current?.need else { return false }
        if ContextCorrectionScope.isTasteJudgmentTask(need.message) { return true }
        return need.recentTurns.suffix(2).contains {
            ContextCorrectionScope.isTasteJudgmentTask($0)
        }
    }
}
