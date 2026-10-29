import Experiences
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ProviderFailure.swift` | Typed provider failure classification and `Diagnostic` wrapper preserving redacted wire evidence and the owner's `ToolFailureError` repair through normalization; `repair` decides once whether a failed call owes repair (sign-in, account, model choice) or is a correction that owes nothing |

/// Adapters translate wire evidence once for recovery and surfaces; cancellation is not a failure.
public enum ProviderFailure: Error, Equatable, Sendable, LocalizedError, Codable {
    case authExpired
    case codexCLISessionExpired
    case rateLimited(retryAfter: Int?)
    case overloaded
    case contextTooLong
    case network
    /// The stream guard cut a request after `seconds` of waiting. `events`
    /// counts wire activity; `account` is the guard's sentence for which cut
    /// it was and on what evidence (absent from older peers). Admission rides
    /// on the `Diagnostic`.
    case noReply(provider: String, seconds: Int, events: Int, account: String? = nil)
    case outputLimit
    case refused
    case requestRejected
    case malformedResponse
    case routingUnavailable
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .authExpired: return "Your model connection needs attention; reconnect it in Settings."
        case .codexCLISessionExpired: return "Your Codex CLI sign-in needs updating. Run codex once, or sign in in NativeAgent."
        case .rateLimited(let seconds?): return "The usage limit was reached; wait \(seconds) seconds before another request."
        case .rateLimited(nil): return "The usage limit was reached; the provider gave no wait time. Check the account's usage allowance."
        case .overloaded: return "The model is busy; try again in a moment."
        case .contextTooLong: return "The conversation is too long; start a new chat or shorten your message."
        case .network: return "The connection was interrupted; check your internet connection and try again."
        case .noReply(let provider, let seconds, let events, let account):
            return account ?? "No reply from \(provider) in \(seconds) s (\(events) events)."
        case .outputLimit: return "The model reached its output limit. Keep any partial output and request only the missing portion."
        case .refused: return "The model refused this request. Read the refusal and stop if it is disallowed."
        case .requestRejected: return "The provider rejected this request. Correct the reported request error."
        case .malformedResponse: return "The model returned an unreadable response; try again."
        case .routingUnavailable: return "Your model settings could not be loaded; check your model connection in Settings."
        case .modelUnavailable: return "The selected model is unavailable; choose another model."
        }
    }

    /// Known HTTP statuses are authoritative; other refusals may describe quota or context limits.
    public static func http(status: Int, detail: String = "", retryAfter: Int? = nil) -> Self {
        switch status {
        case 401: return .authExpired
        case 429: return .rateLimited(retryAfter: retryAfter == nil && quotaExceeded(detail) && !rateLimitWording(detail) ? quotaRetryAfter : retryAfter)
        case 413: return .contextTooLong
        case 408: return .network
        case 409, 425, 500...599: return .overloaded
        case 200..<300, 0: return .malformedResponse
        default:
            if contextOverflow(detail) { return .contextTooLong }
            // Quota responses can use 403 as well as 429.
            if rateLimitWording(detail) { return .rateLimited(retryAfter: retryAfter) }
            if quotaExceeded(detail) { return .rateLimited(retryAfter: retryAfter ?? quotaRetryAfter) }
            if modelUnavailable(detail) { return .modelUnavailable }
            if modelRefusal(detail) { return .refused }
            if status == 403 { return .authExpired }
            return .requestRejected
        }
    }

    // Wire protocols and the CLI sometimes expose only text. Keep that
    // compatibility translation here, outside every retry/tell decision.
    static func wireDetail(_ object: [String: Any]) -> String {
        ["type", "code", "error_code", "message", "error"].compactMap { object[$0] as? String }.joined(separator: " ")
    }

    static func wireDetail(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(4096), encoding: .utf8) ?? ""
        }
        return wireDetail(object["error"] as? [String: Any] ?? object)
    }

    public static func wire(_ detail: String, fallback: Self = .requestRejected) -> Self {
        let text = detail.lowercased()
        if contextOverflow(text) { return .contextTooLong }
        if let status = Self.httpStatusCode(inDescription: text), status >= 400 {
            return http(status: status, detail: text)
        }
        if ["invalid_api_key", "invalid authentication", "authentication_error", "unauthorized", "token expired", "expired token", "invalid token"].contains(where: text.contains) {
            return .authExpired
        }
        if rateLimitWording(text) { return .rateLimited(retryAfter: nil) }
        if quotaExceeded(text) { return .rateLimited(retryAfter: quotaRetryAfter) }
        if modelUnavailable(text) { return .modelUnavailable }
        if ["overloaded", "unavailable", "server_error", "try again later"].contains(where: text.contains) {
            return .overloaded
        }
        if ["llm: transient", "connection refused", "cannot connect", "network connection was lost", "code=-1001", "timed out", "upstream connect", "disconnect/reset", "transport failure"].contains(where: text.contains) {
            return .network
        }
        if text.contains("stop_reason=max_tokens") { return .outputLimit }
        if modelRefusal(text) { return .refused }
        return fallback
    }

    private static func modelRefusal(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return text == "refusal" || text.hasPrefix("refusal ")
            || ["stop_reason=refusal", "content_filter", "content_policy_violation"].contains(where: text.contains)
    }

    // A quota response without Retry-After asks for an hour before retrying.
    private static let quotaRetryAfter = 3600

    private static func quotaExceeded(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["usage exhausted", "usage is exhausted", "out of extra usage", "quota exceeded", "insufficient_quota", "usage limit", "credit balance", "billing limit", "quota_exceeded", "spending limit"].contains(where: text.contains)
    }

    private static func rateLimitWording(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["rate limit", "rate_limit", "too many requests"].contains(where: text.contains)
    }

    private static func modelUnavailable(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["model_not_found", "model_not_available", "model not found", "model not available", "model unavailable", "model is unavailable", "does not exist or you do not have access", "claude_code_version_too_old", "does not support this model", "or newer is required"].contains(where: text.contains)
    }

    private static func contextOverflow(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return ["prompt is too long", "context_length_exceeded", "context length", "exceeds the context window", "input is too long", "input too long", "too many total text bytes", "request_too_large", "exceeds the model's maximum", "max_tokens exceed"].contains(where: text.contains)
    }

    /// Status numbers require HTTP/status-code context, unquoted adapter-prefix status, or a matching reason phrase.
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
            case .outputLengthLimit: return .outputLimit
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

    /// `admitted`: the provider had begun a response for this request.
    static func normalize(_ error: Error, admitted: Bool = false) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if admitted, let diagnostic = error as? Diagnostic {
            return Diagnostic(cause: diagnostic.cause, detail: diagnostic.detail,
                              deadlineExpired: diagnostic.deadlineExpired, admitted: true,
                              repair: diagnostic.repair, tries: diagnostic.tries)
        }
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
        let nsError = error as NSError
        return Diagnostic(cause: classify(error) ?? .malformedResponse,
                          detail: diagnosticDescription(error),
                          deadlineExpired: nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut,
                          admitted: admitted)
    }

    /// Retain transport evidence while people and retry policy still consume
    /// the same typed category. Redact before it can reach durable diagnostics.
    public struct Diagnostic: Error, LocalizedError, Sendable, ProviderFailureWrapping {
        public let cause: ProviderFailure
        public let detail: String
        public let deadlineExpired: Bool
        /// The provider began a response for this request.
        public let admitted: Bool
        public let repair: ToolFailureError?
        /// How many times delivery dialed this request (ProviderWire): above 1,
        /// asking again was already the wire's.
        public let tries: Int
        public init(cause: ProviderFailure, detail: String, deadlineExpired: Bool = false, admitted: Bool = false,
                    repair: ToolFailureError? = nil, tries: Int = 1) {
            self.cause = cause
            self.detail = String(ContextSecretContentPolicy.redactedFragment(detail).prefix(4096))
            self.deadlineExpired = deadlineExpired
            self.admitted = admitted
            self.repair = repair
            self.tries = tries
        }
        public var errorDescription: String? { repair?.message ?? cause.errorDescription }
        public var providerFailureCause: Error { cause }
    }

    public static func diagnosticDescription(_ error: Error) -> String {
        if let error = error as? Diagnostic { return error.detail }
        if let wrapper = error as? any ProviderFailureWrapping {
            return diagnosticDescription(wrapper.providerFailureCause)
        }
        let detail: String
        if let error = error as? LLMError {
            switch error {
            case .transient(let message), .underlying(let message),
                 .providerError(let message), .streamTruncated(let message): detail = message
            case .invalidResponse(let status): detail = "HTTP \(status)"
            case .authRejected(let provider, let message): detail = "\(provider): \(message ?? "authentication rejected")"
            // Never the partial reply itself: it can echo prompt or source text.
            case .outputLengthLimit(let partial): detail = "output length limit after \(partial.utf8.count) bytes"
            default: detail = String(describing: error)
            }
        } else {
            let ns = error as NSError
            detail = "\(ns.domain) code=\(ns.code): \(ns.localizedDescription)"
        }
        return String(ContextSecretContentPolicy.redactedFragment(detail).prefix(4096))
    }

    /// What a failed model call is to her, decided once for every surface. A
    /// sign-in that is rejected or expired, an account that is not connected
    /// or a model its account does not serve stays wrong until someone changes
    /// it: it names that owner and its lever and owes repair. An outage, a
    /// limit, a timeout, an empty or unreadable reply or a refusal is the
    /// provider's answer to this request: it owes nothing and names its fix
    /// and control. Nothing here proves the Mac healthy, so nothing
    /// says so. A failure already carrying its repair keeps it.
    public static func repair(_ error: Error, provider: String, model: String, surface: String,
                              dataRoot: URL, id: String, evidence: [Experience.Ref] = []) -> ToolFailureError {
        if let carried = (error as? Diagnostic)?.repair { return carried }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return ToolFailureError("provider_call_cancelled: The model call was cancelled. Keep any output already received and leave the call stopped; no further action is needed.",
                effects: .unknown, code: "provider_call_cancelled", status: .cancelled,
                instruction: "Keep any output already received and leave the call stopped; no further action is needed.", recovery: .terminal)
        }
        let group = "providers." + (ProviderSurfaceGroups.group(for: surface) ?? ProviderSurfaceGroups.chat).id
        let detail = diagnosticDescription(error)
        let cause = classify(error)
        var lever: String?
        let failure: ToolFailureError
        if let thrown = error as? ToolFailureError { failure = thrown }
        else if let routing = error as? ProviderRoutingError { failure = routing.repair }
        else if case .outputLengthLimit(let partial) = error as? LLMError {
            let instruction = "Keep any partial output and request only the missing portion; inspect model choices with setting.get \(group)_model."
            return ToolFailureError(
                "provider_output_limit: \(provider) · \(model) reached its output limit (\(detail)). \(instruction)",
                effects: partial.isEmpty ? .none : .partial,
                nextCall: ToolFailureError.call("app", ["action": .string("setting.get"), "args": .object(["setting": .string(group + "_model")])]),
                code: "provider_output_limit", instruction: instruction, recovery: .inspect)
        }
        else {
            switch cause {
            case .authExpired?, .codexCLISessionExpired?:
                let connection = SwiftNativeProviderRouting.displayName(for: provider)
                let signIn = NativeOAuthFlow.signInControl(providerID: provider, dataRoot: dataRoot)
                let owner = connection + " (" + provider + ") saved " + (signIn == nil ? "API key" : "sign-in")
                let tap = signIn ?? "Providers → Accounts & API keys → \(connection) → Manage → Key → Paste the key here → Save"
                let instruction = "Ask the person to reconnect at \(tap)."
                failure = ToolFailureError("provider_auth_expired: \(owner): \(detail). \(instruction)", effects: .none, owner: owner, tap: tap,
                    code: "provider_auth_expired", instruction: instruction, recovery: .repair)
            case .routingUnavailable?, .modelUnavailable?:
                let setting = group + (cause == .modelUnavailable ? "_model" : "_account")
                lever = "setting.set:" + setting
                let code = cause == .modelUnavailable ? "provider_model_unavailable" : "provider_routing_unavailable"
                let instruction = "Read setting.get \(setting), then use setting.set with a listed value for \(surface)."
                failure = ToolFailureError(
                    "\(code): \(provider) · \(model): \(detail). \(instruction)",
                    effects: .none, owner: "setting " + setting,
                    nextCall: ToolFailureError.call("app", ["action": .string("setting.get"), "args": .object(["setting": .string(setting)])]),
                    code: code, instruction: instruction, recovery: .repair)
            case .contextTooLong?:
                // Full is not a passing outage: asking again sends the same context.
                let instruction = "Compact this conversation with app {action:\"chat.compact\"}; repeating it unchanged sends the same full context."
                return ToolFailureError(
                    "provider_context_limit: \(provider) · \(model): the context is full (\(detail)). \(instruction)",
                    effects: .none,
                    nextCall: ToolFailureError.call("app", ["action": .string("chat.compact")]),
                    code: "provider_context_limit", instruction: instruction, recovery: .repair)
            default:
                let code: String
                let instruction: String
                let status: ToolFailureError.Status
                switch cause {
                case .refused?: status = .refused
                case .noReply?: status = .timeout
                default: status = (error as? Diagnostic)?.deadlineExpired == true ? .timeout : .failed
                }
                switch cause {
                case .rateLimited(let seconds?)?:
                    code = "provider_rate_limited"
                    instruction = "Wait \(seconds) seconds before another request; inspect the selected account and model with setting.get \(group)_model."
                case .rateLimited(nil)?:
                    code = "provider_rate_limited"
                    instruction = "Check the account's usage allowance before another request; no wait time was supplied. Inspect its model choice with setting.get \(group)_model."
                case .outputLimit?:
                    code = "provider_output_limit"
                    instruction = "Keep any partial output and request only the missing portion; inspect model choices with setting.get \(group)_model."
                case .refused?:
                    code = "provider_refused"
                    instruction = "Read the refusal and stop if the request is disallowed; otherwise address the reported concern."
                case .requestRejected?:
                    code = "provider_request_rejected"
                    instruction = "Inspect the rejection and correct the reported request error before another request."
                case .network?:
                    code = "provider_network_interrupted"
                    instruction = "Check this Mac's internet connection in System Settings → Network; preserve any output already received."
                case .noReply?:
                    code = "provider_no_reply"
                    instruction = "Inspect the deadline evidence and preserve any output already received; inspect the selected model with setting.get \(group)_model."
                case .overloaded?:
                    code = "provider_overloaded"
                    instruction = "Wait for provider capacity before another request; inspect model choices with setting.get \(group)_model."
                default:
                    code = "provider_response_invalid"
                    instruction = "Preserve any output already received and inspect the response error before continuing; inspect the selected model with setting.get \(group)_model."
                }
                return ToolFailureError(
                    "\(code): \(provider) · \(model) response stopped: \(detail). \(instruction)",
                    effects: .unknown,
                    nextCall: cause == .network ? nil : ToolFailureError.call("app", ["action": .string("setting.get"), "args": .object(["setting": .string(group + "_model")])]),
                    tap: cause == .network ? "System Settings → Network" : nil,
                    code: code, status: status,
                    instruction: instruction, recovery: .inspect)
            }
        }
        if let owner = failure.owner, !failure.personDecides {
            RepairOwed.owe(dataRoot, id: id, kind: .act, evidence: evidence, operation: "model.call:" + provider + ":" + model,
                owner: owner, words: failure.message, lever: lever, nextCall: failure.nextCall, tap: failure.tap)
        }
        return failure
    }

    /// The cause as a string, for a receipt whose wire cannot carry the type.
    public var encoded: String? { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } }

    public static func decoded(_ encoded: String) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8))
    }

    static func wireError(_ object: [String: Any]) -> Diagnostic {
        let detail = wireDetail(object)
        return Diagnostic(cause: wire(detail), detail: detail)
    }
}

/// Wrappers preserve typed recovery and work evidence across module boundaries.
public protocol ProviderFailureWrapping: Error {
    var providerFailureCause: Error { get }
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
        public init(cause: ProviderFailure, work: WorkState) {
            self.cause = cause
            self.work = work
        }
        public var providerFailureCause: Error { cause }
        public var providerWorkState: WorkState? { work }
        public var errorDescription: String? {
            (cause.errorDescription ?? "The reply could not be completed.") + " Work: " + work.rawValue + "."
        }
        /// People receive the cause alone; agent peers also receive the work tag.
        public var personDescription: String {
            (cause.errorDescription ?? "The reply could not be completed.")
                + (work == .ranPartly ? " Some steps had already run before it stopped." : "")
        }
    }

    public static func report(_ error: Error, work: WorkState? = nil) -> Report? {
        guard let cause = classify(error) else { return nil }
        func observed(_ error: Error) -> WorkState? {
            guard let wrapper = error as? any ProviderFailureWrapping else { return nil }
            return wrapper.providerWorkState ?? observed(wrapper.providerFailureCause)
        }
        return Report(
            cause: cause,
            work: work ?? observed(error) ?? (cause == .network ? .outcomeUnknown : .nothingRan)
        )
    }
}
