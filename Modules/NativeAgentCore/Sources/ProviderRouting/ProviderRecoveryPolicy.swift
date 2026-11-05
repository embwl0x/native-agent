import Foundation
// Blueprint: | `ProviderRecoveryPolicy.swift` | `ProviderWire`: typed verdicts; wire-owned redelivery |

public enum ProviderRecoveryPolicy {
    /// One typed recovery verdict serves every adapter and surface while preserving the selected model.
    public static func isRecoverable(_ error: Error) -> Bool {
        if let wrapped = error as? any ProviderFailureWrapping {
            return isRecoverable(wrapped.providerFailureCause)
        }
        switch ProviderFailure.classify(error) {
        case .network, .noReply, .overloaded, .rateLimited: return true
        default: return false
        }
    }

    public static func isContextOverflow(_ error: Error) -> Bool {
        ProviderFailure.classify(error) == .contextTooLong
    }

    public static func personMessage(_ error: Error) -> String? {
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
