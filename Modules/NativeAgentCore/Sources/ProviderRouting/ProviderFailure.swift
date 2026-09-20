import Foundation

/// 2026-09-18 WHY: adapters translate wire evidence once; recovery and surfaces
/// consume a failure, never adapter wording. Cancellation is not a failure.
public enum ProviderFailure: Error, Equatable, Sendable, LocalizedError, Codable {
    case authExpired
    case rateLimited(retryAfter: Int?)
    case overloaded
    case contextTooLong
    case network
    case refused
    case malformedResponse
    case routingUnavailable
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .authExpired: return "Your model connection needs attention; reconnect it in Settings."
        case .rateLimited: return "The usage limit was reached; wait a while or choose another model."
        case .overloaded: return "The model is busy; try again in a moment."
        case .contextTooLong: return "The conversation is too long; start a new chat or shorten your message."
        case .network: return "The connection was interrupted; check your internet connection and try again."
        case .refused: return "The model could not accept this request; revise your message or choose another model."
        case .malformedResponse: return "The model returned an unreadable response; try again."
        case .routingUnavailable: return "Your model settings could not be loaded; check your model connection in Settings."
        case .modelUnavailable: return "The selected model is unavailable; choose another model."
        }
    }

    /// Known HTTP statuses are authoritative; other refusals may describe quota or context limits.
    public static func http(status: Int, detail: String = "", retryAfter: Int? = nil) -> Self {
        switch status {
        case 401: return .authExpired
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 413: return .contextTooLong
        case 408: return .network
        case 409, 425, 500...599: return .overloaded
        case 200..<300, 0: return .malformedResponse
        default:
            if contextOverflow(detail) { return .contextTooLong }
            // 2026-09-19 WHY: some quota responses use 403 rather than 429.
            if quotaExceeded(detail) { return .rateLimited(retryAfter: retryAfter) }
            if modelUnavailable(detail) { return .modelUnavailable }
            if status == 403 { return .authExpired }
            return .refused
        }
    }

    // Wire protocols and the CLI sometimes expose only text. Keep that
    // compatibility translation here, outside every retry/tell decision.
    static func wireDetail(_ object: [String: Any]) -> String {
        ["type", "code", "message", "error"].compactMap { object[$0] as? String }.joined(separator: " ")
    }

    static func wireDetail(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(4096), encoding: .utf8) ?? ""
        }
        return wireDetail(object["error"] as? [String: Any] ?? object)
    }

    public static func wire(_ detail: String, fallback: Self = .refused) -> Self {
        let text = detail.lowercased()
        if contextOverflow(text) { return .contextTooLong }
        if let status = Self.httpStatusCode(inDescription: text), status >= 400 {
            return http(status: status, detail: text)
        }
        if ["invalid_api_key", "invalid authentication", "authentication_error", "unauthorized", "token expired", "expired token", "invalid token"].contains(where: text.contains) {
            return .authExpired
        }
        if quotaExceeded(text) {
            return .rateLimited(retryAfter: nil)
        }
        if modelUnavailable(text) { return .modelUnavailable }
        if ["overloaded", "unavailable", "server_error", "try again later"].contains(where: text.contains) {
            return .overloaded
        }
        if ["llm: transient", "connection refused", "cannot connect", "network connection was lost", "code=-1001", "timed out", "upstream connect", "disconnect/reset", "transport failure"].contains(where: text.contains) {
            return .network
        }
        return fallback
    }

    private static func quotaExceeded(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["rate limit", "rate_limit", "too many requests", "usage exhausted", "usage is exhausted", "out of extra usage", "quota exceeded", "insufficient_quota", "usage limit", "credit balance", "billing limit", "quota_exceeded"].contains(where: text.contains)
    }

    private static func modelUnavailable(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["model_not_found", "model_not_available", "model not found", "model not available", "model unavailable", "model is unavailable", "does not exist or you do not have access"].contains(where: text.contains)
    }

    private static func contextOverflow(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["prompt is too long", "context_length_exceeded", "context length", "exceeds the context window", "input is too long", "input too long", "too many total text bytes", "request_too_large", "exceeds the model's maximum", "max_tokens exceed"].contains(where: text.contains)
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

    public static func classify(_ error: Error) -> Self? {
        if error is CancellationError { return nil }
        if let failure = error as? Self { return failure }
        if error is ProviderRoutingError { return .routingUnavailable }
        if let wrapped = error as? any ProviderFailureWrapping { return classify(wrapped.providerFailureCause) }
        if let error = error as? LLMError {
            switch error {
            case .failure(let failure): return failure
            case .notConfigured: return .routingUnavailable
            case .authRejected(_, let detail): return wire(detail ?? "", fallback: .authExpired)
            case .modelUnavailable: return .modelUnavailable
            case .outputLengthLimit: return .refused
            case .invalidResponse(let status): return http(status: status)
            case .transient(let detail): return wire(detail, fallback: .network)
            case .streamTruncated: return .network
            case .providerError(let detail): return wire(detail)
            case .underlying(let detail): return wire(detail, fallback: .malformedResponse)
            }
        }
        if let error = error as? URLError { return error.code == .cancelled ? nil : .network }
        return nil
    }

    static func normalize(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if error is any ProviderFailureWrapping { return error }
        // Output truncation carries partial prose; routing/configuration failures
        // retain their repair identity rather than becoming a transport failure.
        if ProviderRecoveryPolicy.isEmptyReply(error) { return error }
        if let error = error as? LLMError {
            switch error {
            case .outputLengthLimit, .modelUnavailable, .notConfigured: return error
            default: break
            }
        }
        return LLMError.failure(classify(error) ?? .malformedResponse)
    }
}

/// Wrappers preserve typed recovery across module boundaries without replaying
/// tools that already ran (2026-07-18 WHY: a whole-turn retry repeats effects).
public protocol ProviderFailureWrapping: Error {
    var providerFailureCause: Error { get }
    var permitsWholeTurnRetry: Bool { get }
    var providerWorkState: ProviderFailure.WorkState? { get }
}

extension ProviderFailureWrapping {
    public var providerWorkState: ProviderFailure.WorkState? { nil }
}

extension ProviderFailure {
    public enum WorkState: String, Codable, Sendable {
        case nothingRan = "nothing ran"
        case ranPartly = "ran partly"
        case outcomeUnknown = "outcome unknown"
    }

    /// The same cause, with the turn's observed progress attached at its owner.
    public struct Report: Error, Codable, Equatable, Sendable, LocalizedError, ProviderFailureWrapping {
        public let cause: ProviderFailure
        public let work: WorkState
        public init(cause: ProviderFailure, work: WorkState) { self.cause = cause; self.work = work }
        public var providerFailureCause: Error { cause }
        public var permitsWholeTurnRetry: Bool { work == .nothingRan }
        public var providerWorkState: WorkState? { work }
        public var errorDescription: String? {
            (cause.errorDescription ?? "The reply could not be completed.") + " Work: " + work.rawValue + "."
        }
    }

    public static func report(_ error: Error, work: WorkState? = nil) -> Report? {
        guard let cause = classify(error) else { return nil }
        func observed(_ error: Error) -> WorkState? {
            guard let wrapper = error as? any ProviderFailureWrapping else { return nil }
            return wrapper.providerWorkState ?? observed(wrapper.providerFailureCause)
        }
        return Report(cause: cause, work: work ?? observed(error) ?? (cause == .network ? .outcomeUnknown : .nothingRan))
    }
}
