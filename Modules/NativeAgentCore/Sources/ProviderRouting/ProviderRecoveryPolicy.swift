import Foundation
// Blueprint: | `ProviderRecoveryPolicy.swift` | `ProviderRecoveryPolicy`: typed failure classification and descriptions |

public enum ProviderRecoveryPolicy {
    enum Reconnect: Sendable {
        case network(retryAfter: Int?)
        case provider(retryAfter: Int?)

        var retryAfter: Int? {
            switch self {
            case .network(let seconds), .provider(let seconds): return seconds
            }
        }
    }

    /// Only connection loss and capacity refusals admit another request, paced by the server's Retry-After when it sends one.
    static func reconnect(_ error: Error) -> Reconnect? {
        func delay(_ error: Error) -> Int? {
            if let diagnostic = error as? ProviderFailure.Diagnostic { return diagnostic.retryAfter }
            if let wrapped = error as? any ProviderFailureWrapping { return delay(wrapped.providerFailureCause) }
            return nil
        }
        switch ProviderFailure.classify(error) {
        case .network?, .offline?: return .network(retryAfter: delay(error))
        case .overloaded?: return .provider(retryAfter: delay(error))
        case .rateLimited(let seconds)?:
            guard let seconds = seconds ?? delay(error) else { return nil }
            return .provider(retryAfter: seconds)
        default: return nil
        }
    }

    /// One typed recovery verdict serves every adapter and surface while preserving the selected model.
    public static func isRecoverable(_ error: Error) -> Bool {
        if let wrapped = error as? any ProviderFailureWrapping {
            return isRecoverable(wrapped.providerFailureCause)
        }
        switch ProviderFailure.classify(error) {
        case .network, .offline, .noReply, .overloaded, .rateLimited: return true
        default: return false
        }
    }

    public static func isContextOverflow(_ error: Error) -> Bool {
        ProviderFailure.classify(error) == .contextTooLong
    }

    public static func personMessage(_ error: Error) -> String? {
        if let stopped = error as? ProviderRecovery.Stopped { return stopped.errorDescription }
        if let repair = (error as? ProviderFailure.Diagnostic)?.repair { return repair.message }
        if let report = error as? ProviderFailure.Report { return report.personDescription }
        if let wrapped = error as? any ProviderFailureWrapping { return personMessage(wrapped.providerFailureCause) }
        if let error = error as? LLMError { return error.errorDescription }
        return ProviderFailure.classify(error)?.errorDescription
    }

    public static func isEmptyReply(_ error: Error?) -> Bool {
        guard let error else { return false }
        if let wrapped = error as? any ProviderFailureWrapping { return isEmptyReply(wrapped.providerFailureCause) }
        switch error as? LLMError {
        case .transient(let detail), .streamTruncated(let detail): return detail.contains("no answer text")
        default: return false
        }
    }

    public static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
