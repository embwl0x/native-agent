import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `StudioCanonSeatGate.swift` | `StudioCanonSeatGate`: Bind canon authority to the live trusted turn. |

/// Canon authority comes from a trusted live turn, its identity and matching runtime surface, never tool input.
public enum StudioCanonSeatGate {
    public enum Refusal: String, Error, Sendable, Equatable {
        case notALiveTurn = "not_a_live_turn"
        case untrustedPeer = "untrusted_peer"
        case surfaceMismatch = "surface_mismatch"
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

    public static func liveTurnProvenance(turn: Turn,
        dispatchSurface: String
    ) -> Result<StudioCanonTurnProvenance, Refusal> {
        // A bound live turn excludes direct dispatch, approval executors and replays.
        guard let runtime = turn.runtime else { return .failure(.notALiveTurn) }
        let turnProfile = ConversationSurfaceProfile(runtime.surface)
        // Both surfaces must agree on the runtime origin.
        guard turnProfile == ConversationSurfaceProfile(dispatchSurface) else {
            return .failure(.surfaceMismatch)
        }
        guard PeerDataTaint.abilityWriteCheck(turn: turn) == nil else {
            return .failure(.untrustedPeer)
        }
        // Identity comes from this turn's execution or verified session, never input or a pinned run.
        let turnID = turn.run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turnID.isEmpty else { return .failure(.noTurnIdentity) }
        let provenance = StudioCanonTurnProvenance(surface: turnProfile.id, turnID: turnID)
        guard provenance.isComplete else { return .failure(.noTurnIdentity) }
        return .success(provenance)
    }

    /// Callers without a separate dispatch surface retain live-turn and peer-trust checks. Canon decisions also supply the dispatch surface to detect a
    /// mismatched caller.
    public static func liveTurnProvenance(turn: Turn) -> Result<StudioCanonTurnProvenance, Refusal> {
        guard let runtime = turn.runtime else { return .failure(.notALiveTurn) }
        return liveTurnProvenance(turn: turn, dispatchSurface: runtime.surface)
    }

    /// Production pulls use the projection's taste-judgment admission rule on the prepared need; browsing, tending and unprepared turns supply no evidence.
    public static func isProductionTasteJudgment(invocation: ChatToolInvocation) -> Bool {
        guard let need = invocation.preparedContext?.need else { return false }
        if ContextCorrectionScope.isTasteJudgmentTask(need.message) { return true }
        return need.recentTurns.suffix(2).contains {
            ContextCorrectionScope.isTasteJudgmentTask($0)
        }
    }
}
