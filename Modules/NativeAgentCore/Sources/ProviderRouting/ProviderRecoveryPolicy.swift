import Foundation

// MARK: - In-loop provider recovery (2026-09-05)

/// Which provider failures a turn may retry IN PLACE — same call, same
/// conversation, nothing re-executed.
///
/// This is NOT the whole-turn retry ladder. A surface replay re-runs the tool
/// dispatches (messages re-send, files re-write), which is why
/// `ProviderErrorAfterToolEffects` vetoes it. Retrying the provider call from
/// inside the tool loop has none of that hazard: the tool results are already
/// appended to `conversation`, so the retry is a second attempt at the SAME
/// request body. A recoverable drop must therefore keep the turn alive rather
/// than kill it, which is the whole point of this type.
///
/// MODULE PLACEMENT: this lives in ProviderRouting, not ChatOrchestration,
/// because TelegramBot's `isRetryableChatHandlerError` shares the typed policy
/// and TelegramBot depends on ProviderRouting but deliberately NOT on
/// ChatOrchestration (adding that edge would drag the whole tool stack into
/// the bot module — the same posture DelegationOutcomeLoop documents). The two
/// wrapper errors ChatOrchestration owns are unwrapped by the extension in
/// `ChatOrchestration/ProviderRecoveryPolicy.swift`.
public enum ProviderRecoveryPolicy {
    // Every caller gets the existing overload ladder, before output only.
    // Preserve exhaustion across outer chat/whole-turn ladders so they cannot
    // restart this allowance or replay output already delivered to a person.
    private struct FinishedOverload: ProviderFailureWrapping, LocalizedError {
        let providerFailureCause: Error
        var permitsWholeTurnRetry: Bool { false }
        var errorDescription: String? { ProviderFailure.overloaded.errorDescription }
    }

    static func retryOverload<T>(_ operation: () async throws -> T) async throws -> T {
        var attemptsMade = 0
        while true {
            attemptsMade += 1
            do { return try await operation() }
            catch {
                guard canRetryOverload(error) else { throw error }
                guard attemptsMade < maxAttemptsPerCall else { throw finishOverload(error) }
                try await Task.sleep(for: .seconds(backoffSeconds(forRetry: attemptsMade)))
            }
        }
    }

    static func retryOverloadStream<Event: Sendable>(
        hasOutput: @escaping @Sendable (Event) -> Bool,
        operation: @escaping @Sendable () -> AsyncThrowingStream<Event, Error>
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var emittedOutput = false
                do {
                    try await retryOverload {
                        do {
                            for try await event in operation() {
                                try Task.checkCancellation()
                                emittedOutput = emittedOutput || hasOutput(event)
                                continuation.yield(event)
                            }
                            try Task.checkCancellation()
                        } catch {
                            throw emittedOutput ? finishOverload(error) : error
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func canRetryOverload(_ error: Error) -> Bool {
        isRecoverable(error) && ProviderFailure.classify(error) == .overloaded
    }

    private static func finishOverload(_ error: Error) -> Error {
        ProviderFailure.classify(error) == .overloaded
            ? FinishedOverload(providerFailureCause: error) : error
    }

    /// 1 original attempt + 9 retries for a single provider call. The shape is
    /// Claude Code's reconnect ladder on purpose (the user: it says
    /// "reconnecting, try n of 10" and keeps going): a provider blip should
    /// cost a wait, never the turn. Network failures and rate limits ride
    /// this ladder; the shared client exhausts overloads with the same
    /// pre-output ladder above before they reach an outer turn ladder.
    public static let maxAttemptsPerCall = 10

    /// Ceiling on recoveries across the WHOLE turn, so a provider that drops
    /// every round cannot ride the per-call budget forever. Two full ladders'
    /// worth: a turn that needs more than this is not blipping, it is down.
    public static let maxRecoveriesPerTurn = 20

    /// 1, 2, 4, 8, 15, then 30 held flat — 2m30s of patience across the nine
    /// retries. It doubles early so a one-packet blip costs a second, and caps
    /// at 30 so a long provider outage neither hammers the endpoint nor leaves
    /// the surface staring at a dead status line for minutes at a time.
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

    /// The line a surface shows when the provider asked for a wait longer than
    /// the turn has left, so the ladder stops instead of sleeping past the
    /// budget and reporting a bare exhaustion.
    public static func retryAfterBeyondBudgetStatus(
        delaySeconds: TimeInterval,
        remainingSeconds: TimeInterval
    ) -> String {
        "The model needs more time than this turn has left; try again in \(Int(delaySeconds.rounded())) seconds."
    }

    /// Only a provider-requested wait warrants a notice. Ordinary backoff
    /// exhausting the budget ends the turn without attributing it to the provider.
    public static func retryAfterBeyondBudgetNotice(
        for error: Error,
        remainingSeconds: TimeInterval
    ) -> String? {
        guard let retryAfter = retryAfterSeconds(in: error),
              retryAfter >= remainingSeconds else { return nil }
        return retryAfterBeyondBudgetStatus(
            delaySeconds: retryAfter,
            remainingSeconds: remainingSeconds
        )
    }

    /// Reserve held back from the per-call provider wall so a hung call always
    /// leaves the reconnect ladder somewhere to stand: one full backoff plus a
    /// short second call.
    public static let reconnectReserveSeconds: TimeInterval = 60

    /// Floor for the per-call wall. Below this a "timeout" says nothing about
    /// the provider, only about the budget.
    public static let minimumCallWallSeconds: TimeInterval = 60

    /// The per-call provider wall, bounded by what the whole turn has left.
    ///
    /// User, 2026-09-06: interactive and Telegram turn windows are 600s and the
    /// default provider wall was also 600s, so the FIRST timeout consumed the
    /// entire turn — the ladder announced "try 2", slept, and then exited on
    /// the whole-turn budget without ever re-asking. Shaving the reserve off
    /// the wall means a hung call always leaves room for one more attempt.
    /// `remaining` nil (a caller with no turn budget) leaves the wall alone.
    ///
    /// User, 2026-09-06: `remaining == 0` is NOT "no budget" — it is a turn
    /// whose budget is spent, reachable when the sample happens after an
    /// in-turn compaction. Treating it like nil handed that call the FULL
    /// configured wall, the largest wall in the whole policy, to an exhausted
    /// turn. Zero (or negative) now falls through to the floor like any other
    /// too-small remainder.
    public static func callWallSeconds(
        configured: TimeInterval,
        remainingTurnSeconds remaining: TimeInterval?
    ) -> TimeInterval {
        guard configured > 0, let remaining else { return configured }
        let bounded = remaining - reconnectReserveSeconds
        if bounded <= minimumCallWallSeconds {
            return min(configured, minimumCallWallSeconds)
        }
        return min(configured, bounded)
    }

    /// The one line a surface shows while a reconnect is in flight.
    ///
    /// `attemptsMade` is how many attempts the call has already burned, so the
    /// number shown is the attempt ABOUT TO BE MADE — the first reconnect reads
    /// "try 2 of 10" (try 1 is the one that just dropped) and the last reads
    /// "try 10 of 10". Counting the retries instead would top out at 9 of 10
    /// and read as giving up early.
    public static func reconnectStatus(attemptsMade: Int) -> String {
        "Reconnecting to the model, try \(attemptsMade + 1) of \(maxAttemptsPerCall)…"
    }

    /// 2026-09-18 WHY: one typed verdict for every adapter and surface.
    /// Model fallback is deliberately absent: the person's selection is binding.
    public static func isRecoverable(_ error: Error) -> Bool {
        if error is FinishedOverload { return false }
        if let wrapped = error as? any ProviderFailureWrapping {
            return isRecoverable(wrapped.providerFailureCause)
        }
        switch ProviderFailure.classify(error) {
        case .network, .overloaded, .rateLimited: return true
        default: return false
        }
    }

    public static func isContextOverflow(_ error: Error) -> Bool {
        ProviderFailure.classify(error) == .contextTooLong
    }

    public static func permitsWholeTurnRetry(_ error: Error) -> Bool {
        if let wrapped = error as? any ProviderFailureWrapping {
            return wrapped.permitsWholeTurnRetry && permitsWholeTurnRetry(wrapped.providerFailureCause)
        }
        return isRecoverable(error)
    }

    public static func personMessage(_ error: Error) -> String? {
        if let report = error as? ProviderFailure.Report { return report.errorDescription }
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
