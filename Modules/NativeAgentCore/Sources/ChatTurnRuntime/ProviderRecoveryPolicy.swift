import Foundation
import ProviderRouting


extension TurnEngineError: ProviderFailureWrapping {
    public var providerWorkState: ProviderFailure.WorkState? {
        if case .streamInterrupted(let partial, _) = self, !partial.isEmpty { return .ranPartly }
        return nil
    }
    public var providerFailureCause: Error {
        if case .streamInterrupted(_, let underlying) = self { return underlying }
        return CancellationError()
    }
}
