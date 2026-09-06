import Foundation
import ProviderRouting

// MARK: - In-loop provider recovery, ChatOrchestration half (2026-09-05)

extension ProviderRecoveryPolicy {
    /// `isRecoverable`, plus the two wrapper errors THIS module owns and
    /// ProviderRouting therefore cannot name.
    ///
    /// Both wrappers are added on the way OUT of the tool loop — the retry
    /// sites classify a raw provider error — so this unwrap is the contract
    /// for anyone who catches a turn failure and asks the policy about it.
    /// `ProviderErrorAfterToolEffects` vetoes a WHOLE-TURN replay only; the
    /// failure inside it is exactly as recoverable in place as it ever was,
    /// so the wrapper is stripped rather than treated as a verdict.
    /// `.streamCancelled` is deliberately absent: a user stop never retries.
    public static func isRecoverableTurnFailure(_ error: Error) -> Bool {
        if let wrapped = error as? ProviderErrorAfterToolEffects {
            return isRecoverableTurnFailure(wrapped.underlying)
        }
        if let turnError = error as? TurnEngineError,
           case .streamInterrupted(_, let underlying) = turnError {
            return isRecoverableTurnFailure(underlying)
        }
        return isRecoverable(error)
    }
}
