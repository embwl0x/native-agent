import Foundation
import ProviderRouting

// MARK: - In-loop provider recovery, ChatOrchestration half (2026-09-05)

extension ProviderErrorAfterToolEffects: ProviderFailureWrapping {
    public var providerFailureCause: Error { underlying }
    public var permitsWholeTurnRetry: Bool { false }
    public var providerWorkState: ProviderFailure.WorkState? { .ranPartly }
}

extension TurnEngineError: ProviderFailureWrapping {
    public var providerWorkState: ProviderFailure.WorkState? {
        if case .streamInterrupted(let partial, _) = self, !partial.isEmpty { return .ranPartly }
        return nil
    }
    public var providerFailureCause: Error {
        if case .streamInterrupted(_, let underlying) = self { return underlying }
        return CancellationError()
    }
    public var permitsWholeTurnRetry: Bool {
        // 2026-09-19 WHY: visible partial prose is already persisted by the surface.
        if case .streamInterrupted(let partial, _) = self { return partial.isEmpty }
        return false
    }
}

extension ProviderRecoveryPolicy {
    public static func isRecoverableTurnFailure(_ error: Error) -> Bool {
        isRecoverable(error)
    }
}
