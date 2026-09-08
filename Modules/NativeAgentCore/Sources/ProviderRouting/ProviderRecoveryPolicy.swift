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
/// because TelegramBot's `isRetryableChatHandlerError` shares the phrase list
/// and TelegramBot depends on ProviderRouting but deliberately NOT on
/// ChatOrchestration (adding that edge would drag the whole tool stack into
/// the bot module — the same posture DelegationOutcomeLoop documents). The two
/// wrapper errors ChatOrchestration owns are unwrapped by the extension in
/// `ChatOrchestration/ProviderRecoveryPolicy.swift`.
public enum ProviderRecoveryPolicy {
    /// 1 original attempt + 9 retries for a single provider call. The shape is
    /// Claude Code's reconnect ladder on purpose (the user: it says
    /// "reconnecting, try n of 10" and keeps going): a provider blip should
    /// cost a wait, never the turn. A rate limit (429) and an overload (5xx)
    /// ride this same ladder — `isRecoverable` gives them no separate lane,
    /// because from the turn's side they are the same instruction, "ask again".
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
    /// `LLMError.rateLimited`'s ` [retry-after=Ns]` sentinel; this reads it.
    public static func retryDelaySeconds(forRetry n: Int, error: Error) -> TimeInterval {
        max(backoffSeconds(forRetry: n), retryAfterSeconds(in: error) ?? 0)
    }

    /// The provider's own requested wait, when it sent one.
    public static func retryAfterSeconds(in error: Error) -> TimeInterval? {
        LLMError.retryAfterSeconds(fromDescription: describe(error)).map(TimeInterval.init)
    }

    /// The line a surface shows when the provider asked for a wait longer than
    /// the turn has left, so the ladder stops instead of sleeping past the
    /// budget and reporting a bare exhaustion.
    public static func retryAfterBeyondBudgetStatus(
        delaySeconds: TimeInterval,
        remainingSeconds: TimeInterval
    ) -> String {
        "The provider asked to wait \(Int(delaySeconds.rounded()))s before retrying — "
            + "longer than the \(Int(remainingSeconds.rounded()))s this turn has left. Stopping here."
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

    /// True when retrying the identical provider call could plausibly succeed.
    ///
    /// NEVER recoverable: cancellation (a user stop is not a failure), and the
    /// three LLMError cases that describe a standing configuration fault — a
    /// rejected key, a missing provider, a model the provider no longer offers.
    /// Retrying those burns the surface's patience for a guaranteed identical
    /// answer.
    public static func isRecoverable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // A context overflow is deterministic: the SAME body gets the SAME 400
        // however many times we ask. It has its own recovery (trim the
        // conversation, then re-issue), so it must never enter the ladder —
        // checked first because a provider's overflow body sometimes carries a
        // word the phrase list would otherwise call retryable.
        if isContextOverflow(error) { return false }

        if let llmError = error as? LLMError {
            switch llmError {
            case .notConfigured, .modelUnavailable, .authRejected, .outputLengthLimit:
                return false
            case .transient, .streamTruncated:
                return true
            case .providerError(let message):
                // Adapters also use this case for deterministic refusals (an
                // xAI 403, a content refusal, a malformed success body), so
                // only the provider's own overload / rate-limit / 5xx words
                // earn a retry — or, since 2026-09-06, a status code read out
                // of the message whatever shape the adapter wrote it in. The
                // OAuth-direct adapter emits "chatgpt-backend HTTP 503: …",
                // which the phrase list ("status 503") did not match, and 408 /
                // 409 / 425 were only ever classified for `.invalidResponse`.
                if matchesRetryablePhrase(message) { return true }
                if let code = httpStatusCode(inDescription: message) {
                    return isRecoverableStatus(code)
                }
                return false
            case .invalidResponse(let status):
                return isRecoverableStatus(status)
            case .underlying:
                break   // no typed signal; fall through to the phrase ladder
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed,
                 .secureConnectionFailed:
                return true
            default:
                break   // fall through to the phrase ladder
            }
        }

        let description = describe(error)
        if matchesRetryablePhrase(description) { return true }
        if let code = httpStatusCode(inDescription: description) {
            return isRecoverableStatus(code)
        }
        return false
    }

    /// The HTTP status an error message names, in whichever shape the adapter
    /// wrote it: "HTTP 413", "status code 413", "status: 413" in the adapter's
    /// own prefix, or a bare "413 Request Entity Too Large".
    ///
    /// User, 2026-09-06: classification used to depend on adapter wording —
    /// `isContextOverflow` matched "status 413" but not "HTTP 413", and the
    /// 408/409/425/5xx codes were only read off `.invalidResponse`'s typed
    /// payload. Reading the code makes the verdict the same whatever the
    /// wording and whatever the error case.
    ///
    /// User, 2026-09-06 (second pass): the first version read a code out of the
    /// provider's own BODY. `{"error":{"status":503}}` quoted inside a
    /// deterministic 400, and prose like "500 error records", both classified
    /// as retryable 5xx and rode the ladder ten times for the same refusal. A
    /// number now counts only where it can only mean an HTTP status:
    ///   1. after explicit HTTP context — "HTTP 503", "HTTP/1.1 503";
    ///   2. after explicit status-code context — "status code 503";
    ///   3. as "status 503" / "status: 503" in the adapter's own prefix (the
    ///      text before any body it quoted), and never immediately after a
    ///      quote, which is the JSON-field shape;
    ///   4. followed by that code's own reason phrase — "413 Request Entity
    ///      Too Large", "503 Service Unavailable".
    /// The old loose "number then one of a dozen common words" pattern is gone.
    static func httpStatusCode(inDescription description: String) -> Int? {
        let haystack = description.lowercased()
        // The adapter prefix: everything before the body it quoted. Adapters
        // write "<context> status <code>: <body>", so the status they mean is
        // always ahead of the first brace.
        let prefix = String(haystack[haystack.startIndex..<(haystack.firstIndex(of: "{") ?? haystack.endIndex)])
        let reasons = "request timeout|conflict|gone|payload too large|"
            + "request entity too large|content too large|unprocessable entity|"
            + "precondition failed|too early|too many requests|"
            + "internal server error|not implemented|bad gateway|"
            + "service unavailable|gateway timeout"
        let patterns: [(pattern: String, subject: String)] = [
            (#"http[/ ][0-9.]*\s*([1-5][0-9]{2})(?![0-9])"#, haystack),
            (#"status[ _-]?code[^0-9a-z]{0,3}([1-5][0-9]{2})(?![0-9])"#, haystack),
            (#"(?<!["'])\bstatus[ :][ :]?\s*([1-5][0-9]{2})(?![0-9])"#, prefix),
            (#"\b([1-5][0-9]{2})\s+(?:\#(reasons))\b"#, haystack),
        ]
        for (pattern, subject) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(subject.startIndex..<subject.endIndex, in: subject)
            guard let match = regex.firstMatch(in: subject, range: full),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: subject),
                  let code = Int(subject[range])
            else { continue }
            return code
        }
        return nil
    }

    /// 408 request timeout, 409 conflict, 425 too-early, 429 rate limit, and
    /// every 5xx: all of them describe "ask again", not "you asked wrong".
    static func isRecoverableStatus(_ status: Int) -> Bool {
        switch status {
        case 408, 409, 425, 429:
            return true
        default:
            return (500...599).contains(status)
        }
    }

    /// Last resort when nothing typed matched: the provider's own words.
    /// This is the list Telegram's chat-handler retry ladder has always used —
    /// it now has exactly one owner instead of one copy per retry site.
    public static func matchesRetryablePhrase(_ description: String) -> Bool {
        let haystack = description.lowercased()
        return retryablePhrases.contains { haystack.contains($0) }
    }

    /// The full text a retry ladder matches against: the localized description
    /// when there is one, plus the raw value (an enum case's payload often only
    /// shows up in the latter).
    public static func describe(_ error: Error) -> String {
        [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    /// True when the provider refused because the request does not FIT — the
    /// assembled conversation is larger than the model's context window (or the
    /// endpoint's request-size ceiling).
    ///
    /// This is NOT recoverable in the ladder's sense: retrying the identical
    /// call cannot help, and `isRecoverable` returns false for it above. It is
    /// its own recovery — the caller trims the in-flight conversation and
    /// re-issues a SMALLER body (see `IntraTurnContextCompaction`).
    ///
    /// Anthropic delivers this as a 400 whose body says "prompt is too long",
    /// and as a 413 `request_too_large`; OpenAI as `context_length_exceeded`.
    /// Neither is typed on the wire in a way the adapters preserve, so the
    /// provider's own words are the signal.
    public static func isContextOverflow(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case .outputLengthLimit = error as? LLMError { return false }
        if let llmError = error as? LLMError,
           case .invalidResponse(let status) = llmError,
           status == 413 {
            return true
        }
        let description = describe(error)
        // Any wording that names a 413 — "HTTP 413", "status 413",
        // "413 Request Entity Too Large" (2026-09-06).
        if httpStatusCode(inDescription: description) == 413 { return true }
        let haystack = description.lowercased()
        return contextOverflowPhrases.contains { haystack.contains($0) }
    }

    /// The provider phrases that mean "this does not fit". Kept beside the
    /// retryable list on purpose: they are read from the same error text and
    /// the two sets must never overlap.
    private static let contextOverflowPhrases = [
        "prompt is too long",
        "context_length_exceeded",
        "context length",
        "exceeds the context window",
        "maximum context length",
        "input is too long",
        "input too long",
        "too many total text bytes",
        "request_too_large",
        "exceeds the model's maximum",
        "max_tokens exceed"
    ]

    private static let retryablePhrases = [
        "llm: transient",
        "connection refused",
        "cannot connect",
        "network connection was lost",
        "code=-1001",
        "timed out",
        "upstream connect",
        "disconnect/reset",
        "transport failure",
        "server status 5",
        "status 502",
        "status 503",
        "status 504",
        "status 529",
        "rate limited",
        "rate limit",
        "rate_limit",
        "too many requests",
        "overloaded",
        "overloaded_error",
        "invalid response status 429",
        "invalid response status 529",
        "unavailable"
    ]
}
