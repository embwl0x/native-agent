import Foundation

/// Shared classification and backoff for continuing the current provider call.
public enum ProviderRecoveryPolicy {
    private struct StoppedOverload: ProviderFailureWrapping, LocalizedError {
        let providerFailureCause: Error
        var errorDescription: String? { ProviderFailure.overloaded.errorDescription }
    }

    static func retryOverload<T>(_ operation: () async throws -> T) async throws -> T {
        var attemptsMade = 0
        while true {
            attemptsMade += 1
            do { return try await operation() }
            catch {
                guard canRetryOverload(error) else { throw error }
                guard attemptsMade < 10 else { throw stopOverload(error) }
                try await Task.sleep(for: .seconds(backoffSeconds(forRetry: attemptsMade)))
            }
        }
    }

    private static func canRetryOverload(_ error: Error) -> Bool {
        !(error is StoppedOverload) && isRecoverable(error) && ProviderFailure.classify(error) == .overloaded
    }

    private static func stopOverload(_ error: Error) -> Error {
        ProviderFailure.classify(error) == .overloaded
            ? StoppedOverload(providerFailureCause: error) : error
    }

    /// 1, 2, 4, 8, 15, then 30 held flat to avoid hammering a provider outage.
    public static let maxBackoffSeconds: TimeInterval = 30

    public static func backoffSeconds(forRetry n: Int) -> TimeInterval {
        switch n {
        case ..<2: return 1
        case 2: return 2
        case 3: return 4
        case 4: return 8
        case 5: return 15
        default: return maxBackoffSeconds
        }
    }

    /// The delay before the next attempt, honoring the provider's own
    /// Retry-After when it asked for a longer wait than the ladder's.
    ///
    /// User, 2026-09-06: the ladders used `backoffSeconds` alone, so a 429 that
    /// said "wait 60s" was re-asked after 1s and burned the whole ladder into
    /// the same refusal. The adapters already carry the header through
    /// the typed failure; this reads it.
    public static func retryDelaySeconds(forRetry n: Int, error: Error) -> TimeInterval {
        max(backoffSeconds(forRetry: n), retryAfterSeconds(in: error) ?? 0)
    }

    /// The provider's own requested wait, when it sent one.
    public static func retryAfterSeconds(in error: Error) -> TimeInterval? {
        guard case .rateLimited(let delay) = ProviderFailure.classify(error) else { return nil }
        return delay.map(TimeInterval.init)
    }

    /// The next attempt shown while the current call reconnects.
    public static func reconnectStatus(attemptsMade: Int) -> String {
        "Reconnecting to the model, try \(attemptsMade + 1)…"
    }

    /// 2026-09-18 WHY: one typed verdict for every adapter and surface.
    /// Model fallback is deliberately absent: the person's selection is binding.
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
